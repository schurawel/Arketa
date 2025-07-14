#!/bin/bash
# QEMU Cluster Build Script - Build and deploy Slurm cluster using QEMU/KVM

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
VM_DIR="/home/thinclient/Documents/PrimedSLURM/qemu-vms"
BASE_IMAGE="${VM_DIR}/saved-ubuntu-vm.qcow2"
BASE_VM_IMAGE="${VM_DIR}/slurm-base-vm.qcow2"
CONTROLLER_IMAGE="${VM_DIR}/slurm-controller.qcow2"
NODE1_IMAGE="${VM_DIR}/slurm-node1.qcow2"
NODE2_IMAGE="${VM_DIR}/slurm-node2.qcow2"
# Use home directory for temp files where user has write permissions
TMP_DIR="/home/thinclient/Documents/PrimedSLURM/tmp/qemu-build"
SCRIPTS_DIR="/home/thinclient/Documents/PrimedSLURM/scripts"
SAMPLE_JOBS_DIR="/home/thinclient/Documents/PrimedSLURM/sample-jobs"

# Network configuration
BRIDGE_NAME="vswitch0"
CONTROLLER_IP="192.168.7.10"
NODE1_IP="192.168.7.11"
NODE2_IP="192.168.7.12"
CONTROLLER_MAC="52:54:00:12:34:10"
NODE1_MAC="52:54:00:12:34:11"
NODE2_MAC="52:54:00:12:34:12"

# VM credentials
VM_USERNAME="ubuntu"
VM_PASSWORD="ubuntu"


# Function to terminate all running QEMU processes
kill_qemu_processes() {
    echo -e "Removing temporary files"
    rm -rf ./qemu-vms/tmp/ 2>/dev/null || true
    echo -e "${YELLOW}Checking for running QEMU VM instances...${NC}"
    QEMU_PROCS=$(pgrep -l qemu-system)
    
    if [ -n "$QEMU_PROCS" ]; then
        echo -e "${RED}Found running QEMU processes:${NC}"
        echo "$QEMU_PROCS"
        
        echo -e "${YELLOW}Terminating all running QEMU VMs...${NC}"
        pkill qemu-system || pkill qemu-system
        
        # Wait for processes to terminate
        sleep 2
        
        # Check if any processes are still running
        if pgrep qemu-system > /dev/null; then
            echo -e "${RED}Some QEMU processes couldn't be terminated. Forcing...${NC}"
            pkill -9 qemu-system || pkill -9 qemu-system
            sleep 1
        fi
        
        echo -e "${GREEN}All QEMU processes terminated.${NC}"
    else
        echo -e "${GREEN}No running QEMU processes found.${NC}"
    fi
}

kill_qemu_processes

# Function to check if image exists
check_image() {
    local image=$1
    if [ -f "$image" ]; then
        return 0
    else
        return 1
    fi
}

# Ensure necessary directories exist with proper permissions
create_directories() {
    echo -e "${BLUE}Creating necessary directories...${NC}"
    mkdir -p "$TMP_DIR"
    
    # Ensure VM directory exists
    if [ ! -d "$VM_DIR" ]; then
        echo -e "${YELLOW}VM directory doesn't exist, creating it...${NC}"
        mkdir -p "$VM_DIR"
    fi
    
    # Check write permissions
    if [ ! -w "$TMP_DIR" ] || [ ! -w "$VM_DIR" ]; then
        echo -e "${RED}Error: No write permissions to required directories.${NC}"
        echo -e "${YELLOW}Try running: sudo mkdir -p ${VM_DIR} && sudo chown $(whoami):$(whoami) ${VM_DIR}${NC}"
        exit 1
    fi
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
# Function to build base image with Slurm
build_base_image() {
    echo -e "${BLUE}=== PHASE 1: Building Slurm Base Image ===${NC}"
    
    # Create necessary directories first
    create_directories
    
    # Check if base image already exists
    if check_image "$BASE_VM_IMAGE"; then
        echo -e "${YELLOW}Base image already exists. Skipping build.${NC}"
        return 0
    fi
    
    # Check if Ubuntu base image exists
    if ! check_image "$BASE_IMAGE"; then
        echo -e "${RED}Base Ubuntu image not found. Please run ./direct-image.sh first.${NC}"
        exit 1
    fi
    
    # Create a copy of base image for building
    echo -e "${BLUE}Creating base VM image...${NC}"
    qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMAGE" "$BASE_VM_IMAGE" 50G || {
        echo -e "${RED}Failed to create base VM image. Check permissions.${NC}"
        exit 1
    }
    
    # Kill any existing QEMU processes for base VM
    pkill -f "qemu.*slurm-base" || true
    sleep 2
    
    # Create base VM script for xterm
    BASE_SCRIPT="${TMP_DIR}/start_base.sh"
    cat > "${BASE_SCRIPT}" <<EOF
#!/bin/bash
echo "Starting Slurm base VM for compilation..."

export QEMU_AUDIO_DRV=none

# Run QEMU with user networking for SSH access
exec qemu-system-x86_64 -m 4096 -smp 4 \\
    -enable-kvm \\
    -cpu host \\
    -drive file="$BASE_VM_IMAGE",format=qcow2 \\
    -netdev user,id=net0,hostfwd=tcp::2222-:22 \\
    -device virtio-net-pci,netdev=net0 \\
    -nographic \\
    -serial mon:stdio
EOF
    chmod +x "${BASE_SCRIPT}"
    
    # Start base VM in xterm
    echo -e "${BLUE}Starting base VM in xterm for Slurm compilation...${NC}"
    xterm -title "Slurm Base VM" -e "${BASE_SCRIPT}" &
    
    # Get PID of the xterm process
    BASE_XTERM_PID=$!
    
    # Wait for VM to boot
    echo -e "${BLUE}Waiting for base VM to boot...${NC}"
    sleep 20
    
    # Use the improved wait_for_ssh function
    if ! wait_for_ssh "localhost" "2222" "base VM"; then
        echo -e "${RED}Failed to connect to base VM. Check VM console for errors.${NC}"
        exit 1
    fi
    
    # Configure hostname via SSH
    echo -e "${BLUE}Configuring hostname for base VM...${NC}"
    sshpass -p "$VM_PASSWORD" ssh -o StrictHostKeyChecking=no -p 2222 "${VM_USERNAME}@localhost" << EOF
sudo hostnamectl set-hostname slurm-base
EOF
    
    # Copy scripts and source code to VM
    echo -e "${BLUE}Copying setup scripts and source code...${NC}"
    sshpass -p "$VM_PASSWORD" scp -o StrictHostKeyChecking=no -P 2222 -r "$SCRIPTS_DIR" "${VM_USERNAME}@localhost:~/"
    
    # Copy Slurm source if available
    if [ -d "/home/thinclient/Documents/PrimedSLURM/tmp/slurm" ]; then
        echo -e "${BLUE}Copying Slurm source code...${NC}"
        sshpass -p "$VM_PASSWORD" scp -o StrictHostKeyChecking=no -P 2222 -r "/home/thinclient/Documents/PrimedSLURM/tmp/slurm" "${VM_USERNAME}@localhost:~/slurm-src"
    fi
    
    # Run setup-base.sh script
    echo -e "${BLUE}Running base setup script...${NC}"
    sshpass -p "$VM_PASSWORD" ssh -o StrictHostKeyChecking=no -p 2222 "${VM_USERNAME}@localhost" << 'EOF'
sudo chmod +x ~/scripts/setup-base.sh
sudo ~/scripts/setup-base.sh --clean-for-imaging
echo "Base setup completed!"
EOF
    
    # Shutdown the VM
    echo -e "${BLUE}Shutting down base VM...${NC}"
    sshpass -p "$VM_PASSWORD" ssh -o StrictHostKeyChecking=no -p 2222 "${VM_USERNAME}@localhost" "sudo poweroff"
    
    # Wait for VM to shutdown
    sleep 20
    wait $BASE_PID 2>/dev/null || true
    
    echo -e "${GREEN}Base image built successfully!${NC}"
}

# Function to create and configure controller VM
create_controller() {
    echo -e "${BLUE}=== PHASE 2: Creating Controller VM ===${NC}"
    
    # Check if base image exists first
    if ! check_image "$BASE_VM_IMAGE"; then
        echo -e "${RED}Error: Base VM image not found. You must run build-base first!${NC}"
        exit 1
    fi
    
    # Create controller image if it doesn't exist
    if ! check_image "$CONTROLLER_IMAGE"; then
        echo -e "${BLUE}Creating controller VM image from base...${NC}"
        qemu-img create -f qcow2 -F qcow2 -b "$BASE_VM_IMAGE" "$CONTROLLER_IMAGE" 50G || {
            echo -e "${RED}Failed to create controller VM image. Check permissions.${NC}"
            exit 1
        }
    else
        echo -e "${YELLOW}Controller image already exists. Using existing image.${NC}"
    fi
    
    echo -e "${GREEN}Controller VM image created successfully!${NC}"
}

# Function to create compute node VMs
create_compute_nodes() {
    echo -e "${BLUE}=== PHASE 3: Creating Compute Node VMs ===${NC}"
    
    # Check if base image exists first
    if ! check_image "$BASE_VM_IMAGE"; then
        echo -e "${RED}Error: Base VM image not found. You must run build-base first!${NC}"
        exit 1
    fi
    
    # Create node1 image if it doesn't exist
    if ! check_image "$NODE1_IMAGE"; then
        echo -e "${BLUE}Creating node1 VM image from base...${NC}"
        qemu-img create -f qcow2 -F qcow2 -b "$BASE_VM_IMAGE" "$NODE1_IMAGE" 50G || {
            echo -e "${RED}Failed to create node1 VM image. Check permissions.${NC}"
            exit 1
        }
    else
        echo -e "${YELLOW}Node1 image already exists. Using existing image.${NC}"
    fi
    
    # Create node2 image if it doesn't exist
    if ! check_image "$NODE2_IMAGE"; then
        echo -e "${BLUE}Creating node2 VM image from base...${NC}"
        qemu-img create -f qcow2 -F qcow2 -b "$BASE_VM_IMAGE" "$NODE2_IMAGE" 50G || {
            echo -e "${RED}Failed to create node2 VM image. Check permissions.${NC}"
            exit 1
        }
    else
        echo -e "${YELLOW}Node2 image already exists. Using existing image.${NC}"
    fi
    
    echo -e "${GREEN}Compute node VM images created successfully!${NC}"
}

# Function to start cluster VMs
start_cluster_vms() {
    echo -e "${BLUE}=== PHASE 4: Starting Cluster VMs ===${NC}"
    
    # Check if all VM images exist
    if ! check_image "$CONTROLLER_IMAGE"; then
        echo -e "${RED}Error: Controller VM image not found. You must run build-controller first!${NC}"
        exit 1
    fi
    
    if ! check_image "$NODE1_IMAGE" || ! check_image "$NODE2_IMAGE"; then
        echo -e "${RED}Error: Compute node VM images not found. You must run build-nodes first!${NC}"
        exit 1
    fi
    
    # Ensure virtual switch is setup
    setup_virtual_switch
    
    # Set TAP permissions properly before starting VMs
    echo -e "${BLUE}Setting proper permissions for TAP devices...${NC}"
    sudo ip tuntap add dev tap0 mode tap user $(whoami)
    sudo ip link set dev tap0 up
    sudo ovs-vsctl --may-exist add-port $BRIDGE_NAME tap0
    
    sudo ip tuntap add dev tap1 mode tap user $(whoami)
    sudo ip link set dev tap1 up
    sudo ovs-vsctl --may-exist add-port $BRIDGE_NAME tap1
    
    sudo ip tuntap add dev tap2 mode tap user $(whoami)
    sudo ip link set dev tap2 up
    sudo ovs-vsctl --may-exist add-port $BRIDGE_NAME tap2
    
    sudo chown $(whoami) /dev/net/tun
    
    # Create VM start scripts for xterm windows
    
    # Controller VM script - removed sudo from exec line
    CONTROLLER_SCRIPT="${TMP_DIR}/start_controller.sh"
    cat > "${CONTROLLER_SCRIPT}" <<EOF
#!/bin/bash
echo "Starting Slurm controller VM..."

export QEMU_AUDIO_DRV=none

# Run QEMU with TAP networking (removed sudo from exec line)
exec qemu-system-x86_64 -m 4096 -smp 4 \\
    -enable-kvm \\
    -cpu host \\
    -drive file="${CONTROLLER_IMAGE}",format=qcow2 \\
    -netdev tap,id=net0,ifname=tap0,script=no,downscript=no \\
    -device virtio-net-pci,netdev=net0,mac=${CONTROLLER_MAC} \\
    -nographic \\
    -serial mon:stdio \\
    -name "slurm-controller"
EOF
    chmod +x "${CONTROLLER_SCRIPT}"
    
    # Node1 VM script - removed sudo from exec line
    NODE1_SCRIPT="${TMP_DIR}/start_node1.sh"
    cat > "${NODE1_SCRIPT}" <<EOF
#!/bin/bash
echo "Starting Slurm node1 VM..."

export QEMU_AUDIO_DRV=none

# Run QEMU with TAP networking (removed sudo from exec line)
exec qemu-system-x86_64 -m 4096 -smp 4 \\
    -enable-kvm \\
    -cpu host \\
    -drive file="${NODE1_IMAGE}",format=qcow2 \\
    -netdev tap,id=net0,ifname=tap1,script=no,downscript=no \\
    -device virtio-net-pci,netdev=net0,mac=${NODE1_MAC} \\
    -nographic \\
    -serial mon:stdio \\
    -name "slurm-node1"
EOF
    chmod +x "${NODE1_SCRIPT}"
    
    # Node2 VM script - removed sudo from exec line
    NODE2_SCRIPT="${TMP_DIR}/start_node2.sh"
    cat > "${NODE2_SCRIPT}" <<EOF
#!/bin/bash
echo "Starting Slurm node2 VM..."

export QEMU_AUDIO_DRV=none

# Run QEMU with TAP networking (removed sudo from exec line)
exec qemu-system-x86_64 -m 4096 -smp 4 \\
    -enable-kvm \\
    -cpu host \\
    -drive file="${NODE2_IMAGE}",format=qcow2 \\
    -netdev tap,id=net0,ifname=tap2,script=no,downscript=no \\
    -device virtio-net-pci,netdev=net0,mac=${NODE2_MAC} \\
    -nographic \\
    -serial mon:stdio \\
    -name "slurm-node2"
EOF
    chmod +x "${NODE2_SCRIPT}"
    
    # Start VMs in xterm windows
    echo -e "${BLUE}Starting controller VM in xterm...${NC}"
    xterm -title "Slurm Controller" -e "${CONTROLLER_SCRIPT}" &
    
    sleep 5
    
    echo -e "${BLUE}Starting node1 VM in xterm...${NC}"
    xterm -title "Slurm Node1" -e "${NODE1_SCRIPT}" &
    
    sleep 5
    
    echo -e "${BLUE}Starting node2 VM in xterm...${NC}"
    xterm -title "Slurm Node2" -e "${NODE2_SCRIPT}" &
    
    echo -e "${BLUE}Waiting for VMs to boot...${NC}"
    sleep 20
}

# Function to configure network on VMs
configure_vm_network() {
    local hostname=$1
    local ip=$2
    local mac=$3
    
    echo -e "${BLUE}Configuring network for ${hostname}...${NC}"
    
    # Restart VM with new cloud-init ISO
    echo -e "${BLUE}Restarting ${hostname} VM with new network configuration...${NC}"
    local vm_pid=$(pgrep -f "qemu.*${hostname}")
    if [ -n "$vm_pid" ]; then
        sudo kill -9 "$vm_pid" || true
        sleep 5
    fi
    
    # Start VM with new cloud-init ISO
    qemu-system-x86_64 -m 4096 -smp 4 \
        -enable-kvm \
        -cpu host \
        -drive file="${VM_DIR}/${hostname}.qcow2",format=qcow2 \
        -netdev tap,id=net0,ifname="tap${hostname: -1}",script=no,downscript=no \
        -device virtio-net-pci,netdev=net0,mac="$mac" \
        -nographic \
        -serial mon:stdio \
        -name "$hostname" &
    
    echo -e "${GREEN}Network configuration for ${hostname} completed.${NC}"
}

# Function to provision cluster nodes
provision_cluster() {
    echo -e "${BLUE}=== PHASE 4: Provisioning Cluster Nodes ===${NC}"
    
    # Wait for all VMs to be network accessible
    configure_vm_network "controller" "$CONTROLLER_IP" "$CONTROLLER_MAC"
    configure_vm_network "node1" "$NODE1_IP" "$NODE1_MAC"
    configure_vm_network "node2" "$NODE2_IP" "$NODE2_MAC"
    
    # Copy scripts to controller
    echo -e "${BLUE}Copying scripts to controller...${NC}"
    sshpass -p "$VM_PASSWORD" scp -o StrictHostKeyChecking=no -r "$SCRIPTS_DIR" "${VM_USERNAME}@${CONTROLLER_IP}:~/"
    sshpass -p "$VM_PASSWORD" scp -o StrictHostKeyChecking=no -r "$SAMPLE_JOBS_DIR" "${VM_USERNAME}@${CONTROLLER_IP}:~/"
    
    # Run controller setup
    echo -e "${BLUE}Setting up controller...${NC}"
    sshpass -p "$VM_PASSWORD" ssh -o StrictHostKeyChecking=no "${VM_USERNAME}@${CONTROLLER_IP}" << 'EOF'
sudo chmod +x ~/scripts/*.sh
sudo ~/scripts/setup-controller.sh
EOF
    
    # Copy scripts to compute nodes via controller's NFS
    echo -e "${BLUE}Preparing compute node files...${NC}"
    sshpass -p "$VM_PASSWORD" ssh -o StrictHostKeyChecking=no "${VM_USERNAME}@${CONTROLLER_IP}" << 'EOF'
sudo cp -r ~/scripts /shared/
sudo cp -r ~/sample-jobs /shared/
sudo chmod -R 755 /shared/scripts /shared/sample-jobs
EOF
    
    # Setup compute nodes
    for i in 1 2; do
        NODE_IP="192.168.7.1${i}"
        echo -e "${BLUE}Setting up node${i}...${NC}"
        
        # Copy scripts directly to node
        sshpass -p "$VM_PASSWORD" scp -o StrictHostKeyChecking=no -r "$SCRIPTS_DIR" "${VM_USERNAME}@${NODE_IP}:~/"
        
        # Run compute setup
        sshpass -p "$VM_PASSWORD" ssh -o StrictHostKeyChecking=no "${VM_USERNAME}@${NODE_IP}" << EOF
sudo chmod +x ~/scripts/*.sh
sudo ~/scripts/setup-compute.sh $i
EOF
    done
    
    echo -e "${GREEN}Cluster provisioning completed!${NC}"
}

# Function to stop all cluster VMs
stop_cluster() {
    echo -e "${YELLOW}Stopping all cluster VMs...${NC}"
    
    # Try graceful shutdown first
    for ip in $CONTROLLER_IP $NODE1_IP $NODE2_IP; do
        sshpass -p "$VM_PASSWORD" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${VM_USERNAME}@${ip}" "sudo poweroff" 2>/dev/null || true
    done
    
    sleep 10
    
    # Force kill any remaining QEMU processes
    pkill -f "qemu.*slurm-controller" || true
    pkill -f "qemu.*slurm-node1" || true
    pkill -f "qemu.*slurm-node2" || true
    
    echo -e "${GREEN}All VMs stopped.${NC}"
}

# Function to clean up cluster
cleanup_cluster() {
    echo -e "${YELLOW}Cleaning up cluster...${NC}"
    
    # Stop VMs first
    stop_cluster
    
    # Remove VM images (but keep base image)
    rm -f "$CONTROLLER_IMAGE" "$NODE1_IMAGE" "$NODE2_IMAGE"
    
    # Remove virtual switch
    if sudo ovs-vsctl br-exists "$BRIDGE_NAME" 2>/dev/null; then
        sudo ovs-vsctl del-br "$BRIDGE_NAME"
    fi
    
    # Remove TAP interfaces
    for i in 0 1 2; do
        sudo ip link delete "tap${i}" 2>/dev/null || true
    done
    
    echo -e "${GREEN}Cluster cleaned up.${NC}"
}

# Function to start controller VM and provision it
start_controller_vm() {
    echo -e "${BLUE}=== Starting and Provisioning Controller VM ===${NC}"
    
    # Check if controller image exists
    if ! check_image "$CONTROLLER_IMAGE"; then
        echo -e "${RED}Controller image not found. Creating it first...${NC}"
        create_controller
    fi
    
    # PHASE 1: First start VM with user networking (port forwarding) for initial setup
    echo -e "${BLUE}PHASE 1: Starting controller VM with user networking for initial setup${NC}"
    
    # Create controller VM script with user networking
    CONTROLLER_USER_SCRIPT="${TMP_DIR}/start_controller_user.sh"
    cat > "${CONTROLLER_USER_SCRIPT}" <<EOF
#!/bin/bash
echo "Starting controller VM with user networking for initial setup..."

export QEMU_AUDIO_DRV=none

# Run QEMU with user networking for SSH access - EXACT SAME COMMAND AS auto_vm_connect_bridge.sh
exec qemu-system-x86_64 -m 4096 -smp 4 \\
    -enable-kvm \\
    -cpu host \\
    -drive file="${CONTROLLER_IMAGE}",format=qcow2 \\
    -netdev user,id=net0,hostfwd=tcp::2222-:22 \\
    -device virtio-net-pci,netdev=net0 \\
    -nographic \\
    -serial mon:stdio
EOF
    chmod +x "${CONTROLLER_USER_SCRIPT}"
    
    # Start controller VM with user networking
    echo -e "${BLUE}Starting controller VM with user networking...${NC}"
    xterm -title "Controller VM" -e "${CONTROLLER_USER_SCRIPT}" &
    CONTROLLER_USER_PID=$!
    
    # Wait for VM to boot
    echo -e "${BLUE}Waiting for controller VM to boot...${NC}"
    sleep 30
    
    # Wait for SSH to be available - using same approach as auto_vm_connect_bridge.sh
    echo -e "${BLUE}Waiting for SSH on controller VM...${NC}"
    if ! wait_for_ssh "localhost" "2222" "controller VM"; then
        echo -e "${RED}Failed to connect to controller VM. Check VM console for errors.${NC}"
        return 1
    fi
    
    # Create directory structure but NO symlink
    echo -e "${BLUE}Preparing for controller setup...${NC}"
    sshpass -p "$VM_PASSWORD" ssh -o StrictHostKeyChecking=no -p 2222 "${VM_USERNAME}@localhost" <<EOF
# Ensure we have a scripts directory
mkdir -p /home/ubuntu/scripts
EOF
    
    # PHASE 2: Configure network settings inside VM
    echo -e "${BLUE}PHASE 2: Configuring network settings inside controller VM${NC}"
    
    # Configure network via SSH - EXACT SAME CODE AS auto_vm_connect_bridge.sh
    sshpass -p "$VM_PASSWORD" ssh -o StrictHostKeyChecking=no -p 2222 "${VM_USERNAME}@localhost" << EOF
# Disable systemd network wait services
echo "Disabling systemd network wait services..."
sudo systemctl disable systemd-networkd-wait-online.service 2>/dev/null || true
sudo systemctl mask systemd-networkd-wait-online.service 2>/dev/null || true

# Disable cloud-init network configuration if it exists
sudo touch /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg 2>/dev/null || true
echo "network: {config: disabled}" | sudo tee /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg 2>/dev/null || true

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
      addresses: [${CONTROLLER_IP}/24]
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
    ip addr add ${CONTROLLER_IP}/24 dev \$IFACE
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

# Set hostname
sudo hostnamectl set-hostname slurm-controller

# Configure hosts file
echo "Configuring hosts file..."
sudo tee /etc/hosts > /dev/null << HOSTS
127.0.0.1 localhost
${CONTROLLER_IP} slurm-controller controller
${NODE1_IP} node1
${NODE2_IP} node2
HOSTS

# Configure SSH
echo "Configuring SSH for password authentication..."
sudo sed -i 's/#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sudo systemctl restart ssh

echo "Network configuration completed for controller VM"
EOF
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}Failed to configure network settings in controller VM.${NC}"
        return 1
    fi
    
    # Shutdown the VM to apply network changes
    echo -e "${BLUE}Shutting down controller VM to apply network changes...${NC}"
    sshpass -p "$VM_PASSWORD" ssh -o StrictHostKeyChecking=no -p 2222 "${VM_USERNAME}@localhost" "sudo poweroff"
    
    # Wait for VM to shutdown
    sleep 20
    
    # PHASE 3: Set up virtual switch
    echo -e "${BLUE}PHASE 3: Setting up virtual switch for controller VM${NC}"
    setup_virtual_switch
    
    # PHASE 4: Start controller VM with virtual switch networking
    echo -e "${BLUE}PHASE 4: Starting controller VM with virtual switch networking${NC}"
    
    # Create controller VM script with TAP networking - modified to avoid password prompts
    CONTROLLER_TAP_SCRIPT="${TMP_DIR}/start_controller_tap.sh"
    cat > "${CONTROLLER_TAP_SCRIPT}" <<EOF
#!/bin/bash
echo "Starting controller VM with virtual switch networking..."

export QEMU_AUDIO_DRV=none

# Run QEMU with TAP networking (removed sudo from exec line)
qemu-system-x86_64 -m 4096 -smp 4 \\
    -enable-kvm \\
    -cpu host \\
    -drive file="${CONTROLLER_IMAGE}",format=qcow2 \\
    -netdev tap,id=net0,ifname=tap0,script=no,downscript=no \\
    -device virtio-net-pci,netdev=net0,mac=${CONTROLLER_MAC} \\
    -nographic \\
    -serial mon:stdio \\
    -name "slurm-controller"
EOF
    chmod +x "${CONTROLLER_TAP_SCRIPT}"
    
    # Set TAP permissions properly before starting VM (moved before script execution)
    echo -e "${BLUE}Setting proper permissions for TAP devices...${NC}"
    sudo ip tuntap add dev tap0 mode tap user $(whoami)
    sudo ip link set dev tap0 up
    sudo ovs-vsctl --may-exist add-port $BRIDGE_NAME tap0
    
    # Start controller VM with TAP networking (using sudo with the script instead)
    echo -e "${BLUE}Starting controller VM with virtual switch networking...${NC}"
    xterm -title "Slurm Controller" -e "${CONTROLLER_TAP_SCRIPT}" &
    
    # Wait for VM to boot with the new network - increased waiting time
    echo -e "${BLUE}Waiting for controller VM to boot with virtual switch networking...${NC}"
    sleep 10
    
    # PHASE 5: Verify connectivity using direct IP - SAME AS auto_vm_connect_bridge.sh approach
    echo -e "${BLUE}PHASE 5: Verifying connectivity to controller VM${NC}"
    
    # Wait for ping to succeed
    echo -e "${BLUE}Checking ping connectivity to ${CONTROLLER_IP}...${NC}"
    for i in {1..30}; do
        echo -e "${YELLOW}Ping attempt ${i}/30...${NC}"
        if ping -c 1 -W 2 "${CONTROLLER_IP}" > /dev/null 2>&1; then
            echo -e "${GREEN}Successfully pinged controller VM at ${CONTROLLER_IP}${NC}"
            break
        fi
        
        if [ $i -eq 30 ]; then
            echo -e "${RED}Failed to ping controller VM after 30 attempts.${NC}"
            echo -e "${YELLOW}Network debug information:${NC}"
            sudo ovs-vsctl show
            sudo ip link show tap0
            return 1
        fi
        
        sleep 5
    done
    
    # Wait for SSH to be available on direct IP
    echo -e "${BLUE}Checking SSH connectivity to ${CONTROLLER_IP}...${NC}"
    for i in {1..30}; do
        echo -e "${YELLOW}SSH check attempt ${i}/30...${NC}"
        if nc -z -w 2 "${CONTROLLER_IP}" 22; then
            echo -e "${GREEN}SSH port is open on controller VM${NC}"
            sleep 10  # Give SSH service a bit more time to fully initialize
            break
        fi
        
        if [ $i -eq 30 ]; then
            echo -e "${RED}SSH port not open on controller VM after 30 attempts.${NC}"
            return 1
        fi
        
        sleep 5
    done
    
    # PHASE 6: Provision controller
    echo -e "${BLUE}PHASE 6: Provisioning controller VM${NC}"
    
    # Copy scripts and sample jobs to controller
    echo -e "${BLUE}Copying scripts and sample jobs to controller...${NC}"
    sshpass -p "$VM_PASSWORD" scp -o StrictHostKeyChecking=no -r "$SCRIPTS_DIR" "${VM_USERNAME}@${CONTROLLER_IP}:~/" || {
        echo -e "${RED}ERROR: Failed to copy scripts to controller VM${NC}"
        exit 1
    }
    sshpass -p "$VM_PASSWORD" scp -o StrictHostKeyChecking=no -r "$SAMPLE_JOBS_DIR" "${VM_USERNAME}@${CONTROLLER_IP}:~/" || {
        echo -e "${RED}ERROR: Failed to copy sample jobs to controller VM${NC}"
        exit 1
    }
    
    # Verify scripts directory and required scripts exist
    echo -e "${BLUE}Verifying required scripts exist...${NC}"
    sshpass -p "$VM_PASSWORD" ssh -o StrictHostKeyChecking=no "${VM_USERNAME}@${CONTROLLER_IP}" << 'EOF'
if [ ! -d ~/scripts ]; then
    echo "ERROR: Scripts directory not found on controller VM"
    exit 1
fi

# Check for required script files
REQUIRED_SCRIPTS=("setup-controller.sh" "setup-slurmdbd.sh")
for script in "${REQUIRED_SCRIPTS[@]}"; do
    if [ ! -f ~/scripts/$script ]; then
        echo "ERROR: Required script ~/scripts/$script not found"
        exit 1
    fi
    # Make sure scripts are executable
    chmod +x ~/scripts/$script
done

echo "All required scripts verified"
EOF

    # If the verification failed, exit
    if [ $? -ne 0 ]; then
        echo -e "${RED}ERROR: Script verification failed on controller VM${NC}"
        exit 1
    fi
    
    # Run controller setup script with proper error handling
    echo -e "${BLUE}Running setup-controller.sh inside VM...${NC}"
    sshpass -p "$VM_PASSWORD" ssh -o StrictHostKeyChecking=no "${VM_USERNAME}@${CONTROLLER_IP}" << 'EOF'
# Run controller setup script
echo "Starting controller setup..."
sudo ~/scripts/setup-controller.sh
# Check return code
if [ $? -ne 0 ]; then
    echo "ERROR: Controller setup script failed"
    exit 1
fi
EOF

    # Check if controller setup succeeded
    if [ $? -ne 0 ]; then
        echo -e "${RED}ERROR: Failed to setup controller VM${NC}"
        return 1
    else
        echo -e "${GREEN}Controller VM setup completed successfully!${NC}"
        return 0
    fi
}

# Update start_compute_node to use the same multi-phase approach
start_compute_node() {
    local node_num=$1
    local node_ip="192.168.7.1${node_num}"
    local node_mac="52:54:00:12:34:1${node_num}"
    local node_image="${VM_DIR}/slurm-node${node_num}.qcow2"
    local node_name="node${node_num}"
    local ssh_port=$((2223 + node_num - 1))  # 2223 for node1, 2224 for node2
    
    echo -e "${BLUE}=== Starting and Provisioning ${node_name} ===${NC}"
    
    # Check if node image exists
    if ! check_image "$node_image"; then
        echo -e "${RED}${node_name} image not found. Cannot start.${NC}"
        return 1
    fi
    
    # PHASE 1: Start with user networking for initial setup
    echo -e "${BLUE}PHASE 1: Starting ${node_name} with user networking for initial setup${NC}"
    
    # Create VM script with user networking
    local node_user_script="${TMP_DIR}/start_${node_name}_user.sh"
    cat > "${node_user_script}" <<EOF
#!/bin/bash
echo "Starting ${node_name} with user networking for initial setup..."

export QEMU_AUDIO_DRV=none

# Run QEMU with user networking
exec qemu-system-x86_64 -m 4096 -smp 4 \\
    -enable-kvm \\
    -cpu host \\
    -drive file="${node_image}",format=qcow2 \\
    -netdev user,id=net0,hostfwd=tcp::${ssh_port}-:22 \\
    -device virtio-net-pci,netdev=net0 \\
    -nographic \\
    -serial mon:stdio
EOF
    chmod +x "${node_user_script}"
    
    # Start node VM with user networking
    echo -e "${BLUE}Starting ${node_name} with user networking...${NC}"
    xterm -title "${node_name}" -e "${node_user_script}" &
    
    # Wait for VM to boot
    echo -e "${BLUE}Waiting for ${node_name} to boot...${NC}"
    sleep 30
    
    # Wait for SSH to be available
    echo -e "${BLUE}Waiting for SSH on ${node_name}...${NC}"
    if ! wait_for_ssh "localhost" "${ssh_port}" "${node_name}"; then
        echo -e "${RED}Failed to connect to ${node_name}. Check VM console for errors.${NC}"
        return 1
    fi
    
    # PHASE 2: Configure network settings inside VM
    echo -e "${BLUE}PHASE 2: Configuring network settings inside ${node_name}${NC}"
    
    # Configure network via SSH
    sshpass -p "$VM_PASSWORD" ssh -o StrictHostKeyChecking=no -p ${ssh_port} "${VM_USERNAME}@localhost" << EOF
# Disable systemd network wait services
echo "Disabling systemd network wait services..."
sudo systemctl disable systemd-networkd-wait-online.service 2>/dev/null || true
sudo systemctl mask systemd-networkd-wait-online.service 2>/dev/null || true

# Disable cloud-init network configuration if it exists
sudo touch /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg 2>/dev/null || true
echo "network: {config: disabled}" | sudo tee /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg 2>/dev/null || true

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
      addresses: [${node_ip}/24]
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
    ip addr add ${node_ip}/24 dev \$IFACE
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

# Set hostname
sudo hostnamectl set-hostname ${node_name}

# Configure hosts file
echo "Configuring hosts file..."
sudo tee /etc/hosts > /dev/null << HOSTS
127.0.0.1 localhost
${CONTROLLER_IP} slurm-controller controller
${NODE1_IP} node1
${NODE2_IP} node2
HOSTS

# Configure SSH
echo "Configuring SSH for password authentication..."
sudo sed -i 's/#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sudo systemctl restart ssh

echo "Network configuration completed for ${node_name}"
EOF
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}Failed to configure network settings in ${node_name}.${NC}"
        return 1
    fi
    
    # Shutdown the VM to apply network changes
    echo -e "${BLUE}Shutting down ${node_name} to apply network changes...${NC}"
    sshpass -p "$VM_PASSWORD" ssh -o StrictHostKeyChecking=no -p ${ssh_port} "${VM_USERNAME}@localhost" "sudo poweroff"
    
    # Wait for VM to shutdown
    sleep 20
    
    # PHASE 3: Start node VM with virtual switch networking
    echo -e "${BLUE}PHASE 3: Starting ${node_name} with virtual switch networking${NC}"
    
    # Create node VM script with TAP networking - modified to avoid password prompts
    local node_tap_script="${TMP_DIR}/start_${node_name}_tap.sh"
    cat > "${node_tap_script}" <<EOF
#!/bin/bash
echo "Starting ${node_name} with virtual switch networking..."

export QEMU_AUDIO_DRV=none

# Run QEMU with TAP networking (removed sudo from exec line)
qemu-system-x86_64 -m 4096 -smp 4 \\
    -enable-kvm \\
    -cpu host \\
    -drive file="${node_image}",format=qcow2 \\
    -netdev tap,id=net0,ifname=tap${node_num},script=no,downscript=no \\
    -device virtio-net-pci,netdev=net0,mac=${node_mac} \\
    -nographic \\
    -serial mon:stdio \\
    -name "slurm-${node_name}"
EOF
    chmod +x "${node_tap_script}"
    
    # Set TAP permissions properly before starting VM
    echo -e "${BLUE}Setting proper permissions for TAP devices...${NC}"
    sudo ip tuntap add dev tap${node_num} mode tap user $(whoami)
    sudo ip link set dev tap${node_num} up
    sudo ovs-vsctl --may-exist add-port $BRIDGE_NAME tap${node_num}
    sudo chown $(whoami) /dev/net/tun
    
    # Start node VM with TAP networking
    echo -e "${BLUE}Starting ${node_name} with virtual switch networking...${NC}"
    xterm -title "Slurm ${node_name}" -e "${node_tap_script}" &
    
    # Wait for VM to boot with the new network
    echo -e "${BLUE}Waiting for ${node_name} to boot with virtual switch networking...${NC}"
    sleep 10
    
    # PHASE 4: Verify connectivity using direct IP
    echo -e "${BLUE}PHASE 4: Verifying connectivity to ${node_name}${NC}"
    
    # Wait for ping to succeed
    echo -e "${BLUE}Checking ping connectivity to ${node_ip}...${NC}"
    for i in {1..20}; do
        echo -e "${YELLOW}Ping attempt ${i}/20...${NC}"
        if ping -c 1 -W 2 "${node_ip}" > /dev/null 2>&1; then
            echo -e "${GREEN}Successfully pinged ${node_name} at ${node_ip}${NC}"
            break
        fi
        
        if [ $i -eq 20 ]; then
            echo -e "${RED}Failed to ping ${node_name} after 20 attempts.${NC}"
            return 1
        fi
        
        sleep 5
    done
    
    # Wait for SSH to be available on direct IP
    echo -e "${BLUE}Checking SSH connectivity to ${node_ip}...${NC}"
    for i in {1..20}; do
        echo -e "${YELLOW}SSH check attempt ${i}/20...${NC}"
        if nc -z -w 2 "${node_ip}" 22; then
            echo -e "${GREEN}SSH port is open on ${node_name}${NC}"
            sleep 10  # Give SSH service a bit more time to fully initialize
            break
        fi
        
        if [ $i -eq 20 ]; then
            echo -e "${RED}SSH port not open on ${node_name} after 20 attempts.${NC}"
            return 1
        fi
        
        sleep 5
    done
    
    # PHASE 5: Provision compute node
    echo -e "${BLUE}PHASE 5: Provisioning ${node_name}${NC}"
    
    # Copy scripts to compute node
    echo -e "${BLUE}Copying scripts to ${node_name}...${NC}"
    sshpass -p "$VM_PASSWORD" scp -o StrictHostKeyChecking=no -r "$SCRIPTS_DIR" "${VM_USERNAME}@${node_ip}:~/"
    
    # Run compute node setup script
    echo -e "${BLUE}Running setup-compute.sh inside VM...${NC}"
    sshpass -p "$VM_PASSWORD" ssh -o StrictHostKeyChecking=no "${VM_USERNAME}@${node_ip}" <<EOF
sudo chmod +x ~/scripts/*.sh
sudo ~/scripts/setup-compute.sh ${node_num}
EOF
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}${node_name} setup completed successfully!${NC}"
        return 0
    else
        echo -e "${RED}Failed to setup ${node_name}.${NC}"
        return 1
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
    
    # Create TAP interfaces for VMs (3 nodes: controller, node1, node2)
    echo -e "${BLUE}Creating TAP interfaces for VMs...${NC}"
    for i in 0 1 2; do
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

# Main script logic
case "${1:-build}" in
    build-base)
        echo -e "${GREEN}Building Slurm Base Image${NC}"
        build_base_image
        ;;
    build-controller)
        echo -e "${GREEN}Building Slurm Controller VM${NC}"
        create_controller
        ;;
    build-nodes)
        echo -e "${GREEN}Building Slurm Compute Node VMs${NC}"
        create_compute_nodes
        ;;
    build)
        echo -e "${GREEN}Building Complete QEMU Slurm Cluster${NC}"
        
        # Step 1: Build base image if it doesn't exist
        if ! check_image "$BASE_VM_IMAGE"; then
            echo -e "${YELLOW}Base image not found. Building it first...${NC}"
            build_base_image || {
                echo -e "${RED}Failed to build base image. Cannot continue.${NC}"
                exit 1
            }
            echo -e "${GREEN}✅ Base image created successfully: ${BASE_VM_IMAGE}${NC}"
            echo -e "${BLUE}This image contains Slurm binaries and all dependencies${NC}"
        else
            echo -e "${GREEN}Using existing base image: ${BASE_VM_IMAGE}${NC}"
        fi
        
        # Step 2: Create VM images (controller and compute nodes) from the base image
        echo -e "${BLUE}Creating controller and compute node VMs from base image...${NC}"
        create_controller
        create_compute_nodes
        echo -e "${GREEN}✅ Created controller and compute node images from base image${NC}"
        
        # Step 3: Start controller and run setup-controller.sh inside VM
        echo -e "${BLUE}Starting and provisioning controller VM...${NC}"
        start_controller_vm || {
            echo -e "${RED}Failed to setup controller VM. Cannot continue.${NC}"
            exit 1
        }
        
        # Step 4: Start node1 and run setup-compute.sh with node ID 1
        echo -e "${BLUE}Starting and provisioning node1 VM...${NC}"
        start_compute_node 1 || {
            echo -e "${YELLOW}Warning: Issue with node1 setup, but continuing...${NC}"
        }
        
        # Step 5: Start node2 and run setup-compute.sh with node ID 2
        echo -e "${BLUE}Starting and provisioning node2 VM...${NC}"
        start_compute_node 2 || {
            echo -e "${YELLOW}Warning: Issue with node2 setup, but continuing...${NC}"
        }
        
        echo -e "${GREEN}Cluster setup complete!${NC}"
        echo -e "${BLUE}Controller: ssh ${VM_USERNAME}@${CONTROLLER_IP}${NC}"
        echo -e "${BLUE}Node1: ssh ${VM_USERNAME}@${NODE1_IP}${NC}"
        echo -e "${BLUE}Node2: ssh ${VM_USERNAME}@${NODE2_IP}${NC}"
        ;;
    start)
        echo -e "${GREEN}Starting cluster VMs...${NC}"
        start_cluster_vms
        ;;
    stop)
        stop_cluster
        ;;
    clean)
        cleanup_cluster
        ;;
    clean-all)
        cleanup_cluster
        echo -e "${YELLOW}Removing base image...${NC}"
        rm -f "$BASE_VM_IMAGE"
        ;;
    *)
        echo "Usage: $0 {build|start|stop|clean|clean-all}"
        exit 1
        ;;
esac