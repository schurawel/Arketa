#!/bin/bash
# Simple script to SSH into the running VM started by direct-image.sh

# Colors for output
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

VM_USERNAME="ubuntu"
SSH_PORT="2222"
SSH_HOST="localhost"

# Function to find active SSH forwarding ports used by QEMU
find_active_ssh_ports() {
    # Find QEMU processes with port forwarding
    local ports=$(ps aux | grep qemu | grep hostfwd | grep -o 'hostfwd=tcp::[0-9]*-:22' | grep -o '[0-9]*')
    echo "$ports"
}

# Get active ports
ACTIVE_PORTS=$(find_active_ssh_ports)

if [ -z "$ACTIVE_PORTS" ]; then
    echo -e "${RED}No running VM with SSH port forwarding detected.${NC}"
    echo -e "${YELLOW}Please start a VM first with: ./direct-image.sh or ./auto_vm_connect.sh${NC}"
    exit 1
fi

# If only one port is found, use it
if [ $(echo "$ACTIVE_PORTS" | wc -l) -eq 1 ]; then
    SSH_PORT="$ACTIVE_PORTS"
    echo -e "${GREEN}Found VM running with SSH port: ${SSH_PORT}${NC}"
else
    # Multiple ports found, ask user to choose
    echo -e "${YELLOW}Multiple VM instances detected with different SSH ports:${NC}"
    select SSH_PORT in $ACTIVE_PORTS; do
        if [ -n "$SSH_PORT" ]; then
            echo -e "${GREEN}Selected SSH port: ${SSH_PORT}${NC}"
            break
        else
            echo -e "${RED}Invalid selection. Please try again.${NC}"
        fi
    done
fi

echo -e "${BLUE}Attempting to SSH into the running VM...${NC}"
echo -e "Command: ${YELLOW}ssh -p ${SSH_PORT} ${VM_USERNAME}@${SSH_HOST}${NC}"
echo -e "The password is '${YELLOW}ubuntu${NC}' if prompted."
echo "----------------------------------------"

ssh -o StrictHostKeyChecking=no -p "${SSH_PORT}" "${VM_USERNAME}@${SSH_HOST}"

if [ $? -ne 0 ]; then
    echo -e "\n${RED}SSH connection failed.${NC}"
    echo -e "${YELLOW}Is the VM running? You can start it with: ./direct-image.sh or ./auto_vm_connect.sh${NC}"
    echo -e "${YELLOW}For more details, try connecting with the verbose flag: ssh -v -p ${SSH_PORT} ${VM_USERNAME}@${SSH_HOST}${NC}"
fi
