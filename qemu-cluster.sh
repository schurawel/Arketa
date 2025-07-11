#!/bin/bash
# QEMU-based Slurm cluster management script

set -e

# Configuration
PROJECT_DIR="/home/thinclient/Documents/PrimedSLURM"
VM_DIR="${PROJECT_DIR}/qemu-vms"  # Define VM_DIR first
SAVED_IMAGE="${VM_DIR}/saved-ubuntu-vm.qcow2"  # Use saved image from direct-image.sh

# VM login credentials (from direct-image.sh)
VM_USERNAME="ubuntu"
VM_PASSWORD="ubuntu"

# Network configuration - using simple user mode networking
CONTROLLER_SSH_PORT="2222"
NODE1_SSH_PORT="2223"
NODE2_SSH_PORT="2224"

# VM specifications
CONTROLLER_MEM="3072"  # 3GB
COMPUTE_MEM="3072"     # 3GB
CONTROLLER_CPU="2"
COMPUTE_CPU="2"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Usage information
function show_usage {
    echo "Usage: $0 [command]"
    echo "Commands:"
    echo "  create      - Create cluster VMs from saved image"
    echo "  start-all   - Start all VMs"
    echo "  stop-all    - Stop all VMs"
    echo "  status      - Show status of all VMs"
    echo "  clean       - Remove all VMs"
    echo "  ssh NODE    - SSH to specified node (controller, node1, node2)"
    echo "  help        - Show this help message"
    echo ""
    echo "VM Login Credentials:"
    echo "  Username: ${VM_USERNAME}"
    echo "  Password: ${VM_PASSWORD}"
    echo ""
    echo "SSH Connection Ports:"
    echo "  Controller: localhost:${CONTROLLER_SSH_PORT}"
    echo "  Node1:      localhost:${NODE1_SSH_PORT}"
    echo "  Node2:      localhost:${NODE2_SSH_PORT}"
}

# Check if saved image exists
function check_saved_image {
    if [ ! -f "${SAVED_IMAGE}" ]; then
        echo -e "${RED}Error: Saved image not found at ${SAVED_IMAGE}${NC}"
        echo -e "${YELLOW}Please run direct-image.sh first to create the saved image.${NC}"
        exit 1
    fi
    echo -e "${GREEN}Using saved image: ${SAVED_IMAGE}${NC}"
}

# Install required tools for cloud-init
function install_cloud_init_tools {
    echo -e "${BLUE}Checking for cloud-init tools...${NC}"
    
    # Check if cloud-localds is available
    if ! command -v cloud-localds &> /dev/null; then
        echo -e "${YELLOW}cloud-image-utils not found. Installing...${NC}"
        
        # Check if we have sudo access
        if ! sudo -n true 2>/dev/null; then
            echo -e "${YELLOW}Need sudo permission to install cloud-image-utils.${NC}"
            echo -e "${YELLOW}Please enter your password when prompted.${NC}"
        fi
        
        sudo apt-get update && sudo apt-get install -y cloud-image-utils || {
            echo -e "${RED}Failed to install cloud-image-utils. Please install manually:${NC}"
            echo -e "${RED}  sudo apt-get install cloud-image-utils${NC}"
            exit 1
        }
    else
        echo -e "${GREEN}cloud-localds tool is already installed.${NC}"
    fi
    
    # Check for qemu-img
    if ! command -v qemu-img &> /dev/null; then
        echo -e "${YELLOW}qemu-img not found. Installing qemu tools...${NC}"
        sudo apt-get update && sudo apt-get install -y qemu-utils || {
            echo -e "${RED}Failed to install qemu-utils. Please install manually:${NC}"
            echo -e "${RED}  sudo apt-get install qemu-utils${NC}"
            exit 1
        }
    else
        echo -e "${GREEN}qemu-img is already installed.${NC}"
    fi
    
    echo -e "${GREEN}All required tools for cloud-init are installed.${NC}"
}

# Create cloud-init data for a VM
function create_cloud_init {
    local vm_name=$1
    local vm_ip=$2
    
    echo -e "${BLUE}Creating cloud-init data for ${vm_name}...${NC}"
    
    # Ensure directories exist
    mkdir -p "${CLOUD_INIT_DIR}"
    
    # Create user-data file
    echo -e "${BLUE}Creating user-data file...${NC}"
    cat > "${CLOUD_INIT_DIR}/${vm_name}-user-data" <<EOF
#cloud-config
hostname: ${vm_name}
fqdn: ${vm_name}.local
manage_etc_hosts: true
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $(cat "${SSH_KEY_PATH}" || echo "ssh-rsa INVALID_KEY_PLEASE_CREATE_SSH_KEY")
package_update: true
package_upgrade: true
packages:
  - qemu-guest-agent
  - openssh-server
  - python3
  - git
  - wget
  - curl
  - vim
  - rsync
  - build-essential
  - munge
  - libmunge-dev
  - libslurm-dev
  - mariadb-server
  - libmariadb-dev
  - libmariadbclient-dev
  - libcurl4-openssl-dev
  - nfs-common
ssh_pwauth: false
runcmd:
  - systemctl enable qemu-guest-agent
  - systemctl start qemu-guest-agent
  - systemctl enable ssh
  - systemctl start ssh
  - echo 'Starting network service...' > /root/network-debug.log
  - systemctl restart systemd-networkd || echo 'Failed to restart networkd' >> /root/network-debug.log
  - ip addr >> /root/network-debug.log
  - ip route >> /root/network-debug.log
power_state:
  mode: reboot
  timeout: 30
  condition: true
EOF

    if [ ! -f "${CLOUD_INIT_DIR}/${vm_name}-user-data" ]; then
        echo -e "${RED}Failed to create user-data file for ${vm_name}!${NC}"
        exit 1
    else
        echo -e "${GREEN}User-data file created successfully.${NC}"
    fi

    # Create network-config file with correct gateway
    echo -e "${BLUE}Creating network-config file...${NC}"
    cat > "${CLOUD_INIT_DIR}/${vm_name}-network-config" <<EOF
version: 2
ethernets:
  enp0s3:
    dhcp4: false
    addresses: [${vm_ip}/24]
    gateway4: ${BRIDGE_IP}
    nameservers:
      addresses: [8.8.8.8, 1.1.1.1]
EOF

    if [ ! -f "${CLOUD_INIT_DIR}/${vm_name}-network-config" ]; then
        echo -e "${RED}Failed to create network-config file for ${vm_name}!${NC}"
        exit 1
    else
        echo -e "${GREEN}Network-config file created successfully.${NC}"
    fi

    # Create meta-data file (optional but recommended)
    echo -e "${BLUE}Creating meta-data file...${NC}"
    cat > "${CLOUD_INIT_DIR}/${vm_name}-meta-data" <<EOF
instance-id: ${vm_name}-inst-001
local-hostname: ${vm_name}
EOF

    if [ ! -f "${CLOUD_INIT_DIR}/${vm_name}-meta-data" ]; then
        echo -e "${RED}Failed to create meta-data file for ${vm_name}!${NC}"
        exit 1
    else
        echo -e "${GREEN}Meta-data file created successfully.${NC}"
    fi

    # Create cloud-init ISO
    echo -e "${BLUE}Creating cloud-init ISO for ${vm_name}...${NC}"
    cloud-localds -v --network-config="${CLOUD_INIT_DIR}/${vm_name}-network-config" \
        "${CLOUD_INIT_DIR}/${vm_name}-seed.iso" \
        "${CLOUD_INIT_DIR}/${vm_name}-user-data" \
        "${CLOUD_INIT_DIR}/${vm_name}-meta-data"
    
    if [ ! -f "${CLOUD_INIT_DIR}/${vm_name}-seed.iso" ]; then
        echo -e "${RED}Failed to create cloud-init ISO for ${vm_name}!${NC}"
        echo -e "${RED}Debugging information:${NC}"
        ls -la "${CLOUD_INIT_DIR}/"
        exit 1
    else
        echo -e "${GREEN}Cloud-init ISO created successfully: ${CLOUD_INIT_DIR}/${vm_name}-seed.iso${NC}"
        ls -la "${CLOUD_INIT_DIR}/${vm_name}-seed.iso"
    fi
}

# Create a VM disk
function create_vm_disk {
    local vm_name=$1
    local disk_size=$2
    local source_image=$3
    
    echo -e "${BLUE}Creating disk for ${vm_name}...${NC}"
    
    # Verify source image exists
    if [ ! -f "${source_image}" ]; then
        echo -e "${RED}Source image not found: ${source_image}${NC}"
        exit 1
    fi
    
    echo -e "${BLUE}Converting and resizing disk image...${NC}"
    
    # Create a copy of the source image
    qemu-img convert -f qcow2 -O qcow2 "${source_image}" "${VM_DIR}/${vm_name}.qcow2"
    
    # Check if image was created
    if [ ! -f "${VM_DIR}/${vm_name}.qcow2" ]; then
        echo -e "${RED}Failed to create disk image for ${vm_name}!${NC}"
        exit 1
    fi
    
    # Resize the disk
    qemu-img resize "${VM_DIR}/${vm_name}.qcow2" "${disk_size}G"
    
    echo -e "${GREEN}Disk created for ${vm_name} from ${source_image}.${NC}"
    echo -e "${BLUE}Disk details:${NC}"
    qemu-img info "${VM_DIR}/${vm_name}.qcow2"
}

# Configure QEMU bridge helper permissions
function configure_bridge_helper {
    echo -e "${BLUE}Configuring QEMU bridge helper permissions...${NC}"
    
    # Check if bridge.conf exists, if not create it
    if [ ! -f "$BRIDGE_CONF" ]; then
        echo -e "${YELLOW}Bridge configuration file not found. Creating it...${NC}"
        sudo mkdir -p "$(dirname "$BRIDGE_CONF")"
        echo "allow $BRIDGE_NAME" | sudo tee "$BRIDGE_CONF" > /dev/null
    else
        # Check if our bridge is already allowed
        if ! grep -q "allow $BRIDGE_NAME" "$BRIDGE_CONF"; then
            echo -e "${YELLOW}Adding $BRIDGE_NAME to allowed bridges...${NC}"
            echo "allow $BRIDGE_NAME" | sudo tee -a "$BRIDGE_CONF" > /dev/null
        else
            echo -e "${GREEN}Bridge $BRIDGE_NAME is already allowed in $BRIDGE_CONF${NC}"
        fi
    fi
    
    # Make sure qemu-bridge-helper has correct permissions
    if [ -f "$QEMU_BRIDGE_HELPER" ]; then
        # Check if the helper has setuid bit
        if [ ! -u "$QEMU_BRIDGE_HELPER" ]; then
            echo -e "${YELLOW}Setting correct permissions on $QEMU_BRIDGE_HELPER...${NC}"
            sudo chmod u+s "$QEMU_BRIDGE_HELPER"
        else
            echo -e "${GREEN}QEMU bridge helper already has correct permissions.${NC}"
        fi
    else
        echo -e "${RED}QEMU bridge helper not found at $QEMU_BRIDGE_HELPER.${NC}"
        echo -e "${YELLOW}Checking alternative locations...${NC}"
        
        # Try to find bridge helper in common locations
        for path in /usr/local/libexec/qemu-bridge-helper /usr/libexec/qemu-bridge-helper /usr/lib/qemu-kvm/qemu-bridge-helper; do
            if [ -f "$path" ]; then
                QEMU_BRIDGE_HELPER="$path"
                echo -e "${GREEN}Found QEMU bridge helper at $QEMU_BRIDGE_HELPER${NC}"
                sudo chmod u+s "$QEMU_BRIDGE_HELPER"
                break
            fi
        done
        
        if [ ! -f "$QEMU_BRIDGE_HELPER" ]; then
            echo -e "${RED}Could not find QEMU bridge helper. Please install QEMU properly.${NC}"
            exit 1
        fi
    fi
    
    echo -e "${GREEN}QEMU bridge helper configured successfully.${NC}"
}

# Setup network bridge for VM communication - now required
function setup_bridge {
    echo -e "${BLUE}Setting up network bridge ${BRIDGE_NAME}...${NC}"
    
    # Check if bridge already exists
    if ip link show ${BRIDGE_NAME} &> /dev/null; then
        echo -e "${GREEN}Bridge ${BRIDGE_NAME} already exists.${NC}"
    else
        # Check if we have sudo access
        if ! sudo -n true 2>/dev/null; then
            echo -e "${YELLOW}Need sudo permission to create network bridge.${NC}"
            echo -e "${YELLOW}Please enter your password when prompted.${NC}"
        fi
        
        # Install bridge-utils if needed
        if ! command -v brctl &> /dev/null; then
            echo -e "${YELLOW}Installing bridge-utils...${NC}"
            sudo apt-get update && sudo apt-get install -y bridge-utils || {
                echo -e "${RED}Failed to install bridge-utils. Please install manually:${NC}"
                echo -e "${RED}  sudo apt-get install bridge-utils${NC}"
                exit 1
            }
        fi
        
        # Create the bridge
        echo -e "${BLUE}Creating bridge ${BRIDGE_NAME}...${NC}"
        sudo brctl addbr ${BRIDGE_NAME} || {
            echo -e "${RED}Failed to create bridge ${BRIDGE_NAME}.${NC}"
            exit 1
        }
        
        # Set bridge IP
        sudo ip addr add ${BRIDGE_IP}/24 dev ${BRIDGE_NAME} || {
            echo -e "${RED}Failed to set IP address on bridge.${NC}"
            exit 1
        }
        
        # Bring up the bridge
        sudo ip link set ${BRIDGE_NAME} up || {
            echo -e "${RED}Failed to bring up bridge.${NC}"
            exit 1
        }
        
        # Enable IP forwarding for internet access
        echo -e "${BLUE}Enabling IP forwarding...${NC}"
        sudo sysctl -w net.ipv4.ip_forward=1 || {
            echo -e "${YELLOW}Warning: Failed to enable IP forwarding.${NC}"
        }
        
        # Optional: Set up NAT for VMs to access internet
        # Detect default interface
        DEFAULT_IFACE=$(ip route | grep default | cut -d' ' -f5 | head -n1)
        if [ -n "$DEFAULT_IFACE" ]; then
            echo -e "${BLUE}Setting up NAT on ${DEFAULT_IFACE}...${NC}"
            sudo iptables -t nat -A POSTROUTING -o ${DEFAULT_IFACE} -s ${BRIDGE_NETWORK} -j MASQUERADE || {
                echo -e "${YELLOW}Warning: Failed to setup NAT. VMs may not have internet access.${NC}"
            }
        else
            echo -e "${YELLOW}Warning: Could not detect default interface. VMs may not have internet access.${NC}"
        fi
        
        echo -e "${GREEN}Bridge ${BRIDGE_NAME} created successfully.${NC}"
    fi
    
    # Configure QEMU bridge helper
    configure_bridge_helper
    
    return 0
}

# Simplified start_vm function with bridge-only networking
function start_vm {
    local vm_name=$1
    local memory=$2
    local cpus=$3
    
    echo -e "${BLUE}Starting ${vm_name}...${NC}"
    
    # Check if VM is already running
    if pgrep -f "${vm_name}.qcow2" > /dev/null; then
        echo -e "${YELLOW}${vm_name} is already running.${NC}"
        return
    fi
    
    # Create VM directory if it doesn't exist
    mkdir -p "$(dirname "${VM_DIR}/${vm_name}.log")"
    
    # Detect QEMU command and check if KVM is available
    local QEMU_CMD="qemu-system-x86_64"
    local KVM_ARGS="-machine type=q35,accel=kvm -cpu host"
    
    # Check if KVM is available
    if ! [ -c /dev/kvm ] || ! [ -w /dev/kvm ]; then
        echo -e "${YELLOW}Warning: KVM acceleration not available. Performance will be significantly slower.${NC}"
        echo -e "${YELLOW}To fix, ensure KVM is installed and you have permissions:${NC}"
        echo -e "${YELLOW}  sudo apt-get install qemu-kvm${NC}"
        echo -e "${YELLOW}  sudo usermod -aG kvm $(whoami)${NC}"
        echo -e "${YELLOW}  sudo chmod 666 /dev/kvm${NC}"
        # Fall back to emulation without KVM
        KVM_ARGS="-machine type=q35 -cpu max"
    fi
    
    # Check if bridge exists, create it if it doesn't
    if ! ip link show ${BRIDGE_NAME} &> /dev/null; then
        echo -e "${YELLOW}Bridge ${BRIDGE_NAME} not found. Creating it now...${NC}"
        setup_bridge || {
            echo -e "${RED}Failed to create bridge network. Cannot continue.${NC}"
            exit 1
        }
    fi
    
    # Bridge-only networking
    echo -e "${BLUE}Using bridge network: ${BRIDGE_NAME}${NC}"
    local NETWORK_ARGS="-nic bridge,br=${BRIDGE_NAME},model=virtio"
    
    # Add a serial console for debugging
    local SERIAL_CONSOLE="-serial stdio"
    if [ -z "$INTERACTIVE" ]; then
        # In non-interactive mode, redirect to a file
        SERIAL_CONSOLE="-serial file:${VM_DIR}/${vm_name}-console.log"
    fi
    
    echo -e "${BLUE}Starting QEMU...${NC}"
    
    # Create the command string we'll use to start the VM (for logging)
    local CMD="$QEMU_CMD $KVM_ARGS -m ${memory} -smp ${cpus} -drive file=${VM_DIR}/${vm_name}.qcow2,format=qcow2 -drive file=${CLOUD_INIT_DIR}/${vm_name}-seed.iso,format=raw $NETWORK_ARGS -device virtio-serial -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0 -chardev socket,path=/tmp/qga-${vm_name}.sock,server=on,wait=off,id=qga0 $SERIAL_CONSOLE -display none -daemonize -qmp unix:${VM_DIR}/${vm_name}.qmp,server,nowait"
    
    # Log and execute
    echo "Running: $CMD" > "${VM_DIR}/${vm_name}.log"
    set +e
    eval "$CMD" >> "${VM_DIR}/${vm_name}.log" 2>&1
    local result=$?
    set -e
    
    # Check if VM started successfully
    sleep 2
    if pgrep -f "${vm_name}.qcow2" > /dev/null; then
        echo -e "${GREEN}${vm_name} started successfully.${NC}"
    else
        echo -e "${RED}Failed to start ${vm_name} (exit code: $result).${NC}"
        echo -e "${RED}Command: $CMD${NC}"
        echo -e "${RED}Log file at: ${VM_DIR}/${vm_name}.log${NC}"
        echo -e "${RED}Last 10 lines of log:${NC}"
        tail -n 10 "${VM_DIR}/${vm_name}.log" || echo "No log file found."
        exit 1
    fi
}

# Improved wait_for_ssh function with better IP detection
function wait_for_ssh {
    local vm_name=$1
    local vm_ip=$2
    local max_attempts=60
    
    echo -e "${BLUE}Waiting for SSH on ${vm_name} (${vm_ip})...${NC}"
    
    # First check if the bridge is properly set up
    if ! ip addr show ${BRIDGE_NAME} | grep -q "${BRIDGE_IP}"; then
        echo -e "${RED}Bridge ${BRIDGE_NAME} does not have the expected IP ${BRIDGE_IP}${NC}"
        echo -e "${YELLOW}Bridge current configuration:${NC}"
        ip addr show ${BRIDGE_NAME}
        echo -e "${YELLOW}Trying to continue anyway...${NC}"
    fi
    
    # Verify if qemu process is using the bridge
    if ! ps aux | grep qemu | grep -q "${BRIDGE_NAME}"; then
        echo -e "${RED}Warning: No QEMU process found using bridge ${BRIDGE_NAME}${NC}"
        echo -e "${YELLOW}QEMU processes:${NC}"
        ps aux | grep qemu | grep -v grep
    fi
    
    # Try to detect VM IP from ARP table
    echo -e "${BLUE}Checking ARP table for VM MAC address...${NC}"
    ip neigh flush dev ${BRIDGE_NAME} # Clear ARP cache
    ping -c 1 -b ${BRIDGE_IP%.*}.255 > /dev/null 2>&1 # Send broadcast ping to populate ARP table
    
    # Read console log to see what IP the VM is actually using
    if [ -f "${VM_DIR}/${vm_name}-console.log" ]; then
        echo -e "${BLUE}Checking console log for IP configuration...${NC}"
        grep -A 5 "ip addr" "${VM_DIR}/${vm_name}-console.log" | tail -10 || true
    fi
    
    # Try to ping multiple IPs
    echo -e "${BLUE}Trying to ping multiple possible IPs...${NC}"
    
    # Try the expected IP first
    echo -e "${YELLOW}Trying expected IP: ${vm_ip}${NC}"
    if ping -c 3 -W 2 ${vm_ip} > /dev/null 2>&1; then
        echo -e "${GREEN}Success! VM responded at ${vm_ip}${NC}"
    else
        echo -e "${RED}No response from ${vm_ip}${NC}"
        
        # Try common first-boot IP addresses
        for test_ip in "${BRIDGE_IP%.*}.2" "${BRIDGE_IP%.*}.3" "${BRIDGE_IP%.*}.254"; do
            echo -e "${YELLOW}Trying alternate IP: ${test_ip}${NC}"
            if ping -c 2 -W 1 ${test_ip} > /dev/null 2>&1; then
                echo -e "${GREEN}Found responsive IP at ${test_ip}${NC}"
                echo -e "${YELLOW}VM might be using ${test_ip} instead of ${vm_ip}!${NC}"
                echo -e "${YELLOW}Continuing with the original IP, but consider updating your configuration.${NC}"
                break
            fi
        done
    fi
    
    # Continue with SSH attempts on the expected IP
    for i in $(seq 1 $max_attempts); do
        echo -e "${BLUE}SSH attempt $i/$max_attempts...${NC}"
        
        # More verbose SSH attempt with timeout
        if ssh -v -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@${vm_ip} "echo SSH is ready" &> /tmp/ssh_debug.log; then
            echo -e "${GREEN}SSH is ready on ${vm_name}.${NC}"
            return 0
        fi
        
        # Show SSH debugging every 5 attempts
        if [ $((i % 5)) -eq 0 ]; then
            echo -e "${YELLOW}SSH debug info (attempt $i):${NC}"
            cat /tmp/ssh_debug.log | grep -i "connect\|debug\|auth\|error" | tail -10
        fi
        
        sleep 10
    done
    
    echo -e "${RED}Failed to connect to ${vm_name} via SSH after ${max_attempts} attempts.${NC}"
    echo -e "${YELLOW}VM may be running but SSH service might not be properly configured.${NC}"
    echo -e "${YELLOW}Try accessing the VM console to debug:${NC}"
    echo -e "${YELLOW}  1. Find VM process: ps aux | grep ${vm_name}${NC}"
    echo -e "${YELLOW}  2. Check network interfaces: ip addr${NC}"
    echo -e "${YELLOW}  3. Verify bridge configuration: brctl show ${BRIDGE_NAME}${NC}"
    return 1
}

# Build the base image with Slurm pre-installed
function build_base_image {
    echo -e "${BLUE}Building base image with Slurm pre-installed...${NC}"
    
    # Install required tools
    install_cloud_init_tools
    
    # Create cloud-init and disk for base VM with extra debugging
    echo -e "${BLUE}Creating cloud-init for base VM...${NC}"
    create_cloud_init "slurm-base" "${BASE_IP}"
    
    # Verify cloud-init ISO was created
    if [ ! -f "${CLOUD_INIT_DIR}/slurm-base-seed.iso" ]; then
        echo -e "${RED}Failed to create cloud-init ISO for base VM!${NC}"
        echo -e "${RED}Cannot continue with base image creation.${NC}"
        exit 1
    else
        echo -e "${GREEN}Cloud-init ISO verified successfully.${NC}"
    fi
    
    # Use the cloud image, not the ISO
    echo -e "${BLUE}Creating disk for base VM...${NC}"
    create_vm_disk "slurm-base" 40 "${UBUNTU_IMAGE_PATH}"
    
    # Verify VM disk was created
    if [ ! -f "${VM_DIR}/slurm-base.qcow2" ]; then
        echo -e "${RED}Failed to create disk for base VM!${NC}"
        echo -e "${RED}Cannot continue with base image creation.${NC}"
        exit 1
    else
        echo -e "${GREEN}VM disk verified successfully.${NC}"
    fi
    
    # Start base VM
    echo -e "${BLUE}Starting base VM...${NC}"
    start_vm "slurm-base" "${BASE_MEM}" "${BASE_CPU}"
    
    # Wait for SSH
    echo -e "${BLUE}Waiting for SSH on base VM...${NC}"
    wait_for_ssh "slurm-base" "${BASE_IP}" || {
        echo -e "${RED}Failed to connect to base VM via SSH.${NC}"
        echo -e "${RED}Try debugging with: $0 console slurm-base${NC}"
        exit 1
    }
    
    # Copy scripts to base VM
    echo -e "${BLUE}Copying scripts to base VM...${NC}"
    rsync -avz -e "ssh -o StrictHostKeyChecking=no" ./scripts/ ubuntu@${BASE_IP}:~/scripts/ || {
        echo -e "${RED}Failed to copy scripts to base VM.${NC}"
        exit 1
    }
    
    # Make scripts executable
    ssh -o StrictHostKeyChecking=no ubuntu@${BASE_IP} "chmod +x ~/scripts/*.sh" || {
        echo -e "${RED}Failed to make scripts executable.${NC}"
        exit 1
    }
    
    # Clone and copy Slurm source
    echo -e "${BLUE}Preparing Slurm source code...${NC}"
    mkdir -p ./tmp
    if [ ! -d "./tmp/slurm" ]; then
        echo -e "${BLUE}Cloning Slurm repository...${NC}"
        git clone --depth=1 --branch slurm-21-08-8-2 https://github.com/SchedMD/slurm.git ./tmp/slurm || {
            echo -e "${RED}Failed to clone Slurm repository.${NC}"
            exit 1
        }
    fi
    
    # Copy Slurm source to base VM
    echo -e "${BLUE}Copying Slurm source to base VM...${NC}"
    rsync -avz -e "ssh -o StrictHostKeyChecking=no" ./tmp/slurm/ ubuntu@${BASE_IP}:~/slurm-src/ || {
        echo -e "${RED}Failed to copy Slurm source to base VM.${NC}"
        exit 1
    }
    
    # Run setup-base.sh on base VM
    echo -e "${BLUE}Running setup-base.sh on base VM...${NC}"
    ssh -o StrictHostKeyChecking=no ubuntu@${BASE_IP} "cd ~ && sudo ~/scripts/setup-base.sh --clean-for-imaging" || {
        echo -e "${RED}Failed to run setup-base.sh on base VM.${NC}"
        exit 1
    }
    
    # Shutdown base VM
    echo -e "${BLUE}Shutting down base VM...${NC}"
    ssh -o StrictHostKeyChecking=no ubuntu@${BASE_IP} "sudo shutdown -h now" || {
        echo -e "${YELLOW}Warning: Clean shutdown failed, forcing VM to stop...${NC}"
        stop_vm "slurm-base"
    }
    
    # Wait for VM to shutdown
    echo -e "${BLUE}Waiting for base VM to shutdown...${NC}"
    for i in {1..30}; do
        if ! pgrep -f "slurm-base.qcow2" > /dev/null; then
            echo -e "${GREEN}Base VM has shut down.${NC}"
            break
        fi
        echo -n "."
        sleep 2
        if [ $i -eq 30 ]; then
            echo -e "${YELLOW}Warning: Base VM did not shut down cleanly. Forcing stop...${NC}"
            pkill -f "slurm-base.qcow2" || true
            sleep 2
        fi
    done
    
    # Rename the base VM disk to our base image
    echo -e "${BLUE}Creating final base image...${NC}"
    if [ -f "${VM_DIR}/slurm-base.qcow2" ]; then
        cp "${VM_DIR}/slurm-base.qcow2" "${BASE_IMAGE}" || {
            echo -e "${RED}Failed to create base image.${NC}"
            exit 1
        }
        echo -e "${GREEN}Base image created successfully: ${BASE_IMAGE}${NC}"
        qemu-img info "${BASE_IMAGE}"
    else
        echo -e "${RED}Source VM disk not found: ${VM_DIR}/slurm-base.qcow2${NC}"
        exit 1
    fi
}

# Setup command
function cmd_setup {
    download_ubuntu_image
    prepare_environment
    install_cloud_init_tools
    setup_bridge
}

# Build base image command
function cmd_build_base {
    cmd_setup
    build_base_image
    echo -e "${GREEN}Base image with Slurm pre-installed is ready.${NC}"
    echo -e "${GREEN}Base image location: ${BASE_IMAGE}${NC}"
}

# Create cluster command
function cmd_create {
    # Check if base image exists
    if [ ! -f "${BASE_IMAGE}" ]; then
        echo -e "${RED}Base image not found. Please run 'build-base' first.${NC}"
        exit 1
    fi
    
    echo -e "${BLUE}Creating cluster VMs from base image...${NC}"
    
    # Create controller VM
    create_cloud_init "controller" "${CONTROLLER_IP}"
    create_vm_disk "controller" 40 "${BASE_IMAGE}"
    
    # Create compute node VMs
    create_cloud_init "node1" "${NODE1_IP}"
    create_vm_disk "node1" 40 "${BASE_IMAGE}"
    
    create_cloud_init "node2" "${NODE2_IP}"
    create_vm_disk "node2" 40 "${BASE_IMAGE}"
    
    echo -e "${GREEN}All VMs created successfully.${NC}"
}

# Start all command
function cmd_start_all {
    start_vm "controller" "${CONTROLLER_MEM}" "${CONTROLLER_CPU}"
    start_vm "node1" "${COMPUTE_MEM}" "${COMPUTE_CPU}"
    start_vm "node2" "${COMPUTE_MEM}" "${COMPUTE_CPU}"
    
    echo -e "${GREEN}All VMs started.${NC}"
}

# Stop all command
function cmd_stop_all {
    stop_vm "controller"
    stop_vm "node1"
    stop_vm "node2"
    
    echo -e "${GREEN}All VMs stopped.${NC}"
}

# Stop a VM
function stop_vm {
    local vm_name=$1
    
    echo -e "${BLUE}Stopping ${vm_name}...${NC}"
    
    # Check if VM is running
    if ! pgrep -f "${vm_name}.qcow2" > /dev/null; then
        echo -e "${YELLOW}${vm_name} is not running.${NC}"
        return
    fi
    
    # Try graceful shutdown first via QMP
    if [ -S "${VM_DIR}/${vm_name}.qmp" ]; then
        echo -e "${BLUE}Sending shutdown command via QMP...${NC}"
        echo '{ "execute": "qmp_capabilities" }' | nc -U "${VM_DIR}/${vm_name}.qmp" 2>/dev/null
        echo '{ "execute": "system_powerdown" }' | nc -U "${VM_DIR}/${vm_name}.qmp" 2>/dev/null
        
        # Wait for VM to stop gracefully
        echo -e "${BLUE}Waiting for ${vm_name} to stop...${NC}"
        for i in {1..30}; do
            if ! pgrep -f "${vm_name}.qcow2" > /dev/null; then
                echo -e "${GREEN}${vm_name} stopped gracefully.${NC}"
                return
            fi
            sleep 1
        done
    fi
    
    # If we get here, VM didn't stop gracefully or QMP wasn't available
    echo -e "${YELLOW}Forcing ${vm_name} to stop...${NC}"
    if pgrep -f "${vm_name}.qcow2" > /dev/null; then
        pkill -f "${vm_name}.qcow2" || true
        sleep 2
        
        # If still running, use SIGKILL
        if pgrep -f "${vm_name}.qcow2" > /dev/null; then
            echo -e "${RED}VM ${vm_name} didn't respond to normal termination. Using SIGKILL...${NC}"
            pkill -9 -f "${vm_name}.qcow2" || true
        fi
    fi
    
    echo -e "${GREEN}${vm_name} stopped.${NC}"
}

# Check VM status
function check_vm_status {
    local vm_name=$1
    
    # Check if VM process is running
    if pgrep -f "${vm_name}.qcow2" > /dev/null; then
        echo -e "${GREEN}${vm_name} is running.${NC}"
    else
        echo -e "${RED}${vm_name} is not running.${NC}"
    fi
}

# Status command
function cmd_status {
    check_vm_status "controller"
    check_vm_status "node1"
    check_vm_status "node2"
}

# Provision command
function cmd_provision {
    echo -e "${BLUE}Provisioning cluster sequentially...${NC}"
    
    # Check if VMs are running
    check_vm_status "controller" || { echo -e "${RED}Controller is not running. Start it first.${NC}"; return 1; }
    check_vm_status "node1" || { echo -e "${RED}Node1 is not running. Start it first.${NC}"; return 1; }
    check_vm_status "node2" || { echo -e "${RED}Node2 is not running. Start it first.${NC}"; return 1; }
    
    # Step 1: Provision controller first
    echo -e "${BLUE}Step 1/3: Setting up controller...${NC}"
    wait_for_ssh "controller" "${CONTROLLER_IP}" || return 1
    
    # Copy scripts and sample jobs to controller
    echo -e "${BLUE}Copying scripts and sample jobs to controller...${NC}"
    rsync -avz -e "ssh -o StrictHostKeyChecking=no" ./scripts/ ubuntu@${CONTROLLER_IP}:~/scripts/
    rsync -avz -e "ssh -o StrictHostKeyChecking=no" ./sample-jobs/ ubuntu@${CONTROLLER_IP}:~/sample-jobs/
    
    # Run controller setup script
    echo -e "${BLUE}Running controller setup script...${NC}"
    ssh -o StrictHostKeyChecking=no ubuntu@${CONTROLLER_IP} "cd ~ && chmod +x ~/scripts/*.sh && sudo ~/scripts/setup-controller.sh" || { 
        echo -e "${RED}Controller setup failed. Cannot continue with compute nodes.${NC}"; 
        return 1; 
    }
    
    # Create a marker file in the shared directory to indicate controller is ready
    ssh -o StrictHostKeyChecking=no ubuntu@${CONTROLLER_IP} "sudo touch /shared/controller_ready" || {
        echo -e "${YELLOW}Warning: Could not create controller ready marker in shared directory.${NC}";
    }
    
    # Step 2: Provision node1 after controller is ready
    echo -e "${BLUE}Step 2/3: Setting up compute node1...${NC}"
    wait_for_ssh "node1" "${NODE1_IP}" || return 1
    
    # Mount NFS share from controller on node1
    echo -e "${BLUE}Mounting NFS share from controller on node1...${NC}"
    ssh -o StrictHostKeyChecking=no ubuntu@${NODE1_IP} "sudo mkdir -p /shared && \
        sudo mount -t nfs ${CONTROLLER_IP}:/shared /shared || echo 'Warning: NFS mount failed'"
    
    # Check if controller is ready by looking for the marker file
    ssh -o StrictHostKeyChecking=no ubuntu@${NODE1_IP} "test -f /shared/controller_ready" || {
        echo -e "${YELLOW}Warning: Controller ready marker not found. Controller may not be fully set up.${NC}";
        echo -e "${YELLOW}Continuing anyway, but compute node setup might fail.${NC}";
    }
    
    # Copy setup scripts from shared directory
    echo -e "${BLUE}Setting up node1...${NC}"
    ssh -o StrictHostKeyChecking=no ubuntu@${NODE1_IP} "cd ~ && \
        [ -d /shared/scripts ] && sudo cp -r /shared/scripts . || \
        echo 'Warning: Scripts not found in shared folder, using direct copy'"
    
    # If scripts not found in shared folder, copy them directly
    ssh -o StrictHostKeyChecking=no ubuntu@${NODE1_IP} "test -d ~/scripts" || {
        echo -e "${YELLOW}Warning: Scripts not found on node1, copying directly...${NC}";
        rsync -avz -e "ssh -o StrictHostKeyChecking=no" ./scripts/ ubuntu@${NODE1_IP}:~/scripts/
    }
    
    # Run node1 setup script
    ssh -o StrictHostKeyChecking=no ubuntu@${NODE1_IP} "cd ~ && \
        chmod +x scripts/*.sh && sudo scripts/setup-compute.sh 1" || {
        echo -e "${YELLOW}Warning: Node1 setup had issues. Continuing anyway.${NC}";
    }
    
    # Step 3: Provision node2 after node1 is done
    echo -e "${BLUE}Step 3/3: Setting up compute node2...${NC}"
    wait_for_ssh "node2" "${NODE2_IP}" || return 1
    
    # Mount NFS share from controller on node2
    echo -e "${BLUE}Mounting NFS share from controller on node2...${NC}"
    ssh -o StrictHostKeyChecking=no ubuntu@${NODE2_IP} "sudo mkdir -p /shared && \
        sudo mount -t nfs ${CONTROLLER_IP}:/shared /shared || echo 'Warning: NFS mount failed'"
    
    # Copy setup scripts from shared directory
    echo -e "${BLUE}Setting up node2...${NC}"
    ssh -o StrictHostKeyChecking=no ubuntu@${NODE2_IP} "cd ~ && \
        [ -d /shared/scripts ] && sudo cp -r /shared/scripts . || \
        echo 'Warning: Scripts not found in shared folder, using direct copy'"
    
    # If scripts not found in shared folder, copy them directly
    ssh -o StrictHostKeyChecking=no ubuntu@${NODE2_IP} "test -d ~/scripts" || {
        echo -e "${YELLOW}Warning: Scripts not found on node2, copying directly...${NC}";
        rsync -avz -e "ssh -o StrictHostKeyChecking=no" ./scripts/ ubuntu@${NODE2_IP}:~/scripts/
    }
    
    # Run node2 setup script
    ssh -o StrictHostKeyChecking=no ubuntu@${NODE2_IP} "cd ~ && \
        chmod +x scripts/*.sh && sudo scripts/setup-compute.sh 2" || {
        echo -e "${YELLOW}Warning: Node2 setup had issues.${NC}";
    }
    
    # Final verification
    echo -e "${BLUE}Waiting for services to initialize...${NC}"
    sleep 60
    
    echo -e "${GREEN}Provisioning complete.${NC}"
    echo -e "${BLUE}Verifying all nodes are responsive...${NC}"
    
    # Verify controller
    ssh -o StrictHostKeyChecking=no ubuntu@${CONTROLLER_IP} "hostname && uptime" || {
        echo -e "${RED}Controller is not responding.${NC}";
    }
    
    # Verify node1
    ssh -o StrictHostKeyChecking=no ubuntu@${NODE1_IP} "hostname && uptime" || {
        echo -e "${RED}Node1 is not responding.${NC}";
    }
    
    # Verify node2
    ssh -o StrictHostKeyChecking=no ubuntu@${NODE2_IP} "hostname && uptime" || {
        echo -e "${RED}Node2 is not responding.${NC}";
    }
}

# Clean command
function cmd_clean {
    cmd_stop_all || true
    
    echo -e "${BLUE}Cleaning up VMs and data...${NC}"
    
    # Remove socket files
    echo -e "${BLUE}Removing socket files...${NC}"
    rm -f /tmp/qga-*.sock
    
    # Remove VM files
    echo -e "${BLUE}Removing VM files...${NC}"
    rm -f "${VM_DIR}/"*.qcow2 "${VM_DIR}/"*.qmp
    rm -rf "${VM_DIR}/cloud-init"
    
    # Optionally, keep the Ubuntu cloud image to speed up future builds
    echo -e "${GREEN}Cleanup complete. Ubuntu cloud image preserved for future builds.${NC}"
    echo -e "${YELLOW}To remove the Ubuntu cloud image as well, run: rm -f ${UBUNTU_IMAGE_PATH}${NC}"
}

# Simplified SSH command function
function cmd_ssh {
    local node=$1
    local ip
    
    case $node in
        controller) ip="${CONTROLLER_IP}" ;;
        node1) ip="${NODE1_IP}" ;;
        node2) ip="${NODE2_IP}" ;;
        *)
            echo -e "${RED}Invalid node: ${node}. Use controller, node1, or node2.${NC}"
            return 1
            ;;
    esac
    
    echo -e "${BLUE}Connecting to ${node} (${ip}) via SSH...${NC}"
    ssh -o StrictHostKeyChecking=no ubuntu@${ip}
}

# Add a function to handle debugging VM issues
function debug_vm {
    local vm_name=$1
    local vm_ip=$2
    
    echo -e "${YELLOW}Debugging VM ${vm_name}...${NC}"
    
    # Get VM process ID
    local VM_PID=$(pgrep -f "${vm_name}.qcow2" | head -1)
    if [ -z "$VM_PID" ]; then
        echo -e "${RED}VM ${vm_name} is not running!${NC}"
        return 1
    fi
    
    echo -e "${BLUE}VM ${vm_name} process: ${VM_PID}${NC}"
    
    # Check bridge status
    echo -e "${BLUE}Bridge status:${NC}"
    ip link show ${BRIDGE_NAME}
    ip addr show ${BRIDGE_NAME}
    
    # Try to access VM using serial console (optional - this adds a serial console to our VM command)
    echo -e "${YELLOW}Attempting to access VM console...${NC}"
    echo -e "${YELLOW}Note: You may need to kill this process with Ctrl+C when done${NC}"
    echo -e "${YELLOW}After connecting, you can log in with username 'ubuntu' and no password${NC}"
    
    # Return success
    return 0
}

# Create a VM debug command 
function cmd_debug {
    local vm_name=$1
    
    if [ -z "$vm_name" ]; then
        echo -e "${RED}Please specify a VM name to debug (e.g., slurm-base, controller, node1, node2)${NC}"
        return 1
    fi
    
    local vm_ip
    case $vm_name in
        controller) vm_ip="${CONTROLLER_IP}" ;;
        node1) vm_ip="${NODE1_IP}" ;;
        node2) vm_ip="${NODE2_IP}" ;;
        slurm-base) vm_ip="${BASE_IP}" ;;
        *)
            echo -e "${RED}Unknown VM name: ${vm_name}${NC}"
            return 1
            ;;
    esac
    
    debug_vm "$vm_name" "$vm_ip"
}

# Add an interactive command to directly start a VM and connect to its console
function cmd_console {
    local vm_name=$1
    
    if [ -z "$vm_name" ]; then
        echo -e "${RED}Please specify a VM name (e.g., slurm-base, controller, node1, node2)${NC}"
        return 1
    fi
    
    # Stop the VM if it's already running
    if pgrep -f "${vm_name}.qcow2" > /dev/null; then
        echo -e "${YELLOW}VM ${vm_name} is already running. Stopping it first...${NC}"
        stop_vm "$vm_name"
        sleep 2
    fi
    
    # Set interactive mode
    export INTERACTIVE=1
    
    # Determine memory and CPU based on VM name
    local memory
    local cpus
    case $vm_name in
        controller) memory="${CONTROLLER_MEM}"; cpus="${CONTROLLER_CPU}" ;;
        node1|node2) memory="${COMPUTE_MEM}"; cpus="${COMPUTE_CPU}" ;;
        slurm-base) memory="${BASE_MEM}"; cpus="${BASE_CPU}" ;;
        *)
            echo -e "${RED}Unknown VM name: ${vm_name}${NC}"
            return 1
            ;;
    esac
    
    # Use modified start_vm to connect directly to console
    echo -e "${BLUE}Starting ${vm_name} with console access (Ctrl+C to exit)...${NC}"
    QEMU_CMD="qemu-system-x86_64"
    KVM_ARGS="-machine type=q35,accel=kvm -cpu host"
    
    # Check KVM
    if ! [ -c /dev/kvm ] || ! [ -w /dev/kvm ]; then
        KVM_ARGS="-machine type=q35 -cpu max"
    fi
    
    # Network
    NETWORK_ARGS="-nic bridge,br=${BRIDGE_NAME},model=virtio"
    
    # Non-daemonized with console
    echo -e "${YELLOW}Starting VM in console mode. Log in with username 'ubuntu' (no password).${NC}"
    echo -e "${YELLOW}Use Ctrl+A x to exit QEMU.${NC}"
    
    $QEMU_CMD $KVM_ARGS -m $memory -smp $cpus \
        -drive file=${VM_DIR}/${vm_name}.qcow2,format=qcow2 \
        -drive file=${CLOUD_INIT_DIR}/${vm_name}-seed.iso,format=raw \
        $NETWORK_ARGS \
        -device virtio-serial \
        -chardev stdio,mux=on,id=char0 \
        -mon chardev=char0,mode=readline \
        -device isa-serial,chardev=char0 \
        -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0 \
        -chardev socket,path=/tmp/qga-${vm_name}.sock,server=on,wait=off,id=qga0 \
        -display none -no-reboot
    
    # Reset interactive mode
    unset INTERACTIVE
}

# Let's also add a network testing function to diagnose bridge issues
function cmd_network_check {
    echo -e "${BLUE}Checking network setup...${NC}"
    
    # Check if bridge exists
    echo -e "${BLUE}Bridge status:${NC}"
    if ip link show ${BRIDGE_NAME} &> /dev/null; then
        ip link show ${BRIDGE_NAME}
        ip addr show ${BRIDGE_NAME}
    else
        echo -e "${RED}Bridge ${BRIDGE_NAME} does not exist!${NC}"
        echo -e "${YELLOW}Try running 'sudo ./qemu-cluster.sh setup' to create it${NC}"
        return 1
    fi
    
    # Check if bridge is in QEMU allowed bridges
    echo -e "${BLUE}QEMU bridge configuration:${NC}"
    if [ -f "$BRIDGE_CONF" ]; then
        echo -e "${GREEN}Bridge config exists: $BRIDGE_CONF${NC}"
        if grep -q "allow $BRIDGE_NAME" "$BRIDGE_CONF"; then
            echo -e "${GREEN}Bridge $BRIDGE_NAME is allowed in QEMU config${NC}"
        else
            echo -e "${RED}Bridge $BRIDGE_NAME is NOT allowed in QEMU config!${NC}"
            echo -e "${YELLOW}Run 'sudo ./qemu-cluster.sh setup' to fix this${NC}"
        fi
        echo "Current bridge config:"
        cat "$BRIDGE_CONF"
    else
        echo -e "${RED}Bridge config file $BRIDGE_CONF does not exist!${NC}"
        echo -e "${YELLOW}Run 'sudo ./qemu-cluster.sh setup' to create it${NC}"
    fi
    
    # Check if bridge helper has proper permissions
    echo -e "${BLUE}QEMU bridge helper permissions:${NC}"
    if [ -f "$QEMU_BRIDGE_HELPER" ]; then
        ls -l "$QEMU_BRIDGE_HELPER"
        if [ -u "$QEMU_BRIDGE_HELPER" ]; then
            echo -e "${GREEN}Bridge helper has setuid bit set${NC}"
        else
            echo -e "${RED}Bridge helper does NOT have setuid bit set!${NC}"
            echo -e "${YELLOW}Run 'sudo chmod u+s $QEMU_BRIDGE_HELPER' to fix${NC}"
        fi
    else
        echo -e "${RED}QEMU bridge helper not found at $QEMU_BRIDGE_HELPER!${NC}"
        echo -e "${YELLOW}Try finding it with: find /usr -name qemu-bridge-helper${NC}"
    fi
    
    # Check IP forwarding
    echo -e "${BLUE}IP forwarding status:${NC}"
    if sysctl -a 2>/dev/null | grep -q "net.ipv4.ip_forward = 1"; then
        echo -e "${GREEN}IP forwarding is enabled${NC}"
    else
        echo -e "${RED}IP forwarding is NOT enabled!${NC}"
        echo -e "${YELLOW}Run 'sudo sysctl -w net.ipv4.ip_forward=1' to enable${NC}"
    fi
    
    # Check NAT rules
    echo -e "${BLUE}NAT rules status:${NC}"
    if sudo iptables -t nat -L POSTROUTING -v | grep -q "${BRIDGE_NETWORK}"; then
        echo -e "${GREEN}NAT rule for ${BRIDGE_NETWORK} exists${NC}"
        sudo iptables -t nat -L POSTROUTING -v | grep "${BRIDGE_NETWORK}"
    else
        echo -e "${RED}NAT rule for ${BRIDGE_NETWORK} NOT found!${NC}"
        echo -e "${YELLOW}Run setup to create the NAT rule${NC}"
    fi
    
    echo -e "${GREEN}Network check complete.${NC}"
}

# Main command handler
case $1 in
    setup)
        download_ubuntu_image
        prepare_environment
        setup_bridge
        ;;
    build-base)
        cmd_build_base
        ;;
    create)
        cmd_create
        ;;
    start-all)
        cmd_start_all
        ;;
    stop-all)
        cmd_stop_all
        ;;
    status)
        cmd_status
        ;;
    provision)
        cmd_provision
        ;;
    clean)
        cmd_clean
        ;;
    ssh)
        cmd_ssh $2
        ;;
    debug)
        cmd_debug $2
        ;;
    console)
        cmd_console $2
        ;;
    network-check)
        cmd_network_check
        ;;
    help|--help|-h)
        show_usage
        ;;
    *)
        echo -e "${RED}Unknown command: $1${NC}"
        show_usage
        exit 1
        ;;
esac
