#!/bin/bash
# Script to start VM with console display in a new window

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

# Clear all running QEMU processes at startup
kill_qemu_processes

# Configuration
VM_DIR="/home/thinclient/Documents/PrimedSLURM/qemu-vms"
IMAGE_PATH="${VM_DIR}/ubuntu-22.04-server-cloudimg-amd64.img"
SAVED_IMAGE="${VM_DIR}/saved-ubuntu-vm.qcow2"
CLOUD_INIT_DIR="${VM_DIR}/cloud-init"
VM_USERNAME="ubuntu"
VM_PASSWORD="ubuntu"
SSH_PORT=2222  # FIXED PORT - no dynamic port finding
SSH_HOST="localhost"
TMP_DIR="${VM_DIR}/tmp"

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

# Copy the boot image to the temporary directory
TMP_BOOT_IMAGE="${TMP_DIR}/boot_image_${SESSION_ID}.qcow2"
echo -e "${BLUE}Copying boot image to temporary location...${NC}"
cp "${BOOT_IMAGE}" "${TMP_BOOT_IMAGE}"

if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to copy boot image to temporary location.${NC}"
    exit 1
fi

# Create a temporary overlay disk to capture changes
TEMP_DISK="${TMP_DIR}/temp-session-${SESSION_ID}.qcow2"
echo -e "${BLUE}Creating temporary session disk...${NC}"
qemu-img create -f qcow2 -F qcow2 -b "${TMP_BOOT_IMAGE}" "${TEMP_DISK}"

# Create VM launch script for the new console window
VM_SCRIPT="${TMP_DIR}/vm_console_${SESSION_ID}.sh"
cat > "${VM_SCRIPT}" <<EOF
#!/bin/bash
# VM Console script

echo "Starting VM console..."
echo "Use 'poweroff' in the VM or close this window to shutdown"

# Run VM with console - USING FIXED PORT 2222
exec qemu-system-x86_64 -m 4096 -smp 4 \\
    -drive file="${TEMP_DISK}",format=qcow2 \\
    -drive file="${CLOUD_INIT_DIR}/seed.iso",format=raw \\
    -device virtio-net-pci,netdev=net0 \\
    -netdev user,id=net0,hostfwd=tcp::${SSH_PORT}-:22,dns=8.8.8.8 \\
    -nographic \\
    -serial mon:stdio
EOF

# Make script executable
chmod +x "${VM_SCRIPT}"

# Function to clean up temporary files
cleanup() {
    echo -e "${BLUE}Cleaning up temporary files...${NC}"
    rm -f "${TEMP_DISK}" "${TMP_BOOT_IMAGE}" "${VM_SCRIPT}"
    echo -e "${GREEN}Cleanup complete.${NC}"
}

# Set up trap to clean up on exit
trap cleanup EXIT

# Display VM credentials
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}    VM LOGIN CREDENTIALS${NC}"
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}  Username: ${YELLOW}${VM_USERNAME}${NC}"
echo -e "${GREEN}  Password: ${YELLOW}${VM_PASSWORD}${NC}"
echo -e "${GREEN}  SSH Port: ${YELLOW}${SSH_PORT}${NC}"
echo -e "${GREEN}=========================================${NC}"

# Manual SSH connection instructions
echo -e "${BLUE}When VM is running, you can connect with:${NC}"
echo -e "${YELLOW}ssh -p ${SSH_PORT} ${VM_USERNAME}@${SSH_HOST}${NC}"
echo -e "${YELLOW}Password: ${VM_PASSWORD}${NC}"

# Launch VM in a new terminal window
echo -e "${BLUE}Starting VM with console in a new window...${NC}"
if command -v xterm &> /dev/null; then
    xterm -title "VM Console" -e "${VM_SCRIPT}" &
    VM_TERMINAL="xterm"
elif command -v gnome-terminal &> /dev/null; then
    gnome-terminal -- "${VM_SCRIPT}" &
    VM_TERMINAL="gnome-terminal"
elif command -v konsole &> /dev/null; then
    konsole -e "${VM_SCRIPT}" &
    VM_TERMINAL="konsole"
else
    echo -e "${RED}No supported terminal emulator found.${NC}"
    echo -e "${YELLOW}Please install xterm, gnome-terminal, or konsole.${NC}"
    exit 1
fi

echo -e "${GREEN}VM launched in a new ${VM_TERMINAL} window.${NC}"
echo -e "${BLUE}This console will remain available for commands.${NC}"

# Wait for VM to start and try SSH connection
echo -e "${BLUE}Waiting for SSH port ${SSH_PORT} to become available...${NC}"
echo -e "${YELLOW}Will try for up to 10 minutes...${NC}"

MAX_ATTEMPTS=60
RETRY_INTERVAL=10
PORT_IS_OPEN=false

# Check if we can use netcat for port checking
if command -v nc >/dev/null 2>&1; then
    HAS_NC=true
    echo -e "${GREEN}Using netcat (nc) to check port availability${NC}"
else
    HAS_NC=false
    echo -e "${YELLOW}Netcat (nc) not found, will use basic port check${NC}"
fi

for ((attempt=1; attempt<=MAX_ATTEMPTS; attempt++)); do
    echo -e "${YELLOW}Attempt ${attempt}/${MAX_ATTEMPTS}: Checking if SSH is ready...${NC}"
    
    # Two methods to check if port is open
    if [ "$HAS_NC" = true ]; then
        nc -z "$SSH_HOST" $SSH_PORT >/dev/null 2>&1
        NC_EXIT_CODE=$?
        if [ $NC_EXIT_CODE -eq 0 ]; then
            PORT_IS_OPEN=true
        fi
    else
        # Alternative method using /dev/tcp if nc is not available
        (echo > /dev/tcp/$SSH_HOST/$SSH_PORT) >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            PORT_IS_OPEN=true
        fi
    fi
    
    if [ "$PORT_IS_OPEN" = true ]; then
        echo -e "\n${GREEN}Port ${SSH_PORT} is open! SSH should be ready.${NC}"
        break
    fi
    
    echo -e "${YELLOW}SSH not ready yet. Waiting ${RETRY_INTERVAL} seconds...${NC}"
    sleep ${RETRY_INTERVAL}
done

if [ "$PORT_IS_OPEN" = true ]; then
    echo -e "\n${GREEN}=========================================${NC}"
    echo -e "${GREEN}Attempting to start SSH session...${NC}"
    echo -e "${GREEN}=========================================${NC}"
    
    # Simple SSH session loop - restarts automatically if connection ends
    MAX_SESSIONS=10  # Maximum number of consecutive SSH sessions
    SESSION_COUNT=0
    
    while [ $SESSION_COUNT -lt $MAX_SESSIONS ]; do
        SESSION_COUNT=$((SESSION_COUNT + 1))
        
        if [ $SESSION_COUNT -gt 1 ]; then
            echo -e "\n${YELLOW}Restarting SSH session (${SESSION_COUNT}/${MAX_SESSIONS})...${NC}"
        fi
        
        if [ "$HAS_SSHPASS" = true ]; then
            echo -e "${GREEN}Using auto-login with sshpass...${NC}"
            sshpass -p "${VM_PASSWORD}" ssh -o StrictHostKeyChecking=no -p $SSH_PORT ${VM_USERNAME}@${SSH_HOST}
        else
            echo -e "${YELLOW}Manual login required. Password: ${VM_PASSWORD}${NC}"
            ssh -o StrictHostKeyChecking=no -p $SSH_PORT ${VM_USERNAME}@${SSH_HOST}
        fi
        
        echo -e "\n${BLUE}SSH session ended.${NC}"
        
        # Ask if user wants to start another session or quit
        echo -e "${YELLOW}Do you want to start another SSH session? (y/n)${NC}"
        read -r response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            echo -e "${GREEN}Exiting SSH session loop.${NC}"
            break
        fi
    done
    
    if [ $SESSION_COUNT -ge $MAX_SESSIONS ]; then
        echo -e "${RED}Maximum number of consecutive SSH sessions reached.${NC}"
    fi
else
    echo -e "\n${RED}SSH port ${SSH_PORT} did not become available after 10 minutes.${NC}"
    echo -e "${YELLOW}Please check the VM console for errors.${NC}"
fi

echo -e "${BLUE}VM is running in a separate window.${NC}"
echo -e "${YELLOW}You can connect via SSH with: ./test-ssh.sh${NC}"
echo -e "${YELLOW}When finished, type 'poweroff' in the VM or close the VM window.${NC}"
echo -e "${YELLOW}This console will remain available. Press Ctrl+C to exit this script.${NC}"

# Wait for user to press Ctrl+C or for VM to shutdown
echo -e "${BLUE}Monitoring VM process...${NC}"
while pgrep qemu-system > /dev/null; do
    sleep 5
done

echo -e "${GREEN}VM has been shut down.${NC}"
