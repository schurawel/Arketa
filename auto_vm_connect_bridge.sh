#!/bin/bash
# Script to start two VMs with virtual switch networking - CONFIGURE FIRST, THEN CONNECT SWITCH

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

# Function to setup virtual switch using Open vSwitch
setup_virtual_switch() {
    SWITCH_NAME="vswitch0"
    INTERNAL_PORT="vswitch0-int"  # Shortened to fit 15-char limit
    
    echo -e "${BLUE}Setting up Open vSwitch virtual switch ${SWITCH_NAME} with internet access...${NC}"
    
    # Install Open vSwitch if not already installed
    if ! command -v ovs-vsctl &> /dev/null; then
        echo -e "${YELLOW}Installing Open vSwitch...${NC}"
        sudo apt-get update
        sudo apt-get install -y openvswitch-switch openvswitch-common
        sudo systemctl start openvswitch-switch
        sudo systemctl enable openvswitch-switch
    fi
    
    # Remove existing switch if it exists
    if sudo ovs-vsctl br-exists "${SWITCH_NAME}" 2>/dev/null; then
        echo -e "${YELLOW}Removing existing virtual switch...${NC}"
        sudo ovs-vsctl del-br "${SWITCH_NAME}"
        sleep 2
    fi
    
    # Find the default network interface
    echo -e "${BLUE}Finding default internet interface...${NC}"
    DEFAULT_IFACE=$(ip route show default | grep -Eo 'dev [^ ]+' | cut -d ' ' -f 2)
    if [ -z "$DEFAULT_IFACE" ]; then
        echo -e "${RED}Failed to determine default internet interface. Cannot continue.${NC}"
        exit 1
    fi
    echo -e "${GREEN}Using ${DEFAULT_IFACE} as the internet-connected interface.${NC}"
    
    # Create virtual switch
    echo -e "${BLUE}Creating virtual switch ${SWITCH_NAME}...${NC}"
    sudo ovs-vsctl add-br "${SWITCH_NAME}"
    
    # Create internal port for host connectivity with shorter name
    echo -e "${BLUE}Creating internal port for host connectivity...${NC}"
    sudo ovs-vsctl add-port "${SWITCH_NAME}" "${INTERNAL_PORT}" -- set interface "${INTERNAL_PORT}" type=internal
    
    # Wait for interface to be created
    sleep 2
    
    # Configure the internal port
    sudo ip link set "${INTERNAL_PORT}" up
    sudo ip addr add 192.168.7.1/24 dev "${INTERNAL_PORT}"
    
    # Create TAP interfaces for VMs
    echo -e "${BLUE}Creating TAP interfaces for VMs...${NC}"
    for i in 0 1; do
        TAP_NAME="tap${i}"
        # Remove if exists
        sudo ip link delete "${TAP_NAME}" 2>/dev/null || true
        # Create new TAP interface
        sudo ip tuntap add mode tap "${TAP_NAME}"
        sudo ip link set "${TAP_NAME}" up
        # Add TAP to virtual switch
        sudo ovs-vsctl add-port "${SWITCH_NAME}" "${TAP_NAME}"
    done
    
    # Set up NAT for internet access
    echo -e "${BLUE}Setting up NAT for internet access...${NC}"
    
    # Clear existing NAT rules
    sudo iptables -t nat -D POSTROUTING -s 192.168.7.0/24 -j MASQUERADE 2>/dev/null || true
    
    # Add NAT rule
    sudo iptables -t nat -A POSTROUTING -s 192.168.7.0/24 -o "${DEFAULT_IFACE}" -j MASQUERADE
    
    # Allow forwarding using the shortened interface name
    sudo iptables -D FORWARD -i "${INTERNAL_PORT}" -o "${DEFAULT_IFACE}" -j ACCEPT 2>/dev/null || true
    sudo iptables -A FORWARD -i "${INTERNAL_PORT}" -o "${DEFAULT_IFACE}" -j ACCEPT
    
    sudo iptables -D FORWARD -i "${DEFAULT_IFACE}" -o "${INTERNAL_PORT}" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    sudo iptables -A FORWARD -i "${DEFAULT_IFACE}" -o "${INTERNAL_PORT}" -m state --state RELATED,ESTABLISHED -j ACCEPT
    
    # Enable IP forwarding
    echo 1 | sudo tee /proc/sys/net/ipv4/ip_forward > /dev/null
    sudo sysctl -w net.ipv4.ip_forward=1
    
    # Verify internal interface is up
    echo -e "${BLUE}Verifying internal interface configuration...${NC}"
    ip addr show "${INTERNAL_PORT}"
    
    # Show virtual switch configuration
    echo -e "${BLUE}Virtual switch configuration:${NC}"
    sudo ovs-vsctl show
    
    echo -e "${GREEN}Virtual switch setup completed.${NC}"
}

# Improved bridge network setup with proper internet access
setup_bridge() {
    # Call the virtual switch setup instead
    setup_virtual_switch
}

# Function to start VMs with virtual switch networking
start_vms_with_bridge() {
    echo -e "${BLUE}PHASE 4: Starting VMs with virtual switch networking ONLY (NO PORT FORWARDING)${NC}"
    
    # Set permissions for TAP interfaces before starting VMs
    echo -e "${BLUE}Setting TAP interface permissions...${NC}"
    sudo chown $(whoami) /dev/net/tun
    
    # Ensure TAP interfaces are up
    sudo ip link set tap0 up
    sudo ip link set tap1 up
    
    # Create VM1 script with TAP interface ONLY
    VM1_BRIDGE_SCRIPT="${TMP_DIR}/vm1_bridge_${SESSION_ID}.sh"
    cat > "${VM1_BRIDGE_SCRIPT}" <<EOF
#!/bin/bash
echo "Starting VM1 with virtual switch networking ONLY..."

export QEMU_AUDIO_DRV=none

# Run QEMU with ONLY TAP networking - NO USER NETWORKING
exec sudo qemu-system-x86_64 -m 4096 -smp 4 \\
    -enable-kvm \\
    -cpu host \\
    -drive file="${TEMP_DISK1}",format=qcow2 \\
    -netdev tap,id=net0,ifname=tap0,script=no,downscript=no \\
    -device virtio-net-pci,netdev=net0,mac=${VM1_MAC} \\
    -nographic \\
    -serial mon:stdio
EOF
    chmod +x "${VM1_BRIDGE_SCRIPT}"
    
    # Create VM2 script with TAP interface ONLY
    VM2_BRIDGE_SCRIPT="${TMP_DIR}/vm2_bridge_${SESSION_ID}.sh"
    cat > "${VM2_BRIDGE_SCRIPT}" <<EOF
#!/bin/bash
echo "Starting VM2 with virtual switch networking ONLY..."

export QEMU_AUDIO_DRV=none

# Run QEMU with ONLY TAP networking - NO USER NETWORKING
exec sudo qemu-system-x86_64 -m 4096 -smp 4 \\
    -enable-kvm \\
    -cpu host \\
    -drive file="${TEMP_DISK2}",format=qcow2 \\
    -netdev tap,id=net0,ifname=tap1,script=no,downscript=no \\
    -device virtio-net-pci,netdev=net0,mac=${VM2_MAC} \\
    -nographic \\
    -serial mon:stdio
EOF
    chmod +x "${VM2_BRIDGE_SCRIPT}"
    
    # Start VMs
    echo -e "${BLUE}Starting VM1 with virtual switch networking ONLY...${NC}"
    xterm -title "VM1 Console" -e "${VM1_BRIDGE_SCRIPT}" &
    
    echo -e "${BLUE}Starting VM2 with virtual switch networking ONLY...${NC}"
    xterm -title "VM2 Console" -e "${VM2_BRIDGE_SCRIPT}" &
    
    # Wait for VMs to boot
    echo -e "${YELLOW}Waiting 45 seconds for VMs to boot with virtual switch networking...${NC}"
    sleep 45
    
    # Debug: Check virtual switch status
    echo -e "${BLUE}Virtual switch status after VM startup:${NC}"
    sudo ovs-vsctl show
    sudo ovs-vsctl list-ports ${SWITCH_NAME}
    
    # Show TAP interface status
    echo -e "${BLUE}TAP interface status:${NC}"
    ip link show tap0
    ip link show tap1
    
    # Wait for SSH to be available on REAL IPs ONLY
    echo -e "${BLUE}Waiting for VM SSH to be available on REAL NETWORK IPs...${NC}"
    wait_for_ssh_direct "${VM1_IP}" "VM1"
    wait_for_ssh_direct "${VM2_IP}" "VM2"
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
    
    # Give VMs more time to boot before checking SSH
    echo -e "${YELLOW}Waiting 10 seconds for VMs to boot...${NC}"
    sleep 10
    
    # Wait for SSH to be available - ONLY USE PORT FORWARDING IN PHASE 1
    echo -e "${BLUE}Waiting for SSH to be available...${NC}"
    
    # Check if VMs are still running
    if ! ps -p $VM1_PID > /dev/null && ! pgrep -f "qemu.*${TEMP_DISK1}" > /dev/null; then
        echo -e "${RED}VM1 process has terminated unexpectedly. Check xterm window for errors.${NC}"
        exit 1
    fi
    
    if ! ps -p $VM2_PID > /dev/null && ! pgrep -f "qemu.*${TEMP_DISK2}" > /dev/null; then
        echo -e "${RED}VM2 process has terminated unexpectedly. Check xterm window for errors.${NC}"
        exit 1
    fi
    
    # Test port connectivity
    echo -e "${BLUE}Testing port connectivity...${NC}"
    if ! nc -z localhost 2222; then
        echo -e "${RED}Cannot connect to VM1 port 2222. VM might not have started properly.${NC}"
        echo -e "${YELLOW}Trying alternative approach...${NC}"
        
        # Try starting with direct virtual switch networking only
        echo -e "${BLUE}Skipping port forwarding configuration and proceeding directly to virtual switch setup.${NC}"
        return 1
    fi
    
    if ! nc -z localhost 2223; then
        echo -e "${RED}Cannot connect to VM2 port 2223. VM might not have started properly.${NC}"
        echo -e "${YELLOW}Trying alternative approach...${NC}"
        
        # Try starting with direct virtual switch networking only
        echo -e "${BLUE}Skipping port forwarding configuration and proceeding directly to virtual switch setup.${NC}"
        return 1
    fi
    
    wait_for_ssh "localhost" "2222" "VM1" || {
        echo -e "${RED}Failed to connect to VM1 SSH. Trying alternative approach.${NC}"
        return 1
    }
    
    wait_for_ssh "localhost" "2223" "VM2" || {
        echo -e "${RED}Failed to connect to VM2 SSH. Trying alternative approach.${NC}"
        return 1
    }
    
    return 0
}

# Function to configure network inside VM with improved resilience against hanging
configure_network() {
    local ssh_port=$1
    local vm_name=$2
    local static_ip=$3
    local other_vm_name=$4
    local other_vm_ip=$5
    
    echo -e "${BLUE}Configuring network in ${vm_name} for static IP ${static_ip}...${NC}"
    
    # Configure network via SSH
    sshpass -p "ubuntu" ssh -o StrictHostKeyChecking=no -p ${ssh_port} ubuntu@localhost << EOF
# Disable systemd network wait services
echo "Disabling systemd network wait services..."
sudo systemctl disable systemd-networkd-wait-online.service 2>/dev/null || true
sudo systemctl mask systemd-networkd-wait-online.service 2>/dev/null || true

# Disable cloud-init network configuration
echo "Disabling cloud-init network configuration..."
sudo touch /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
echo "network: {config: disabled}" | sudo tee /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg

# Remove any existing netplan configurations
echo "Removing existing netplan configurations..."
sudo rm -f /etc/netplan/*.yaml

# Detect the network interface
echo "Detecting network interface..."
IFACE=\$(ip link | grep -v lo | grep -E "ens|enp|eth" | head -1 | cut -d: -f2 | tr -d ' ')
echo "Found interface: \$IFACE"

# Create a simple netplan configuration
echo "Creating netplan configuration..."
cat > /tmp/01-netcfg.yaml << NETPLAN
network:
  version: 2
  renderer: networkd
  ethernets:
    \${IFACE}:
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

# Create rc.local script to ensure network comes up on boot
echo "Creating network startup script..."
cat > /tmp/rc.local << 'RCLOCAL'
#!/bin/bash
# Wait for network interface
sleep 5

# Get interface name
IFACE=\$(ip link | grep -v lo | grep -E "ens|enp|eth" | head -1 | cut -d: -f2 | tr -d ' ')

if [ -n "\$IFACE" ]; then
    # Bring interface up
    ip link set \$IFACE up
    
    # Apply static IP
    ip addr flush dev \$IFACE
    ip addr add ${static_ip}/24 dev \$IFACE
    ip link set \$IFACE up
    
    # Add default route
    ip route del default 2>/dev/null || true
    ip route add default via 192.168.7.1
    
    # Try netplan apply (may fail but that's ok)
    netplan apply 2>/dev/null || true
fi

exit 0
RCLOCAL

sudo mv /tmp/rc.local /etc/rc.local
sudo chmod +x /etc/rc.local

# Enable rc-local service
sudo systemctl enable rc-local 2>/dev/null || true

# Configure DNS
echo "Configuring DNS..."
cat > /tmp/resolv.conf << DNSCONF
nameserver 8.8.8.8
nameserver 8.8.4.4
DNSCONF
sudo mv /tmp/resolv.conf /etc/resolv.conf

# Disable systemd-resolved to prevent DNS issues
sudo systemctl stop systemd-resolved 2>/dev/null || true
sudo systemctl disable systemd-resolved 2>/dev/null || true

# Add hosts entries
echo "Configuring hosts file..."
grep -q "${other_vm_ip} ${other_vm_name}" /etc/hosts || echo "${other_vm_ip} ${other_vm_name}" | sudo tee -a /etc/hosts
grep -q "192.168.7.1 bridge-host" /etc/hosts || echo "192.168.7.1 bridge-host" | sudo tee -a /etc/hosts

# Configure SSH
echo "Configuring SSH..."
sudo sed -i 's/#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sudo sed -i 's/#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sudo systemctl restart ssh

echo "Network configuration completed for ${vm_name} with IP ${static_ip}"
echo "Network will be applied after VM restart."
EOF
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Network configuration completed in ${vm_name}.${NC}"
    else
        echo -e "${RED}Failed to configure network in ${vm_name}.${NC}"
        return 1
    fi
    
    return 0
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
# Function to wait for SSH to be available - DIRECT IP VERSION
wait_for_ssh_direct() {
    local ip=$1
    local name=$2
    local max_attempts=60  # Increased attempts
    local retry_interval=5   # Decreased interval
    
    echo -e "${BLUE}Waiting for ${name} SSH to be available at ${ip}...${NC}"
    
    for ((attempt=1; attempt<=max_attempts; attempt++)); do
        echo -e "${YELLOW}Attempt ${attempt}/${max_attempts}: Checking if ${name} SSH is ready at ${ip}...${NC}"
        
        # First check if we can ping the IP
        if ping -c 1 -W 2 ${ip} >/dev/null 2>&1; then
            echo -e "${GREEN}${name} is pingable at ${ip}${NC}"
            
            # Then check if SSH port is open
            if nc -z -w 2 "${ip}" 22 2>/dev/null; then
                echo -e "${GREEN}${name} SSH port is open at ${ip}!${NC}"
                
                # Test actual SSH connectivity
                if timeout 5 sshpass -p "ubuntu" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 ubuntu@"${ip}" "echo 'SSH is working'" 2>/dev/null; then
                    echo -e "${GREEN}${name} SSH is fully ready at ${ip}!${NC}"
                    return 0
                else
                    echo -e "${YELLOW}SSH port open but service not ready yet at ${ip}${NC}"
                fi
            else
                echo -e "${YELLOW}Waiting for SSH service to start on ${ip}${NC}"
            fi
        else
            echo -e "${YELLOW}Waiting for ${name} to be reachable at ${ip}${NC}"
        fi
        
        sleep "${retry_interval}"
    done
    
    echo -e "${RED}Failed to connect to ${name} SSH at ${ip} after ${max_attempts} attempts.${NC}"
    return 1
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
BRIDGE_NAME="vswitch0"  # Changed to virtual switch name
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
if start_vms_with_user_networking; then
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
else
    # Skip configuration and shutdown phases if VMs didn't start properly
    echo -e "${YELLOW}Skipping configuration phase due to VM startup issues.${NC}"
    echo -e "${YELLOW}Proceeding directly to virtual switch setup.${NC}"
    
    # Kill any running VMs to be safe
    echo -e "${YELLOW}Cleaning up any running VM processes...${NC}"
    pkill -f "qemu.*${TEMP_DISK1}" || true
    pkill -f "qemu.*${TEMP_DISK2}" || true
    sleep 10
fi

# PHASE 3: Setup bridge network
echo -e "${BLUE}PHASE 3: Setting up bridge network...${NC}"
setup_bridge

# PHASE 4: Start VMs with bridge networking
start_vms_with_bridge

# PHASE 5: Proceed with testing connectivity now that VMs are up and accessible
echo -e "${BLUE}PHASE 5: Testing connectivity between VMs${NC}"

echo -e "${BLUE}=== VERIFYING VM CONNECTIVITY ===${NC}"

# The VMs should be accessible with their configured static IPs
FINAL_VM1_IP="${VM1_IP}"
FINAL_VM2_IP="${VM2_IP}"

echo -e "${BLUE}VM1 IP: ${FINAL_VM1_IP}${NC}"
echo -e "${BLUE}VM2 IP: ${FINAL_VM2_IP}${NC}"

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

# Ask if user wants to connect to VMs or shut them down immediately
echo -e "${YELLOW}Do you want to connect to the VMs before shutting them down? (y/n)${NC}"
read -r response
if [[ "$response" =~ ^[Yy]$ ]]; then
    echo -e "${BLUE}Starting SSH session to VM1 using direct bridge IP...${NC}"
    sshpass -p "ubuntu" ssh -o StrictHostKeyChecking=no ubuntu@${FINAL_VM1_IP}
    
    echo -e "${YELLOW}Do you want to connect to VM2? (y/n)${NC}"
    read -r response2
    if [[ "$response2" =~ ^[Yy]$ ]]; then
        echo -e "${BLUE}Starting SSH session to VM2 using direct bridge IP...${NC}"
        sshpass -p "ubuntu" ssh -o StrictHostKeyChecking=no ubuntu@${FINAL_VM2_IP}
    fi
    
    echo -e "${BLUE}SSH sessions completed. Proceeding to shut down VMs.${NC}"
fi

# Add a function to gracefully shut down VMs via SSH
shutdown_vms() {
    echo -e "${BLUE}Shutting down VMs...${NC}"
    
    # Shut down VM1
    echo -e "${YELLOW}Shutting down VM1 at ${FINAL_VM1_IP}...${NC}"
    if ping -c 1 -W 2 ${FINAL_VM1_IP} > /dev/null 2>&1; then
        sshpass -p "ubuntu" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@${FINAL_VM1_IP} "sudo poweroff" || echo "VM1 may already be shutting down"
        echo -e "${GREEN}VM1 shutdown initiated.${NC}"
    else
        echo -e "${RED}Cannot reach VM1 to shut down properly.${NC}"
    fi
    
    # Shut down VM2
    echo -e "${YELLOW}Shutting down VM2 at ${FINAL_VM2_IP}...${NC}"
    if ping -c 1 -W 2 ${FINAL_VM2_IP} > /dev/null 2>&1; then
        sshpass -p "ubuntu" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@${FINAL_VM2_IP} "sudo poweroff" || echo "VM2 may already be shutting down"
        echo -e "${GREEN}VM2 shutdown initiated.${NC}"
    else
        echo -e "${RED}Cannot reach VM2 to shut down properly.${NC}"
    fi
    
    # Wait for VMs to shut down
    echo -e "${BLUE}Waiting for VMs to shut down...${NC}"
    sleep 30
}

# Shut down VMs automatically
shutdown_vms

# Wait for VMs to shutdown
echo -e "${BLUE}Monitoring VM processes...${NC}"
while pgrep -f "qemu-system.*${SESSION_ID}" > /dev/null; do
    sleep 5
done

echo -e "${GREEN}All VMs have been shut down.${NC}"
echo -e "${GREEN}Script execution completed successfully.${NC}"
