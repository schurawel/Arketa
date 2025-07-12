#!/bin/bash
# Script to start two VMs with bridged networking - CONFIGURE FIRST, THEN CONNECT BRIDGE

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to terminate all running QEMU processes
kill_qemu_processes() {
    echo -e "Removing temporary files"
    rm -r ./qemu-vms/tmp/
    echo -e "${YELLOW}Checking for running QEMU VM instances...${NC}"
    QEMU_PROCS=$(pgrep -l qemu-system)
    
    if [ -n "$QEMU_PROCS" ]; then
        echo -e "${RED}Found running QEMU processes:${NC}"
        echo "$QEMU_PROCS"
        
        echo -e "${YELLOW}Terminating all running QEMU VMs...${NC}"
        pkill qemu-system
        
        # Wait for processes to terminate
        sleep 2
        
        # Check if any processes are still running
        if pgrep qemu-system > /dev/null; then
            echo -e "${RED}Some QEMU processes couldn't be terminated. Forcing...${NC}"
            pkill -9 qemu-system
            sleep 1
        fi
        
        echo -e "${GREEN}All QEMU processes terminated.${NC}"
    else
        echo -e "${GREEN}No running QEMU processes found.${NC}"
    fi
}

# Improved bridge network setup with proper internet access
setup_bridge() {
    BRIDGE_NAME="qemubr0"
    
    echo -e "${BLUE}Setting up Linux bridge network ${BRIDGE_NAME} with internet access...${NC}"
    
    # Remove existing bridge if it exists to ensure clean setup
    if ip link show "${BRIDGE_NAME}" >/dev/null 2>&1; then
        echo -e "${YELLOW}Removing existing bridge interface...${NC}"
        sudo ip link set "${BRIDGE_NAME}" down || true
        sudo ip link delete "${BRIDGE_NAME}" || true
        sleep 2
    fi
    
    # Find the default network interface that has internet access
    echo -e "${BLUE}Finding default internet interface...${NC}"
    DEFAULT_IFACE=$(ip route show default | grep -Eo 'dev [^ ]+' | cut -d ' ' -f 2)
    if [ -z "$DEFAULT_IFACE" ]; then
        echo -e "${RED}Failed to determine default internet interface. Cannot continue.${NC}"
        exit 1
    fi
    echo -e "${GREEN}Using ${DEFAULT_IFACE} as the internet-connected interface.${NC}"
    
    # Create bridge interface
    echo -e "${BLUE}Creating bridge interface ${BRIDGE_NAME}...${NC}"
    sudo ip link add name "${BRIDGE_NAME}" type bridge || {
        echo -e "${RED}Failed to create bridge. Trying alternative method...${NC}"
        sudo brctl addbr "${BRIDGE_NAME}" || {
            echo -e "${RED}Failed to create bridge. Cannot continue.${NC}"
            exit 1
        }
    }
    
    # Configure bridge parameters for better performance
    sudo ip link set "${BRIDGE_NAME}" type bridge forward_delay 0
    sudo ip link set "${BRIDGE_NAME}" type bridge stp_state 0
    
    # Add IP to bridge
    sudo ip addr add 192.168.7.1/24 dev "${BRIDGE_NAME}" || {
        echo -e "${RED}Failed to add IP to bridge. Cannot continue.${NC}"
        exit 1
    }
    
    # Bring bridge up
    sudo ip link set "${BRIDGE_NAME}" up || {
        echo -e "${RED}Failed to bring bridge up. Cannot continue.${NC}"
        exit 1
    }
    
    # Set up NAT to allow VMs to access the internet
    echo -e "${BLUE}Setting up NAT for internet access...${NC}"
    
    # Clear any existing NAT rules for this subnet to avoid duplicates
    sudo iptables -t nat -D POSTROUTING -s 192.168.7.0/24 -j MASQUERADE 2>/dev/null || true
    
    # Add NAT rule for outgoing traffic
    sudo iptables -t nat -A POSTROUTING -s 192.168.7.0/24 -o "${DEFAULT_IFACE}" -j MASQUERADE || {
        echo -e "${RED}Failed to set up NAT. Internet access may not work.${NC}"
    }
    
    # Allow forwarding between bridge and default interface
    sudo iptables -D FORWARD -i "${BRIDGE_NAME}" -o "${DEFAULT_IFACE}" -j ACCEPT 2>/dev/null || true
    sudo iptables -A FORWARD -i "${BRIDGE_NAME}" -o "${DEFAULT_IFACE}" -j ACCEPT
    
    sudo iptables -D FORWARD -i "${DEFAULT_IFACE}" -o "${BRIDGE_NAME}" -j ACCEPT 2>/dev/null || true
    sudo iptables -A FORWARD -i "${DEFAULT_IFACE}" -o "${BRIDGE_NAME}" -j ACCEPT
    
    # Enable IP forwarding (make it persistent)
    echo -e "${BLUE}Enabling IP forwarding...${NC}"
    echo 1 | sudo tee /proc/sys/net/ipv4/ip_forward > /dev/null
    sudo sysctl -w net.ipv4.ip_forward=1
    
    # Ensure QEMU has access to the bridge - FIX PERMISSIONS
    echo -e "${BLUE}Setting up QEMU bridge permissions...${NC}"
    sudo mkdir -p /etc/qemu
    echo "allow ${BRIDGE_NAME}" | sudo tee /etc/qemu/bridge.conf > /dev/null
    
    # Make sure qemu-bridge-helper has correct permissions
    QEMU_BRIDGE_HELPER=$(which qemu-bridge-helper 2>/dev/null || echo "/usr/lib/qemu/qemu-bridge-helper")
    if [ -f "$QEMU_BRIDGE_HELPER" ]; then
        echo -e "${GREEN}Found qemu-bridge-helper at ${QEMU_BRIDGE_HELPER}${NC}"
        # Make sure it's setuid root
        sudo chown root:root "$QEMU_BRIDGE_HELPER"
        sudo chmod u+s "$QEMU_BRIDGE_HELPER"
    else
        echo -e "${RED}qemu-bridge-helper not found. Bridge networking may fail.${NC}"
        # Try to find it in other common locations
        for path in /usr/libexec/qemu-bridge-helper /usr/local/libexec/qemu-bridge-helper; do
            if [ -f "$path" ]; then
                echo -e "${GREEN}Found alternative qemu-bridge-helper at ${path}${NC}"
                QEMU_BRIDGE_HELPER="$path"
                sudo chown root:root "$QEMU_BRIDGE_HELPER"
                sudo chmod u+s "$QEMU_BRIDGE_HELPER"
                break
            fi
        done
    fi
    
    # Verify bridge setup
    echo -e "${BLUE}Bridge configuration:${NC}"
    ip addr show "${BRIDGE_NAME}"
    ip route show | grep "${BRIDGE_NAME}"
    
    echo -e "${GREEN}Bridge setup with internet access completed.${NC}"
    
    # Export bridge helper path for child processes
    export QEMU_BRIDGE_HELPER
}

# Function to start VMs with only user networking
start_vms_with_user_networking() {
    echo -e "${BLUE}PHASE 1: Starting VMs with user networking only for configuration${NC}"
    
    # Create VM1 script
    VM1_USER_SCRIPT="${TMP_DIR}/vm1_user_${SESSION_ID}.sh"
    cat > "${VM1_USER_SCRIPT}" <<EOF
#!/bin/bash
echo "Starting VM1 with user networking only..."

export QEMU_AUDIO_DRV=none
exec qemu-system-x86_64 -m 4096 -smp 4 \\
    -enable-kvm \\
    -cpu host \\
    -drive file="${TEMP_DISK1}",format=qcow2 \\
    -netdev user,id=net0,hostfwd=tcp::2222-:22 \\
    -device virtio-net-pci,netdev=net0 \\
    -nographic \\
    -serial mon:stdio
EOF
    chmod +x "${VM1_USER_SCRIPT}"
    
    # Create VM2 script
    VM2_USER_SCRIPT="${TMP_DIR}/vm2_user_${SESSION_ID}.sh"
    cat > "${VM2_USER_SCRIPT}" <<EOF
#!/bin/bash
echo "Starting VM2 with user networking only..."

export QEMU_AUDIO_DRV=none
exec qemu-system-x86_64 -m 4096 -smp 4 \\
    -enable-kvm \\
    -cpu host \\
    -drive file="${TEMP_DISK2}",format=qcow2 \\
    -netdev user,id=net0,hostfwd=tcp::2223-:22 \\
    -device virtio-net-pci,netdev=net0 \\
    -nographic \\
    -serial mon:stdio
EOF
    chmod +x "${VM2_USER_SCRIPT}"
    
    # Start VMs
    echo -e "${BLUE}Starting VM1...${NC}"
    xterm -title "VM1 Console" -e "${VM1_USER_SCRIPT}" &
    VM1_PID=$!
    
    echo -e "${BLUE}Starting VM2...${NC}"
    xterm -title "VM2 Console" -e "${VM2_USER_SCRIPT}" &
    VM2_PID=$!
    
    # Wait for SSH to be available - ONLY USE PORT FORWARDING IN PHASE 1
    echo -e "${BLUE}Waiting for SSH to be available...${NC}"
    wait_for_ssh "localhost" "2222" "VM1"
    wait_for_ssh "localhost" "2223" "VM2"
}

# Function to configure network inside VM with improved resilience against hanging
configure_network() {
    local ssh_port=$1
    local vm_name=$2
    local static_ip=$3
    local other_vm_name=$4
    local other_vm_ip=$5
    
    echo -e "${BLUE}Configuring network in ${vm_name} with non-blocking approach...${NC}"
    
    # Create a detached background script to avoid hanging the SSH session
    sshpass -p "ubuntu" ssh -o StrictHostKeyChecking=no -p ${ssh_port} ubuntu@localhost << EOF
# Disable systemd network wait services
echo "Disabling systemd network wait services..."
sudo systemctl disable systemd-networkd-wait-online.service
sudo systemctl mask systemd-networkd-wait-online.service
sudo systemctl disable NetworkManager-wait-online.service 2>/dev/null || true
sudo systemctl mask NetworkManager-wait-online.service 2>/dev/null || true

# Create a file to disable cloud-init network config which can cause delays
sudo touch /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
echo "network: {config: disabled}" | sudo tee /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg

# Completely remove Netplan files that might be interfering
echo "Removing any existing netplan configurations..."
sudo rm -f /etc/netplan/*.yaml

# Find network interface
echo "Detecting network interfaces..."
IFACE=\$(ip link | grep -v lo | grep -E "ens|enp|eth" | head -1 | cut -d: -f2 | tr -d ' ')
echo "Using \$IFACE as bridge interface"

# Disable problematic services
echo "Disabling network services that might cause issues..."
sudo systemctl stop systemd-resolved || true
sudo systemctl disable systemd-resolved || true

# Create a background script that will configure the network
# This prevents SSH session from hanging due to network changes
cat > /tmp/configure_network.sh << 'NETSCRIPT'
#!/bin/bash

# Wait a moment to ensure we don't interrupt current SSH session
sleep 5

# Get interface name
IFACE=\$(ip link | grep -v lo | grep -E "ens|enp|eth" | head -1 | cut -d: -f2 | tr -d ' ')

# Create netplan configuration for static IP
sudo mkdir -p /etc/netplan

# Remove existing netplan configs to avoid conflicts
sudo rm -f /etc/netplan/*.yaml

cat > /tmp/01-netcfg.yaml << NETPLAN
network:
  version: 2
  renderer: networkd
  ethernets:
    \$IFACE:
      dhcp4: no
      addresses: [${static_ip}/24]
      routes:
        - to: default
          via: 192.168.7.1
      nameservers:
        addresses: [8.8.8.8, 8.8.4.4]
NETPLAN

sudo mv /tmp/01-netcfg.yaml /etc/netplan/01-netcfg.yaml
sudo chmod 600 /etc/netplan/01-netcfg.yaml

# Apply the netplan config
echo "Applying netplan configuration..."
sudo netplan generate
sudo netplan apply

# Configure direct IP as backup (in case netplan fails)
echo "Setting up manual IP configuration as backup..."
sudo ip addr flush dev \$IFACE
sudo ip addr add ${static_ip}/24 dev \$IFACE
sudo ip link set \$IFACE up
sudo ip route add default via 192.168.7.1 dev \$IFACE

# Set up proper DNS resolution
echo "Configuring DNS..."
sudo rm -f /etc/resolv.conf
cat > /tmp/resolv.conf << DNSCONF
nameserver 8.8.8.8
nameserver 8.8.4.4
DNSCONF
sudo mv /tmp/resolv.conf /etc/resolv.conf
sudo chown root:root /etc/resolv.conf
sudo chmod 644 /etc/resolv.conf

# Prevent systemd from overwriting resolv.conf
sudo mkdir -p /etc/systemd/resolved.conf.d/
cat > /tmp/dns.conf << RESOLVED
[Resolve]
DNS=8.8.8.8 8.8.4.4
LLMNR=no
DNSSEC=no
DNSOverTLS=no
RESOLVED
sudo mv /tmp/dns.conf /etc/systemd/resolved.conf.d/dns.conf

# Add hosts entries
echo "Configuring hosts file..."
grep -q "${other_vm_ip} ${other_vm_name}" /etc/hosts || echo "${other_vm_ip} ${other_vm_name}" | sudo tee -a /etc/hosts
grep -q "192.168.7.1 bridge-host" /etc/hosts || echo "192.168.7.1 bridge-host" | sudo tee -a /etc/hosts

# Configure SSH server
echo "Configuring SSH server..."
sudo sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config
sudo sed -i 's/#ListenAddress 0.0.0.0/ListenAddress 0.0.0.0/' /etc/ssh/sshd_config
sudo sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
sudo systemctl restart ssh

# Signal completion
touch /tmp/network_configured
echo "Network configuration completed at \$(date)" > /tmp/network_setup.log
echo "IP: ${static_ip}" >> /tmp/network_setup.log
echo "Gateway: 192.168.7.1" >> /tmp/network_setup.log
echo "DNS: 8.8.8.8, 8.8.4.4" >> /tmp/network_setup.log
NETSCRIPT

# Make the script executable
chmod +x /tmp/configure_network.sh

# Run the script in the background so it doesn't hang SSH session
echo "Configuring static IP ${static_ip} in background process..."
nohup /tmp/configure_network.sh >/dev/null 2>&1 &

# Don't wait for completion - let it run in background
echo "Network configuration initiated in background process."
echo "Setup will continue after VM shutdown/restart."
EOF
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Network configuration initiated in ${vm_name} (running in background).${NC}"
    else
        echo -e "${RED}Failed to initiate network configuration in ${vm_name}.${NC}"
        return 1
    fi
    
    return 0  # Return success as configuration is running in background
}

# Function to wait for SSH to be available - DIRECT IP VERSION
wait_for_ssh_direct() {
    local ip=$1
    local name=$2
    local max_attempts=30
    local retry_interval=10
    
    echo -e "${BLUE}Waiting for ${name} SSH to be available at ${ip}...${NC}"
    
    for ((attempt=1; attempt<=max_attempts; attempt++)); do
        echo -e "${YELLOW}Attempt ${attempt}/${max_attempts}: Checking if ${name} SSH is ready at ${ip}...${NC}"
        
        if nc -z "${ip}" 22; then
            echo -e "${GREEN}${name} SSH port is open at ${ip}!${NC}"
            
            # Wait a bit more for SSH service to fully initialize
            sleep 10
            
            # Test SSH connectivity with direct IP using password authentication
            if timeout 10 sshpass -p "ubuntu" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o PasswordAuthentication=yes ubuntu@"${ip}" "echo 'SSH is working'"; then
                echo -e "${GREEN}${name} SSH is fully ready at ${ip}!${NC}"
                return 0
            else
                echo -e "${YELLOW}Port is open but SSH not responding yet at ${ip}. Waiting...${NC}"
            fi
        fi
        
        sleep "${retry_interval}"
    done
    
    echo -e "${RED}Failed to connect to ${name} SSH at ${ip} after ${max_attempts} attempts.${NC}"
    return 1
}

# Function to wait for SSH to be available - USED ONLY FOR INITIAL SETUP
wait_for_ssh() {
    local host=$1
    local port=$2
    local name=$3
    local max_attempts=30
    local retry_interval=10
    
    echo -e "${BLUE}Waiting for ${name} SSH to be available...${NC}"
    
    for ((attempt=1; attempt<=max_attempts; attempt++)); do
        echo -e "${YELLOW}Attempt ${attempt}/${max_attempts}: Checking if ${name} SSH is ready...${NC}"
        
        if nc -z "${host}" "${port}"; then
            echo -e "${GREEN}${name} SSH port is open!${NC}"
            
            # Wait a bit more for SSH service to fully initialize
            sleep 10
            
            # Test SSH connectivity
            if sshpass -p "ubuntu" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -p "${port}" ubuntu@"${host}" "echo 'SSH is working'"; then
                echo -e "${GREEN}${name} SSH is fully ready!${NC}"
                return 0
            else
                echo -e "${YELLOW}Port is open but SSH not responding yet. Waiting...${NC}"
            fi
        fi
        
        sleep "${retry_interval}"
    done
    
    echo -e "${RED}Failed to connect to ${name} SSH after ${max_attempts} attempts.${NC}"
    return 1
}

# Function to start VMs with bridge networking
start_vms_with_bridge() {
    echo -e "${BLUE}PHASE 4: Starting VMs with bridge networking${NC}"
    
    # Locate qemu-bridge-helper
    if [ -z "$QEMU_BRIDGE_HELPER" ]; then
        QEMU_BRIDGE_HELPER=$(which qemu-bridge-helper 2>/dev/null || echo "/usr/lib/qemu/qemu-bridge-helper")
        if [ ! -f "$QEMU_BRIDGE_HELPER" ]; then
            # Try to find it in other common locations
            for path in /usr/libexec/qemu-bridge-helper /usr/local/libexec/qemu-bridge-helper; do
                if [ -f "$path" ]; then
                    QEMU_BRIDGE_HELPER="$path"
                    break
                fi
            done
        fi
    fi
    
    echo -e "${BLUE}Using QEMU bridge helper: ${QEMU_BRIDGE_HELPER}${NC}"
    
    # Create VM1 script
    VM1_BRIDGE_SCRIPT="${TMP_DIR}/vm1_bridge_${SESSION_ID}.sh"
    cat > "${VM1_BRIDGE_SCRIPT}" <<EOF
#!/bin/bash
echo "Starting VM1 with bridge networking..."

# Set environment variable for QEMU bridge helper
export QEMU_BRIDGE_HELPER=${QEMU_BRIDGE_HELPER}
export QEMU_AUDIO_DRV=none

# Debug info
echo "Using bridge: ${BRIDGE_NAME}"
echo "Bridge helper: \$QEMU_BRIDGE_HELPER"
ls -la \$QEMU_BRIDGE_HELPER

exec qemu-system-x86_64 -m 4096 -smp 4 \\
    -enable-kvm \\
    -cpu host \\
    -drive file="${TEMP_DISK1}",format=qcow2 \\
    -netdev bridge,br=${BRIDGE_NAME},id=net0,helper=\$QEMU_BRIDGE_HELPER \\
    -device virtio-net-pci,netdev=net0,mac=${VM1_MAC} \\
    -netdev user,id=net1 \\
    -device virtio-net-pci,netdev=net1 \\
    -nographic \\
    -serial mon:stdio
EOF
    chmod +x "${VM1_BRIDGE_SCRIPT}"
    
    # Create VM2 script
    VM2_BRIDGE_SCRIPT="${TMP_DIR}/vm2_bridge_${SESSION_ID}.sh"
    cat > "${VM2_BRIDGE_SCRIPT}" <<EOF
#!/bin/bash
echo "Starting VM2 with bridge networking..."

# Set environment variable for QEMU bridge helper
export QEMU_BRIDGE_HELPER=${QEMU_BRIDGE_HELPER}
export QEMU_AUDIO_DRV=none

# Debug info
echo "Using bridge: ${BRIDGE_NAME}"
echo "Bridge helper: \$QEMU_BRIDGE_HELPER"
ls -la \$QEMU_BRIDGE_HELPER

exec qemu-system-x86_64 -m 4096 -smp 4 \\
    -enable-kvm \\
    -cpu host \\
    -drive file="${TEMP_DISK2}",format=qcow2 \\
    -netdev bridge,br=${BRIDGE_NAME},id=net0,helper=\$QEMU_BRIDGE_HELPER \\
    -device virtio-net-pci,netdev=net0,mac=${VM2_MAC} \\
    -netdev user,id=net1 \\
    -device virtio-net-pci,netdev=net1 \\
    -nographic \\
    -serial mon:stdio
EOF
    chmod +x "${VM2_BRIDGE_SCRIPT}"
    
    # Start VMs
    echo -e "${BLUE}Starting VM1 with bridge networking...${NC}"
    xterm -title "VM1 Console" -e "${VM1_BRIDGE_SCRIPT}" &
    
    echo -e "${BLUE}Starting VM2 with bridge networking...${NC}"
    xterm -title "VM2 Console" -e "${VM2_BRIDGE_SCRIPT}" &
    
    # Wait for VMs to boot
    echo -e "${YELLOW}Waiting 30 seconds for VMs to boot with bridge networking...${NC}"
    sleep 30
    
    # Debug: Check bridge status
    echo -e "${BLUE}Bridge status after VM startup:${NC}"
    ip addr show ${BRIDGE_NAME}
    brctl show ${BRIDGE_NAME} 2>/dev/null || ip link show master ${BRIDGE_NAME}
    
    # Wait for SSH to be available using BRIDGE IPs, not localhost
    echo -e "${BLUE}Waiting for VM SSH to be available after restart...${NC}"
    wait_for_ssh_direct "${VM1_IP}" "VM1"
    wait_for_ssh_direct "${VM2_IP}" "VM2"
}

# IMPORTANT: Function to connect to VMs using DIRECT IPs, not localhost port forwarding
connect_via_direct_ip() {
    local vm_name=$1
    local vm_ip=$2
    
    echo -e "${BLUE}Attempting to connect to ${vm_name} via direct IP ${vm_ip}...${NC}"
    
    # Try to ping the VM first to verify basic connectivity
    echo -e "${YELLOW}Testing connectivity to ${vm_ip}...${NC}"
    if ping -c 2 -W 2 ${vm_ip} > /dev/null 2>&1; then
        echo -e "${GREEN}Successfully pinged ${vm_name} at ${vm_ip}${NC}"
    else
        echo -e "${RED}Cannot ping ${vm_name} at ${vm_ip}. Network may not be properly configured.${NC}"
        return 1
    fi
    
    # Try SSH connection with timeout
    echo -e "${BLUE}Connecting to ${vm_name} via SSH at ${vm_ip}...${NC}"
    timeout 10s ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=no ubuntu@${vm_ip}
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}SSH session to ${vm_name} completed successfully.${NC}"
        return 0
    else
        echo -e "${RED}Failed to connect to ${vm_name} via SSH at ${vm_ip}.${NC}"
        return 1
    fi
}

# Function to test connectivity between VMs
test_direct_connectivity() {
    echo -e "${BLUE}Testing direct connectivity between VMs...${NC}"
    
    # Use the final discovered IPs
    local vm1_ip="${FINAL_VM1_IP:-${VM1_IP}}"
    local vm2_ip="${FINAL_VM2_IP:-${VM2_IP}}"
    
    # Test host -> VM1
    echo -e "${YELLOW}Host pinging VM1 (${vm1_ip})...${NC}"
    if ping -c 2 -W 2 ${vm1_ip} > /dev/null 2>&1; then
        echo -e "${GREEN}Host can ping VM1${NC}"
    else
        echo -e "${RED}Host cannot ping VM1${NC}"
    fi
    
    # Test host -> VM2
    echo -e "${YELLOW}Host pinging VM2 (${vm2_ip})...${NC}"
    if ping -c 2 -W 2 ${vm2_ip} > /dev/null 2>&1; then
        echo -e "${GREEN}Host can ping VM2${NC}"
    else
        echo -e "${RED}Host cannot ping VM2${NC}"
    fi
    
    # Test if SSH ports are open (using nc)
    echo -e "${YELLOW}Checking if SSH port is open on VM1...${NC}"
    if nc -z -w 2 ${vm1_ip} 22; then
        echo -e "${GREEN}SSH port is open on VM1${NC}"
    else
        echo -e "${RED}SSH port is not open on VM1${NC}"
    fi
    
    echo -e "${YELLOW}Checking if SSH port is open on VM2...${NC}"
    if nc -z -w 2 ${vm2_ip} 22; then
        echo -e "${GREEN}SSH port is open on VM2${NC}"
    else
        echo -e "${RED}SSH port is not open on VM2${NC}"
    fi
    
    echo -e "${BLUE}Direct connectivity test completed.${NC}"
}

# Add a function to test internet connectivity
test_internet_connectivity() {
    echo -e "${BLUE}Testing internet connectivity from VMs...${NC}"
    
    # Use the final discovered IPs
    local vm1_ip="${FINAL_VM1_IP:-${VM1_IP}}"
    local vm2_ip="${FINAL_VM2_IP:-${VM2_IP}}"
    
    # Test from VM1
    echo -e "${YELLOW}Testing internet connectivity from VM1...${NC}"
    if ping -c 1 -W 3 ${vm1_ip} > /dev/null 2>&1; then
        sshpass -p "ubuntu" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@${vm1_ip} << EOF
echo "Ping test to Google DNS:"
ping -c 3 8.8.8.8
echo "DNS resolution test:"
nslookup google.com
echo "HTTP connectivity test:"
curl -s --head http://www.google.com | head -1
EOF
    else
        echo -e "${RED}Cannot reach VM1 to test internet connectivity.${NC}"
    fi
    
    # Test from VM2
    echo -e "${YELLOW}Testing internet connectivity from VM2...${NC}"
    if ping -c 1 -W 3 ${vm2_ip} > /dev/null 2>&1; then
        sshpass -p "ubuntu" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@${vm2_ip} << EOF
echo "Ping test to Google DNS:"
ping -c 3 8.8.8.8
echo "DNS resolution test:"
nslookup google.com
echo "HTTP connectivity test:"
curl -s --head http://www.google.com | head -1
EOF
    else
        echo -e "${RED}Cannot reach VM2 to test internet connectivity.${NC}"
    fi
    
    echo -e "${GREEN}Internet connectivity tests completed.${NC}"
}

# MAIN SCRIPT STARTS HERE
# Clear all running QEMU processes at startup
kill_qemu_processes

# Configuration
VM_DIR="/home/thinclient/Documents/PrimedSLURM/qemu-vms"
IMAGE_PATH="${VM_DIR}/ubuntu-22.04-server-cloudimg-amd64.img"
SAVED_IMAGE="${VM_DIR}/saved-ubuntu-vm.qcow2"
CLOUD_INIT_DIR="${VM_DIR}/cloud-init"
VM_USERNAME="ubuntu"
VM_PASSWORD="ubuntu"
BRIDGE_NAME="qemubr0"
TMP_DIR="${VM_DIR}/tmp"

# VM networking info
VM1_MAC="52:54:00:12:34:56"
VM2_MAC="52:54:00:12:34:57"
VM1_IP="192.168.7.10"
VM2_IP="192.168.7.11"

# Create temporary directory if it doesn't exist
mkdir -p "${TMP_DIR}"

# Check if saved image exists, use base image if not
if [ -f "${SAVED_IMAGE}" ]; then
    BOOT_IMAGE="${SAVED_IMAGE}"
    echo -e "${BLUE}Using saved VM image: ${SAVED_IMAGE}${NC}"
else
    BOOT_IMAGE="${IMAGE_PATH}"
    echo -e "${BLUE}Using base VM image: ${IMAGE_PATH}${NC}"
    
    # Check if base image exists
    if [ ! -f "${BOOT_IMAGE}" ]; then
        echo -e "${RED}Error: VM image not found. Please run ./direct-image.sh first to create it.${NC}"
        exit 1
    fi
fi

# Generate a unique ID for this VM session
SESSION_ID=$(date +%Y%m%d%H%M%S)

# Copy the boot image to the temporary directory for VM1
TMP_BOOT_IMAGE1="${TMP_DIR}/boot_image_${SESSION_ID}_vm1.qcow2"
echo -e "${BLUE}Copying boot image to temporary location for VM1...${NC}"
cp "${BOOT_IMAGE}" "${TMP_BOOT_IMAGE1}"

# Create a temporary overlay disk for VM1
TEMP_DISK1="${TMP_DIR}/temp-session-${SESSION_ID}-vm1.qcow2"
echo -e "${BLUE}Creating temporary session disk for VM1...${NC}"
qemu-img create -f qcow2 -F qcow2 -b "${TMP_BOOT_IMAGE1}" "${TEMP_DISK1}" 30G

# Copy the boot image to the temporary directory for VM2
TMP_BOOT_IMAGE2="${TMP_DIR}/boot_image_${SESSION_ID}_vm2.qcow2"
echo -e "${BLUE}Copying boot image to temporary location for VM2...${NC}"
cp "${BOOT_IMAGE}" "${TMP_BOOT_IMAGE2}"

# Create a temporary overlay disk for VM2
TEMP_DISK2="${TMP_DIR}/temp-session-${SESSION_ID}-vm2.qcow2"
echo -e "${BLUE}Creating temporary session disk for VM2...${NC}"
qemu-img create -f qcow2 -F qcow2 -b "${TMP_BOOT_IMAGE2}" "${TEMP_DISK2}" 30G

# PHASE 1: Start VMs with user networking only
start_vms_with_user_networking

# PHASE 2: Configure network in each VM
echo -e "${BLUE}PHASE 2: Configuring network in each VM${NC}"
configure_network 2222 "VM1" "${VM1_IP}" "vm2" "${VM2_IP}"
configure_network 2223 "VM2" "${VM2_IP}" "vm1" "${VM1_IP}"

# Stop VMs to prepare for bridge networking
echo -e "${BLUE}Shutting down VMs to prepare for bridge networking...${NC}"
sshpass -p "ubuntu" ssh -o StrictHostKeyChecking=no -p 2222 ubuntu@localhost "sudo poweroff" || echo "VM1 may already be shutting down"
sshpass -p "ubuntu" ssh -o StrictHostKeyChecking=no -p 2223 ubuntu@localhost "sudo poweroff" || echo "VM2 may already be shutting down"

# Wait for VMs to shut down
echo -e "${BLUE}Waiting for VMs to shut down...${NC}"
sleep 30

# PHASE 3: Setup bridge network
echo -e "${BLUE}PHASE 3: Setting up bridge network...${NC}"
setup_bridge

# PHASE 4: Start VMs with bridge networking
start_vms_with_bridge

# Wait for bridge networking to initialize
echo -e "${BLUE}Waiting for VMs to boot with bridge networking...${NC}"
sleep 60

# PHASE 5: Wait for VMs to be accessible via DIRECT IPS and configure them
echo -e "${BLUE}PHASE 5: Waiting for VMs to be accessible via direct IPs${NC}"

# Wait a bit more for network to settle
sleep 30

# Check if VMs have gotten IP addresses via DHCP from bridge first
echo -e "${BLUE}Checking if VMs have received IP addresses...${NC}"

# Function to check VM IP and configure if needed
configure_vm_network_via_ssh() {
    local vm_name=$1
    local expected_ip=$2
    local ssh_port=$3
    local mac_address=$4
    
    echo -e "${BLUE}Configuring ${vm_name} network to use STATIC IP ${expected_ip} on interface with MAC ${mac_address}...${NC}"
    
    # Connect via port forwarding to configure the bridge IP
    sshpass -p "ubuntu" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -p ${ssh_port} ubuntu@localhost << EOF
echo "=== CONFIGURING STATIC IP ${expected_ip} FOR ${vm_name} ==="

# Get the bridge interface name using MAC address
BRIDGE_IFACE=\$(ip -br link | grep -i "${mac_address}" | awk '{print \$1}')
if [ -z "\$BRIDGE_IFACE" ]; then
    echo "ERROR: Could not find network interface for MAC address ${mac_address}"
    echo "Available interfaces:"
    ip link
    exit 1
fi
echo "Found bridge interface: \$BRIDGE_IFACE for MAC ${mac_address}"

# FORCE STATIC IP CONFIGURATION
echo "Flushing any existing IP on \$BRIDGE_IFACE..."
sudo ip addr flush dev \$BRIDGE_IFACE

echo "Adding static IP ${expected_ip}/24 to \$BRIDGE_IFACE..."
sudo ip addr add ${expected_ip}/24 dev \$BRIDGE_IFACE

echo "Bringing interface \$BRIDGE_IFACE up..."
sudo ip link set \$BRIDGE_IFACE up

# Remove all existing default routes and add our bridge route
echo "Configuring routing..."
sudo ip route del default 2>/dev/null || true
sudo ip route add default via 192.168.7.1 dev \$BRIDGE_IFACE

# FORCE DNS CONFIGURATION - Make it permanent
echo "=== CONFIGURING DNS ==="
sudo rm -f /etc/resolv.conf

# Create new resolv.conf with static DNS
sudo tee /etc/resolv.conf << RESOLV
nameserver 8.8.8.8
nameserver 8.8.4.4
nameserver 192.168.7.1
search local
RESOLV

# Make it immutable to prevent overwrites
sudo chattr +i /etc/resolv.conf 2>/dev/null || true

# Disable systemd-resolved to prevent DNS conflicts
sudo systemctl stop systemd-resolved 2>/dev/null || true
sudo systemctl disable systemd-resolved 2>/dev/null || true

# Configure SSH for password authentication
echo "=== CONFIGURING SSH ==="
sudo sed -i 's/#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sudo sed -i 's/#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
sudo sed -i 's/#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sudo systemctl restart ssh

# Add hosts entries for inter-VM communication
echo "=== CONFIGURING HOSTS FILE ==="
sudo tee -a /etc/hosts << HOSTS
192.168.7.1 bridge-host gateway
192.168.7.10 vm1
192.168.7.11 vm2
${expected_ip} ${vm_name}
HOSTS

# Verify network configuration
echo "=== NETWORK VERIFICATION ==="
ip addr show \$BRIDGE_IFACE
ip route show

echo "=== CONNECTIVITY TESTS ==="
echo "Testing bridge gateway..."
if ping -c 2 192.168.7.1; then
    echo "✓ Bridge gateway reachable"
else
    echo "✗ Bridge gateway NOT reachable"
fi

echo "Testing internet connectivity..."
if ping -c 2 8.8.8.8; then
    echo "✓ Internet reachable"
else
    echo "✗ Internet NOT reachable"
fi

echo "Testing DNS resolution..."
if nslookup google.com; then
    echo "✓ DNS resolution working"
else
    echo "✗ DNS resolution FAILED"
fi

echo "=== CONFIGURATION COMPLETE ==="
echo "VM: ${vm_name}"
echo "IP: ${expected_ip}/24"
echo "Gateway: 192.168.7.1"
echo "Interface: \$BRIDGE_IFACE"
EOF
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Successfully configured ${vm_name} with static IP ${expected_ip}${NC}"
        return 0
    else
        echo -e "${RED}✗ Failed to configure ${vm_name} network${NC}"
        return 1
    fi
}

# Configure VM networks via existing SSH port forwarding with STATIC IPs
echo -e "${BLUE}=== CONFIGURING STATIC IPs VIA SSH ===${NC}"

# Wait a bit for SSH to be ready
sleep 15

# Configure VM1 with static IP
if nc -z localhost 2222; then
    echo -e "${GREEN}VM1 SSH port available via localhost:2222${NC}"
    configure_vm_network_via_ssh "VM1" "${VM1_IP}" "2222" "${VM1_MAC}"
else
    echo -e "${RED}ERROR: Port 2222 not available for VM1 configuration${NC}"
    exit 1
fi

# Configure VM2 with static IP
if nc -z localhost 2223; then
    echo -e "${GREEN}VM2 SSH port available via localhost:2223${NC}"
    configure_vm_network_via_ssh "VM2" "${VM2_IP}" "2223" "${VM2_MAC}"  
else
    echo -e "${RED}ERROR: Port 2223 not available for VM2 configuration${NC}"
    exit 1
fi

echo -e "${GREEN}=== STATIC IP CONFIGURATION COMPLETE ===${NC}"

# Verify the VMs now have their static IPs
echo -e "${BLUE}=== VERIFYING STATIC IP ASSIGNMENT ===${NC}"
for ip in ${VM1_IP} ${VM2_IP}; do
    echo -e "${YELLOW}Testing connectivity to ${ip}...${NC}"
    if ping -c 2 -W 3 ${ip} >/dev/null 2>&1; then
        echo -e "${GREEN}✓ ${ip} is reachable${NC}"
    else
        echo -e "${RED}✗ ${ip} is NOT reachable${NC}"
    fi
done

# Now wait for SSH using DIRECT STATIC IP ADDRESSES
echo -e "${BLUE}=== WAITING FOR SSH VIA STATIC IPs ===${NC}"

# Use the static IPs we just configured
FINAL_VM1_IP="${VM1_IP}"
FINAL_VM2_IP="${VM2_IP}"

echo -e "${BLUE}VM1 Static IP: ${FINAL_VM1_IP}${NC}"
echo -e "${BLUE}VM2 Static IP: ${FINAL_VM2_IP}${NC}"

# Wait for SSH to be available on static IPs
wait_for_ssh_direct "${FINAL_VM1_IP}" "VM1"
wait_for_ssh_direct "${FINAL_VM2_IP}" "VM2"

# Test connectivity between VMs using direct IPs
test_direct_connectivity

# Test internet connectivity  
test_internet_connectivity

echo -e "${BLUE}Testing VM1 to VM2 connectivity via direct IPs...${NC}"
sshpass -p "ubuntu" ssh -o StrictHostKeyChecking=no ubuntu@${FINAL_VM1_IP} "ping -c 4 ${FINAL_VM2_IP}"

echo -e "${BLUE}Testing VM2 to VM1 connectivity via direct IPs...${NC}"
sshpass -p "ubuntu" ssh -o StrictHostKeyChecking=no ubuntu@${FINAL_VM2_IP} "ping -c 4 ${FINAL_VM1_IP}"

# Final instructions - NO PORT FORWARDING REFERENCES AT ALL
echo -e "\n${GREEN}=========================================${NC}"
echo -e "${GREEN}VMs are now set up with bridge networking!${NC}"
echo -e "${GREEN}VM1: ${FINAL_VM1_IP}${NC}"
echo -e "${GREEN}VM2: ${FINAL_VM2_IP}${NC}"
echo -e "${GREEN}=========================================${NC}"

echo -e "${BLUE}Starting SSH session to VM1 using direct bridge IP...${NC}"
sshpass -p "ubuntu" ssh -o StrictHostKeyChecking=no ubuntu@${FINAL_VM1_IP}

echo -e "${YELLOW}Do you want to connect to VM2? (y/n)${NC}"
read -r response
if [[ "$response" =~ ^[Yy]$ ]]; then
    echo -e "${BLUE}Starting SSH session to VM2 using direct bridge IP...${NC}"
    sshpass -p "ubuntu" ssh -o StrictHostKeyChecking=no ubuntu@${FINAL_VM2_IP}
fi

echo -e "${BLUE}VMs are running in separate windows.${NC}"
echo -e "${YELLOW}When finished, type 'poweroff' in the VMs or close the VM windows.${NC}"
echo -e "${YELLOW}This console will remain available. Press Ctrl+C to exit this script.${NC}"

# Wait for VMs to shutdown
echo -e "${BLUE}Monitoring VM processes...${NC}"
while pgrep -f "qemu-system.*${SESSION_ID}" > /dev/null; do
    sleep 5
done

echo -e "${GREEN}All VMs have been shut down.${NC}"
