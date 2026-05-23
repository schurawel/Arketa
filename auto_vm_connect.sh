#!/bin/bash
# Script to start two VMs with bridged networking

# Ensure script is run from PrimedSLURM directory
if [ ! -f "README.md" ] || [ ! -d "scripts" ]; then
    echo -e "\033[0;31mError: This script must be run from the PrimedSLURM directory.\033[0m"
    echo -e "\033[1;33mPlease cd to the PrimedSLURM directory and run: ./auto_vm_connect.sh\033[0m"
    exit 1
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to terminate all running QEMU processes
kill_qemu_processes() {
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
            sleep 5
            
            # Test SSH connectivity with direct IP
            if timeout 10 ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@"${ip}" "echo 'SSH is working'" >/dev/null 2>&1; then
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

# Clear all running QEMU processes at startup
kill_qemu_processes

# Configuration
VM_DIR="./qemu-vms"
IMAGE_PATH="${VM_DIR}/ubuntu-22.04-server-cloudimg-amd64.img"
SAVED_IMAGE="${VM_DIR}/saved-ubuntu-vm.qcow2"
VM_USERNAME="ubuntu"
VM_PASSWORD="ubuntu"
TMP_DIR="${VM_DIR}/tmp"

# VM networking info
VM1_IP="192.168.7.10"
VM2_IP="192.168.7.11"
VM1_MAC="52:54:00:12:34:56"
VM2_MAC="52:54:00:12:34:57"
BRIDGE_NAME="qemubr0"

# Check if sshpass is installed
if ! command -v sshpass &> /dev/null; then
    echo -e "${RED}sshpass is not installed. Please install sshpass to use this script.${NC}"
    exit 1
fi

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

# Create temporary disks for both VMs
TEMP_DISK1="${TMP_DIR}/temp-session-${SESSION_ID}-vm1.qcow2"
echo -e "${BLUE}Creating temporary session disk for VM1...${NC}"
qemu-img create -f qcow2 -F qcow2 -b "${BOOT_IMAGE}" "${TEMP_DISK1}" 30G

TEMP_DISK2="${TMP_DIR}/temp-session-${SESSION_ID}-vm2.qcow2"
echo -e "${BLUE}Creating temporary session disk for VM2...${NC}"
qemu-img create -f qcow2 -F qcow2 -b "${BOOT_IMAGE}" "${TEMP_DISK2}" 30G

# Create VM launch scripts
VM1_SCRIPT="${TMP_DIR}/vm1_console_${SESSION_ID}.sh"
cat > "${VM1_SCRIPT}" <<EOF
#!/bin/bash
exec qemu-system-x86_64 -m 4096 -smp 4 \\
    -enable-kvm -cpu host \\
    -drive file="${TEMP_DISK1}",format=qcow2 \\
    -netdev bridge,br=${BRIDGE_NAME},id=net0 \\
    -device virtio-net-pci,netdev=net0,mac=${VM1_MAC} \\
    -nographic -serial mon:stdio
EOF

VM2_SCRIPT="${TMP_DIR}/vm2_console_${SESSION_ID}.sh"
cat > "${VM2_SCRIPT}" <<EOF
#!/bin/bash
exec qemu-system-x86_64 -m 4096 -smp 4 \\
    -enable-kvm -cpu host \\
    -drive file="${TEMP_DISK2}",format=qcow2 \\
    -netdev bridge,br=${BRIDGE_NAME},id=net0 \\
    -device virtio-net-pci,netdev=net0,mac=${VM2_MAC} \\
    -nographic -serial mon:stdio
EOF

chmod +x "${VM1_SCRIPT}" "${VM2_SCRIPT}"

# Function to clean up temporary files
cleanup() {
    echo -e "${BLUE}Cleaning up temporary files...${NC}"
    rm -f "${TEMP_DISK1}" "${TEMP_DISK2}" "${VM1_SCRIPT}" "${VM2_SCRIPT}"
    echo -e "${GREEN}Cleanup complete.${NC}"
}

# Set up trap to clean up on exit
trap cleanup EXIT

# Launch VMs in new terminal windows
echo -e "${BLUE}Starting VMs with console in new windows...${NC}"
xterm -title "VM1 Console" -e "${VM1_SCRIPT}" &
xterm -title "VM2 Console" -e "${VM2_SCRIPT}" &

echo -e "${GREEN}VMs launched.${NC}"

# Wait for VMs to be accessible via DIRECT IPs ONLY
echo -e "${BLUE}Waiting for VMs to be accessible via direct IPs...${NC}"
wait_for_ssh_direct "${VM1_IP}" "VM1"
wait_for_ssh_direct "${VM2_IP}" "VM2"

# Test connectivity between VMs using direct IPs
echo -e "${BLUE}Testing VM1 to VM2 connectivity via direct IPs...${NC}"
ssh -o StrictHostKeyChecking=no ubuntu@${VM1_IP} "ping -c 4 ${VM2_IP}"

echo -e "${BLUE}Testing VM2 to VM1 connectivity via direct IPs...${NC}"
ssh -o StrictHostKeyChecking=no ubuntu@${VM2_IP} "ping -c 4 ${VM1_IP}"

# Final instructions
echo -e "\n${GREEN}=========================================${NC}"
echo -e "${GREEN}VMs are now set up with bridge networking!${NC}"
echo -e "${GREEN}VM1: ${VM1_IP}${NC}"
echo -e "${GREEN}VM2: ${VM2_IP}${NC}"
echo -e "${GREEN}=========================================${NC}"

echo -e "${BLUE}Starting SSH session to VM1 using direct bridge IP...${NC}"
ssh -o StrictHostKeyChecking=no ubuntu@${VM1_IP}

echo -e "${YELLOW}Do you want to connect to VM2? (y/n)${NC}"
read -r response
if [[ "$response" =~ ^[Yy]$ ]]; then
    echo -e "${BLUE}Starting SSH session to VM2 using direct bridge IP...${NC}"
    ssh -o StrictHostKeyChecking=no ubuntu@${VM2_IP}
fi

echo -e "${BLUE}Monitoring VM processes...${NC}"
while pgrep qemu-system > /dev/null; do
    sleep 5
done

echo -e "${GREEN}All VMs have been shut down.${NC}"
