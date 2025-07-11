#!/bin/bash
# Simple direct VM runner - uses standard Ubuntu cloud image

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

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

# Clear all running QEMU processes at startup
kill_qemu_processes

# Configuration
UBUNTU_CLOUD_IMAGE="ubuntu-22.04-server-cloudimg-amd64.img"
UBUNTU_CLOUD_URL="https://cloud-images.ubuntu.com/releases/22.04/release/${UBUNTU_CLOUD_IMAGE}"
VM_DIR="/home/thinclient/Documents/PrimedSLURM/qemu-vms"
IMAGE_PATH="${VM_DIR}/${UBUNTU_CLOUD_IMAGE}"

# Create VM directory
mkdir -p "${VM_DIR}"

# Download image if needed
if [ ! -f "${IMAGE_PATH}" ]; then
    echo -e "${BLUE}Downloading Ubuntu cloud image...${NC}"
    wget --progress=dot:giga -O "${IMAGE_PATH}" "${UBUNTU_CLOUD_URL}" || {
        echo -e "${RED}Failed to download image${NC}"
        exit 1
    }
fi

# Set login credentials - will be configured in cloud-init
VM_USERNAME="ubuntu"
VM_PASSWORD="ubuntu"
SAVED_IMAGE="${VM_DIR}/saved-ubuntu-vm.qcow2"

# Always use fresh image - no prompting for saved image
USE_SAVED=false

echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}    VM LOGIN CREDENTIALS${NC}"
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}  Username: ${YELLOW}${VM_USERNAME}${NC}"
echo -e "${GREEN}  Password: ${YELLOW}${VM_PASSWORD}${NC}"
echo -e "${GREEN}=========================================${NC}"
echo -e "${BLUE}These credentials will be configured in the VM${NC}"
echo ""

# Create cloud-init files to enable login
echo -e "${BLUE}Creating cloud-init configuration for login...${NC}"
CLOUD_INIT_DIR="${VM_DIR}/cloud-init"
mkdir -p "${CLOUD_INIT_DIR}"

# Create a user-data file with username and password and network configuration
cat > "${CLOUD_INIT_DIR}/user-data" <<EOF
#cloud-config
password: ${VM_PASSWORD}
chpasswd: { expire: False }
ssh_pwauth: True
hostname: ubuntu-vm

# Ensure networking works properly
manage_etc_hosts: true
package_update: true
packages:
  - openssh-server
  - avahi-daemon
  - net-tools
  - curl
  - iputils-ping

# Network configuration
write_files:
  - path: /etc/netplan/50-cloud-init.yaml
    content: |
      network:
        version: 2
        ethernets:
          ens3:
            dhcp4: true
            optional: true

# Run commands to ensure network is properly configured
runcmd:
  - netplan apply
  - systemctl restart systemd-networkd
  - systemctl enable ssh
  - systemctl start ssh
  - echo "Network configured successfully" > /var/log/cloud-init-network.log
EOF

# Create a minimal meta-data file
cat > "${CLOUD_INIT_DIR}/meta-data" <<EOF
instance-id: id-local01
local-hostname: ubuntu-vm
EOF

# Create the cloud-init ISO
echo -e "${BLUE}Creating cloud-init disk...${NC}"
cloud-localds "${CLOUD_INIT_DIR}/seed.iso" "${CLOUD_INIT_DIR}/user-data" "${CLOUD_INIT_DIR}/meta-data"

# Run QEMU with the VM image
echo -e "${BLUE}Starting VM...${NC}"
echo -e "${YELLOW}You will see all boot messages in real-time${NC}"
echo -e "${YELLOW}Use Ctrl+C to stop the VM${NC}"
echo -e "${GREEN}Login with:${NC}"
echo -e "  Username: ${YELLOW}${VM_USERNAME}${NC}"
echo -e "  Password: ${YELLOW}${VM_PASSWORD}${NC}"
echo -e "${YELLOW}When finished, type 'poweroff' in the VM or press Ctrl+C to shutdown and save its state${NC}"

# Set up trap to simply print a message on Ctrl+C, allowing the script to continue to the save step.
trap 'echo -e "\n${YELLOW}Ctrl+C detected. Proceeding to save VM state...${NC}"' INT

# Create a temporary overlay disk to capture changes during the session
TEMP_DISK="${VM_DIR}/temp-session.qcow2"
echo -e "${BLUE}Creating temporary session disk...${NC}"
qemu-img create -f qcow2 -F qcow2 -b "${IMAGE_PATH}" "${TEMP_DISK}"

# Run VM with cloud-init, using the temporary disk
qemu-system-x86_64 -m 4096 -smp 4 \
    -drive file="${TEMP_DISK}",format=qcow2 \
    -drive file="${CLOUD_INIT_DIR}/seed.iso",format=raw \
    -device virtio-net-pci,netdev=net0 \
    -netdev user,id=net0,hostfwd=tcp::2222-:22,dns=8.8.8.8 \
    -nographic \
    -serial mon:stdio

# Unconditionally save the image after the VM exits for any reason.
echo -e "\n${GREEN}VM process has ended.${NC}"
echo -e "${BLUE}Saving VM state with all changes to ${SAVED_IMAGE}...${NC}"

# Back up existing saved image if it exists
if [ -f "${SAVED_IMAGE}" ]; then
    echo -e "${YELLOW}Backing up existing saved image...${NC}"
    mv "${SAVED_IMAGE}" "${SAVED_IMAGE}.bak"
fi

# Convert the temporary disk (which contains all changes) to the final saved image
qemu-img convert -O qcow2 "${TEMP_DISK}" "${SAVED_IMAGE}"
echo -e "${GREEN}VM state saved successfully!${NC}"

# Clean up the temporary session disk
rm -f "${TEMP_DISK}"

echo -e "${GREEN}VM session ended${NC}"
