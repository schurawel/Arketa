#!/bin/bash
# Build Slurm cluster with QEMU VMs - Uses direct image copying approach

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
VM_DIR="/home/thinclient/Documents/PrimedSLURM/qemu-vms"
BASE_IMAGE="${VM_DIR}/ubuntu-22.04-server-cloudimg-amd64.img"
BASE_URL="https://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-amd64.img"
SAVED_BASE="${VM_DIR}/slurm-base.qcow2"
SCRIPTS_DIR="/home/thinclient/Documents/PrimedSLURM/scripts"
TMP_DIR="${VM_DIR}/tmp"
LOG_DIR="${VM_DIR}/logs"

# VM Configuration
VM_USERNAME="ubuntu"
VM_PASSWORD="ubuntu"
CONTROLLER_IP="192.168.122.10"
NODE1_IP="192.168.122.11"
NODE2_IP="192.168.122.12"

# Function to show help
show_help() {
    echo -e "${GREEN}QEMU Slurm Cluster Builder${NC}"
    echo -e "Usage: $0 [command]"
    echo
    echo -e "Commands:"
    echo -e "  ${YELLOW}build-base${NC}       Build Slurm base image"
    echo -e "  ${YELLOW}build-cluster${NC}    Build full cluster from base image"
    echo -e "  ${YELLOW}start-cluster${NC}    Start all cluster VMs"
    echo -e "  ${YELLOW}stop-cluster${NC}     Stop all cluster VMs"
    echo -e "  ${YELLOW}clean${NC}            Clean up all VMs and images"
    echo -e "  ${YELLOW}status${NC}           Show status of all VMs"
    echo -e "  ${YELLOW}connect${NC} [vm]     Connect to a specific VM (controller, node1, node2)"
    echo -e "  ${YELLOW}help${NC}             Show this help message"
    echo
    echo -e "Example workflow:"
    echo -e "  1. ./build_qemu_cluster.sh build-base"
    echo -e "  2. ./build_qemu_cluster.sh build-cluster"
    echo -e "  3. ./build_qemu_cluster.sh connect controller"
}

# Function to check if required tools are installed
check_dependencies() {
    echo -e "${BLUE}Checking dependencies...${NC}"
    
    local missing_deps=()
    
    for cmd in qemu-system-x86_64 qemu-img ssh sshpass nc; do
        if ! command -v $cmd &> /dev/null; then
            missing_deps+=($cmd)
        fi
    done
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo -e "${RED}Missing dependencies: ${missing_deps[*]}${NC}"
        echo -e "${YELLOW}Please install them with:${NC}"
        echo -e "sudo apt-get update && sudo apt-get install -y qemu-system-x86 qemu-utils openssh-client sshpass netcat-openbsd"
        exit 1
    fi
    
    echo -e "${GREEN}All dependencies are installed.${NC}"
}

# Function to create directories
create_directories() {
    mkdir -p "${VM_DIR}" "${TMP_DIR}" "${LOG_DIR}"
}

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

# Function to download base Ubuntu cloud image
download_base_image() {
    if [ ! -f "${BASE_IMAGE}" ]; then
        echo -e "${BLUE}Downloading Ubuntu cloud image...${NC}"
        wget --progress=dot:giga -O "${BASE_IMAGE}" "${BASE_URL}" || {
            echo -e "${RED}Failed to download image${NC}"
            exit 1
        }
        echo -e "${GREEN}Download complete.${NC}"
    else
        echo -e "${BLUE}Using existing Ubuntu cloud image.${NC}"
    fi
}

# Function to retry SSH commands with exponential backoff
ssh_with_retry() {
    local host=$1
    local port=$2
    local user=$3
    local password=$4
    local command=$5
    local max_attempts=10
    local attempt=1
    local wait_time=10
    local success=false

    while [ $attempt -le $max_attempts ]; do
        echo -e "${BLUE}SSH command attempt ${attempt}/${max_attempts}...${NC}"
        echo -e "${YELLOW}Executing: ${command}${NC}"
        
        # We'll use a specific error file to capture SSH connection errors only
        SSH_ERROR_FILE=$(mktemp)
        
        # Execute the SSH command directly, capturing only SSH errors
        if [ -z "$command" ]; then
            # Interactive mode
            sshpass -p "$password" ssh -o StrictHostKeyChecking=no -p $port ${user}@${host} 2>${SSH_ERROR_FILE}
            local ssh_exit_code=$?
        else
            # Command mode - run command regardless of its exit code
            # The -t option forces pseudo-terminal allocation for better output handling
            sshpass -p "$password" ssh -o StrictHostKeyChecking=no -p $port ${user}@${host} -t "$command" 2>${SSH_ERROR_FILE}
            local ssh_exit_code=$?
        fi
        
        # Check for SSH connection errors only
        if [ $ssh_exit_code -eq 0 ]; then
            # SSH connection was successful (command may have failed, but we don't care)
            echo -e "${GREEN}SSH connection successful. Command execution completed.${NC}"
            success=true
            break
        elif [ $ssh_exit_code -eq 255 ]; then
            # SSH specific errors (like connection reset, connection refused)
            grep_result=$(grep -i "Connection reset by peer\|Connection refused\|Network is unreachable" ${SSH_ERROR_FILE})
            
            if [ -n "$grep_result" ]; then
                echo -e "${YELLOW}SSH connection failed: ${grep_result}${NC}"
                echo -e "${YELLOW}Retrying in ${wait_time} seconds...${NC}"
                
                # Exponential backoff with max of 60 seconds
                wait_time=$((wait_time * 2))
                if [ $wait_time -gt 60 ]; then
                    wait_time=60
                fi
                
                # Check if VM is still running before retrying
                if ! pgrep -f "qemu-system.*${port}" > /dev/null; then
                    echo -e "${RED}VM appears to have shut down. Aborting retry.${NC}"
                    rm -f ${SSH_ERROR_FILE}
                    return 1
                fi
                
                attempt=$((attempt + 1))
            else
                # Other SSH errors that we don't want to retry
                echo -e "${RED}SSH error occurred:${NC}"
                cat ${SSH_ERROR_FILE}
                success=false
                break
            fi
        else
            # This is a subprocess error, but SSH connection worked
            # We consider this successful from an SSH perspective
            echo -e "${YELLOW}SSH connection succeeded, but remote command returned non-zero exit code: ${ssh_exit_code}${NC}"
            echo -e "${YELLOW}Continuing since SSH connection was established.${NC}"
            success=true
            break
        fi
        
        sleep $wait_time
        
        # Clean up temp file
        rm -f ${SSH_ERROR_FILE}
    done
    
    # Clean up temp file if it still exists
    [ -f ${SSH_ERROR_FILE} ] && rm -f ${SSH_ERROR_FILE}
    
    if [ "$success" = true ]; then
        return 0
    else
        echo -e "${RED}Failed to establish SSH connection after ${max_attempts} attempts.${NC}"
        return 1
    fi
}

# Function to retry SCP transfers with exponential backoff
scp_with_retry() {
    local host=$1
    local port=$2
    local user=$3
    local password=$4
    local source=$5
    local destination=$6
    local max_attempts=10
    local attempt=1
    local wait_time=10
    local success=false

    while [ $attempt -le $max_attempts ]; do
        echo -e "${BLUE}SCP transfer attempt ${attempt}/${max_attempts}...${NC}"
        
        # Execute the SCP command
        sshpass -p "$password" scp -o StrictHostKeyChecking=no -P $port $source ${user}@${host}:${destination}
        local exit_code=$?
        
        # Check the exit code
        if [ $exit_code -eq 0 ]; then
            echo -e "${GREEN}File transfer successful.${NC}"
            success=true
            break
        fi
        
        echo -e "${RED}SCP transfer failed. Retrying in ${wait_time} seconds...${NC}"
        sleep $wait_time
        
        # Exponential backoff with max of 60 seconds
        wait_time=$((wait_time * 2))
        if [ $wait_time -gt 60 ]; then
            wait_time=60
        fi
        
        # Check if VM is still running before retrying
        if ! pgrep -f "qemu-system.*${port}" > /dev/null; then
            echo -e "${RED}VM appears to have shut down. Aborting retry.${NC}"
            return 1
        fi
        
        attempt=$((attempt + 1))
    done
    
    if [ "$success" = true ]; then
        return 0
    else
        echo -e "${RED}Failed to transfer file after ${max_attempts} attempts.${NC}"
        return 1
    fi
}

# Function to ensure VM is ready for SSH with extended checks
ensure_vm_ready() {
    local host=$1
    local port=$2
    local user=$3
    local password=$4
    local max_attempts=20
    local retry_interval=15
    local attempt=1
    
    echo -e "${BLUE}Ensuring VM is fully ready for SSH connections...${NC}"
    
    for ((attempt=1; attempt<=max_attempts; attempt++)); do
        echo -e "${YELLOW}Readiness check ${attempt}/${max_attempts}...${NC}"
        
        # First check if port is open
        if nc -z $host $port; then
            echo -e "${GREEN}Port $port is open. Testing SSH connectivity...${NC}"
            
            # Try a simple echo command
            RESULT=$(sshpass -p "$password" ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -p $port ${user}@${host} "echo 'SSH_TEST_OK'" 2>&1)
            
            if [[ "$RESULT" == *"SSH_TEST_OK"* ]]; then
                echo -e "${GREEN}VM is fully ready for SSH connections.${NC}"
                
                # Do an additional test with a simple command to ensure stability
                sleep 5
                RESULT2=$(sshpass -p "$password" ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -p $port ${user}@${host} "hostname" 2>&1)
                if [ $? -eq 0 ]; then
                    echo -e "${GREEN}Extended SSH test successful. VM is stable.${NC}"
                    return 0
                else
                    echo -e "${YELLOW}Extended SSH test failed. VM might need more time.${NC}"
                fi
            else
                if echo "$RESULT" | grep -q "Connection reset by peer"; then
                    echo -e "${YELLOW}Connection reset detected. VM services still starting up.${NC}"
                else
                    echo -e "${YELLOW}SSH port is open but command execution failed.${NC}"
                    echo -e "${YELLOW}Error: $RESULT${NC}"
                fi
            fi
        else
            echo -e "${YELLOW}Port $port is not open yet.${NC}"
        fi
        
        echo -e "${YELLOW}Waiting ${retry_interval} seconds before next check...${NC}"
        sleep $retry_interval
    done
    
    echo -e "${RED}VM did not become fully ready for SSH after ${max_attempts} attempts.${NC}"
    return 1
}

# Function to build base VM with retry logic
build_base_vm() {
    echo -e "${BLUE}Building Slurm base VM...${NC}"
    
    # Download base image if needed
    download_base_image
    
    # Create temporary disk for base VM
    BASE_TEMP_DISK="${TMP_DIR}/slurm-base-temp.qcow2"
    echo -e "${BLUE}Creating temporary disk for base VM...${NC}"
    qemu-img create -f qcow2 -F qcow2 -b "${BASE_IMAGE}" "${BASE_TEMP_DISK}" 20G
    
    # Copy setup scripts into VM directory
    echo -e "${BLUE}Preparing setup scripts...${NC}"
    
    # Ensure scripts directory exists
    mkdir -p "${TMP_DIR}/scripts"
    
    # Copy setup scripts
    if [ -d "${SCRIPTS_DIR}" ]; then
        cp "${SCRIPTS_DIR}"/*.sh "${TMP_DIR}/scripts/"
        chmod +x "${TMP_DIR}/scripts"/*.sh
    else
        echo -e "${RED}Scripts directory not found: ${SCRIPTS_DIR}${NC}"
        echo -e "${YELLOW}Please ensure the scripts directory exists and contains the setup scripts.${NC}"
        exit 1
    fi
    
    # Create base VM console script
    BASE_VM_SCRIPT="${TMP_DIR}/base-vm-console.sh"
    cat > "${BASE_VM_SCRIPT}" <<EOF
#!/bin/bash
echo "Starting base VM console..."
echo "Use 'poweroff' in the VM or close this window to shutdown"

exec qemu-system-x86_64 -m 4096 -smp 4 \\
    -drive file="${BASE_TEMP_DISK}",format=qcow2 \\
    -device virtio-net-pci,netdev=net0 \\
    -netdev user,id=net0,hostfwd=tcp::2222-:22,dns=8.8.8.8 \\
    -nographic \\
    -serial mon:stdio
EOF

    chmod +x "${BASE_VM_SCRIPT}"
    
    # Start VM in a new terminal
    if command -v xterm &> /dev/null; then
        xterm -title "Slurm Base VM" -e "${BASE_VM_SCRIPT}" &
        VM_TERMINAL="xterm"
    elif command -v gnome-terminal &> /dev/null; then
        gnome-terminal -- "${BASE_VM_SCRIPT}" &
        VM_TERMINAL="gnome-terminal"
    elif command -v konsole &> /dev/null; then
        konsole -e "${BASE_VM_SCRIPT}" &
        VM_TERMINAL="konsole"
    else
        echo -e "${RED}No supported terminal emulator found.${NC}"
        echo -e "${YELLOW}Please install xterm, gnome-terminal, or konsole.${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}Base VM launched in a new ${VM_TERMINAL} window.${NC}"
    
    # Wait for VM to be fully ready for SSH with enhanced checks
    if ! ensure_vm_ready "localhost" "2222" "${VM_USERNAME}" "${VM_PASSWORD}"; then
        echo -e "${RED}Base VM is not ready for SSH. Aborting.${NC}"
        exit 1
    fi
    
    # Create directory on VM with retry
    echo -e "${BLUE}Creating scripts directory on VM...${NC}"
    ssh_with_retry "localhost" "2222" "${VM_USERNAME}" "${VM_PASSWORD}" "mkdir -p ~/scripts"
    
    # Copy scripts to VM with retry
    echo -e "${BLUE}Copying setup scripts to VM...${NC}"
    for script in "${TMP_DIR}/scripts/"*.sh; do
        echo -e "${BLUE}Copying $(basename "$script")...${NC}"
        scp_with_retry "localhost" "2222" "${VM_USERNAME}" "${VM_PASSWORD}" "$script" "~/scripts/"
    done
    
    # Make scripts executable
    echo -e "${BLUE}Making scripts executable...${NC}"
    ssh_with_retry "localhost" "2222" "${VM_USERNAME}" "${VM_PASSWORD}" "chmod +x ~/scripts/*.sh"
    
    # Run base setup script with retry
    echo -e "${BLUE}Running setup-base.sh script on VM...${NC}"
    if ! ssh_with_retry "localhost" "2222" "${VM_USERNAME}" "${VM_PASSWORD}" "cd ~ && sudo scripts/setup-base.sh --clean-for-imaging"; then
        echo -e "${RED}Failed to run setup-base.sh script. Trying to continue...${NC}"
    fi
    
    # Shutdown VM
    echo -e "${BLUE}Shutting down VM...${NC}"
    ssh_with_retry "localhost" "2222" "${VM_USERNAME}" "${VM_PASSWORD}" "sudo poweroff" || true
    
    # Wait for VM to shutdown
    echo -e "${BLUE}Waiting for VM to shutdown...${NC}"
    while pgrep -f "qemu-system-x86_64.*${BASE_TEMP_DISK}" > /dev/null; do
        sleep 5
    done
    
    # Save base VM image
    echo -e "${BLUE}Saving base VM image...${NC}"
    qemu-img convert -O qcow2 "${BASE_TEMP_DISK}" "${SAVED_BASE}"
    
    echo -e "${GREEN}Base VM image saved to ${SAVED_BASE}${NC}"
}

# Function to build cluster
build_cluster() {
    echo -e "${BLUE}Building Slurm cluster from base image...${NC}"
    
    # Check if base image exists
    if [ ! -f "${SAVED_BASE}" ]; then
        echo -e "${RED}Base VM image not found. Please build it first with 'build-base'.${NC}"
        exit 1
    fi
    
    # Create disks for each node
    echo -e "${BLUE}Creating disks for cluster nodes...${NC}"
    qemu-img create -f qcow2 -F qcow2 -b "${SAVED_BASE}" "${VM_DIR}/controller.qcow2" 20G
    qemu-img create -f qcow2 -F qcow2 -b "${SAVED_BASE}" "${VM_DIR}/node1.qcow2" 20G
    qemu-img create -f qcow2 -F qcow2 -b "${SAVED_BASE}" "${VM_DIR}/node2.qcow2" 20G
    
    echo -e "${GREEN}Cluster build preparation complete.${NC}"
    echo -e "${BLUE}Use 'start-cluster' to start the cluster nodes.${NC}"
}

# Function to start a specific VM
start_vm() {
    local vm_name=$1
    local ssh_port=$2
    
    echo -e "${BLUE}Starting ${vm_name}...${NC}"
    
    # Create VM script
    VM_SCRIPT="${TMP_DIR}/${vm_name}-console.sh"
    cat > "${VM_SCRIPT}" <<EOF
#!/bin/bash
echo "Starting ${vm_name} console..."
echo "Use 'poweroff' in the VM or close this window to shutdown"

exec qemu-system-x86_64 -m 4096 -smp 4 \\
    -drive file="${VM_DIR}/${vm_name}.qcow2",format=qcow2 \\
    -device virtio-net-pci,netdev=net0 \\
    -netdev user,id=net0,hostfwd=tcp::${ssh_port}-:22,dns=8.8.8.8 \\
    -nographic \\
    -serial mon:stdio
EOF

    chmod +x "${VM_SCRIPT}"
    
    # Start VM in a new terminal
    if command -v xterm &> /dev/null; then
        xterm -title "${vm_name} VM" -e "${VM_SCRIPT}" &
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
    
    echo -e "${GREEN}${vm_name} launched in a new ${VM_TERMINAL} window.${NC}"
    
    # Log running command
    echo "$(date): Started ${vm_name} with port ${ssh_port}" >> "${LOG_DIR}/vm-status.log"
}

# Function to start the cluster
start_cluster() {
    echo -e "${BLUE}Starting Slurm cluster...${NC}"
    
    # Check if VM images exist
    for vm in controller node1 node2; do
        if [ ! -f "${VM_DIR}/${vm}.qcow2" ]; then
            echo -e "${RED}${vm} image not found. Please run 'build-cluster' first.${NC}"
            exit 1
        fi
    done
    
    # Start controller
    start_vm "controller" "2222"
    echo -e "${YELLOW}Waiting for controller to boot before starting compute nodes...${NC}"
    sleep 30
    
    # Start compute nodes
    start_vm "node1" "2223"
    start_vm "node2" "2224"
    
    echo -e "${GREEN}All cluster nodes started.${NC}"
    echo -e "${BLUE}Waiting for SSH to become available on controller...${NC}"
    
    # Wait for controller SSH
    MAX_ATTEMPTS=60
    RETRY_INTERVAL=10
    PORT_IS_OPEN=false
    
    for ((attempt=1; attempt<=MAX_ATTEMPTS; attempt++)); do
        echo -e "${YELLOW}Attempt ${attempt}/${MAX_ATTEMPTS}: Checking if controller SSH is ready...${NC}"
        
        if nc -z localhost 2222; then
            PORT_IS_OPEN=true
            break
        fi
        
        echo -e "${YELLOW}SSH not ready yet. Waiting ${RETRY_INTERVAL} seconds...${NC}"
        sleep ${RETRY_INTERVAL}
    done
    
    if [ "$PORT_IS_OPEN" = true ]; then
        echo -e "${GREEN}Controller SSH is available. Waiting additional 30 seconds for system to fully boot...${NC}"
        sleep 30
        
        # Copy scripts to controller VM
        echo -e "${BLUE}Copying setup scripts to controller...${NC}"
        sshpass -p "${VM_PASSWORD}" ssh -o StrictHostKeyChecking=no -p 2222 ${VM_USERNAME}@localhost "mkdir -p ~/scripts"
        sshpass -p "${VM_PASSWORD}" scp -o StrictHostKeyChecking=no -P 2222 -r "${TMP_DIR}/scripts/"* ${VM_USERNAME}@localhost:~/scripts/
        
        # Run controller setup script
        echo -e "${BLUE}Running setup-controller.sh on controller...${NC}"
        sshpass -p "${VM_PASSWORD}" ssh -o StrictHostKeyChecking=no -p 2222 ${VM_USERNAME}@localhost "cd ~ && chmod +x scripts/*.sh && sudo scripts/setup-controller.sh"
        
        # Wait for node1 SSH
        echo -e "${BLUE}Waiting for SSH to become available on node1...${NC}"
        PORT_IS_OPEN=false
        
        for ((attempt=1; attempt<=MAX_ATTEMPTS; attempt++)); do
            echo -e "${YELLOW}Attempt ${attempt}/${MAX_ATTEMPTS}: Checking if node1 SSH is ready...${NC}"
            
            if nc -z localhost 2223; then
                PORT_IS_OPEN=true
                break
            fi
            
            echo -e "${YELLOW}SSH not ready yet. Waiting ${RETRY_INTERVAL} seconds...${NC}"
            sleep ${RETRY_INTERVAL}
        done
        
        if [ "$PORT_IS_OPEN" = true ]; then
            echo -e "${GREEN}Node1 SSH is available. Setting up node1...${NC}"
            
            # Copy scripts to node1
            echo -e "${BLUE}Copying setup scripts to node1...${NC}"
            sshpass -p "${VM_PASSWORD}" ssh -o StrictHostKeyChecking=no -p 2223 ${VM_USERNAME}@localhost "mkdir -p ~/scripts"
            sshpass -p "${VM_PASSWORD}" scp -o StrictHostKeyChecking=no -P 2223 -r "${TMP_DIR}/scripts/"* ${VM_USERNAME}@localhost:~/scripts/
            
            # Run node1 setup script
            echo -e "${BLUE}Running setup-compute.sh on node1...${NC}"
            sshpass -p "${VM_PASSWORD}" ssh -o StrictHostKeyChecking=no -p 2223 ${VM_USERNAME}@localhost "cd ~ && chmod +x scripts/*.sh && sudo scripts/setup-compute.sh 1"
        else
            echo -e "${RED}Node1 SSH did not become available.${NC}"
        fi
        
        # Wait for node2 SSH
        echo -e "${BLUE}Waiting for SSH to become available on node2...${NC}"
        PORT_IS_OPEN=false
        
        for ((attempt=1; attempt<=MAX_ATTEMPTS; attempt++)); do
            echo -e "${YELLOW}Attempt ${attempt}/${MAX_ATTEMPTS}: Checking if node2 SSH is ready...${NC}"
            
            if nc -z localhost 2224; then
                PORT_IS_OPEN=true
                break
            fi
            
            echo -e "${YELLOW}SSH not ready yet. Waiting ${RETRY_INTERVAL} seconds...${NC}"
            sleep ${RETRY_INTERVAL}
        done
        
        if [ "$PORT_IS_OPEN" = true ]; then
            echo -e "${GREEN}Node2 SSH is available. Setting up node2...${NC}"
            
            # Copy scripts to node2
            echo -e "${BLUE}Copying setup scripts to node2...${NC}"
            sshpass -p "${VM_PASSWORD}" ssh -o StrictHostKeyChecking=no -p 2224 ${VM_USERNAME}@localhost "mkdir -p ~/scripts"
            sshpass -p "${VM_PASSWORD}" scp -o StrictHostKeyChecking=no -P 2224 -r "${TMP_DIR}/scripts/"* ${VM_USERNAME}@localhost:~/scripts/
            
            # Run node2 setup script
            echo -e "${BLUE}Running setup-compute.sh on node2...${NC}"
            sshpass -p "${VM_PASSWORD}" ssh -o StrictHostKeyChecking=no -p 2224 ${VM_USERNAME}@localhost "cd ~ && chmod +x scripts/*.sh && sudo scripts/setup-compute.sh 2"
        else
            echo -e "${RED}Node2 SSH did not become available.${NC}"
        fi
        
        echo -e "${GREEN}Cluster should be running. Check node status with:${NC}"
        echo -e "${YELLOW}sshpass -p ${VM_PASSWORD} ssh -o StrictHostKeyChecking=no -p 2222 ${VM_USERNAME}@localhost \"sudo /opt/slurm/bin/sinfo\"${NC}"
    else
        echo -e "${RED}Controller SSH did not become available. Cluster provisioning failed.${NC}"
    fi
}

# Function to stop the cluster
stop_cluster() {
    echo -e "${BLUE}Stopping Slurm cluster...${NC}"
    
    # Stop each VM by shutting it down via SSH
    for vm in controller node1 node2; do
        local port
        case $vm in
            controller) port=2222 ;;
            node1) port=2223 ;;
            node2) port=2224 ;;
        esac
        
        echo -e "${BLUE}Stopping ${vm}...${NC}"
        if nc -z localhost $port; then
            sshpass -p "${VM_PASSWORD}" ssh -o StrictHostKeyChecking=no -p $port ${VM_USERNAME}@localhost "sudo poweroff" || true
            echo -e "${GREEN}Shutdown command sent to ${vm}.${NC}"
        else
            echo -e "${YELLOW}${vm} does not appear to be running.${NC}"
        fi
    done
    
    # Wait for VMs to stop
    echo -e "${BLUE}Waiting for VMs to stop...${NC}"
    local timeout=60
    local count=0
    
    while [ $count -lt $timeout ]; do
        if ! pgrep -f "qemu-system-x86_64.*controller.qcow2" > /dev/null && \
           ! pgrep -f "qemu-system-x86_64.*node1.qcow2" > /dev/null && \
           ! pgrep -f "qemu-system-x86_64.*node2.qcow2" > /dev/null; then
            echo -e "${GREEN}All VMs stopped.${NC}"
            return 0
        fi
        
        sleep 5
        count=$((count + 5))
        echo -n "."
    done
    
    echo
    echo -e "${YELLOW}Some VMs may still be running. Consider using 'kill_qemu_processes' if needed.${NC}"
}

# Function to check cluster status
check_status() {
    echo -e "${BLUE}Checking cluster status...${NC}"
    
    # Check if each VM is running
    for vm in controller node1 node2; do
        local port
        case $vm in
            controller) port=2222 ;;
            node1) port=2223 ;;
            node2) port=2224 ;;
        esac
        
        if pgrep -f "qemu-system-x86_64.*${vm}.qcow2" > /dev/null; then
            echo -e "${GREEN}${vm} is running.${NC}"
            
            # Check if SSH is accessible
            if nc -z localhost $port; then
                echo -e "  ${GREEN}SSH is accessible on port ${port}${NC}"
                
                # If controller, check slurm status
                if [ "$vm" = "controller" ]; then
                    echo -e "  ${BLUE}Checking Slurm status...${NC}"
                    sshpass -p "${VM_PASSWORD}" ssh -o StrictHostKeyChecking=no -p $port ${VM_USERNAME}@localhost "sudo /opt/slurm/bin/sinfo" || \
                        echo -e "  ${YELLOW}Could not get Slurm status.${NC}"
                fi
            else
                echo -e "  ${YELLOW}SSH is not accessible on port ${port}${NC}"
            fi
        else
            echo -e "${RED}${vm} is not running.${NC}"
        fi
    done
}

# Function to connect to a VM
connect_to_vm() {
    local vm=$1
    local port
    
    case $vm in
        controller) port=2222 ;;
        node1) port=2223 ;;
        node2) port=2224 ;;
        *)
            echo -e "${RED}Invalid VM name: ${vm}${NC}"
            echo -e "${YELLOW}Valid options are: controller, node1, node2${NC}"
            exit 1
            ;;
    esac
    
    echo -e "${BLUE}Connecting to ${vm} on port ${port}...${NC}"
    
    # Check if VM is running
    if ! pgrep -f "qemu-system-x86_64.*${vm}.qcow2" > /dev/null; then
        echo -e "${RED}${vm} is not running.${NC}"
        exit 1
    fi
    
    # Check if SSH is accessible
    if ! nc -z localhost $port; then
        echo -e "${RED}SSH is not accessible on port ${port}${NC}"
        exit 1
    fi
    
    # Connect to VM
    echo -e "${GREEN}Connecting to ${vm}...${NC}"
    sshpass -p "${VM_PASSWORD}" ssh -o StrictHostKeyChecking=no -p $port ${VM_USERNAME}@localhost
}

# Function to clean up
clean_up() {
    echo -e "${YELLOW}Cleaning up...${NC}"
    
    # Kill any running VMs
    kill_qemu_processes
    
    # Ask before removing images
    echo -e "${YELLOW}Do you want to remove all VM images? [y/N]${NC}"
    read -r remove_images
    
    if [[ "$remove_images" =~ ^[Yy]$ ]]; then
        echo -e "${BLUE}Removing VM images...${NC}"
        rm -f "${VM_DIR}"/*.qcow2 "${VM_DIR}"/*.img
        rm -f "${TMP_DIR}"/*.sh "${TMP_DIR}"/*.qcow2
        echo -e "${GREEN}VM images removed.${NC}"
    else
        echo -e "${BLUE}Keeping VM images.${NC}"
    fi
    
    echo -e "${GREEN}Cleanup complete.${NC}"
}

# Main script
main() {
    # Check if a command was provided
    if [ $# -eq 0 ]; then
        show_help
        exit 0
    fi
    
    # Parse command
    case "$1" in
        build-base)
            check_dependencies
            create_directories
            kill_qemu_processes
            build_base_vm
            ;;
        build-cluster)
            check_dependencies
            create_directories
            build_cluster
            ;;
        start-cluster)
            check_dependencies
            create_directories
            start_cluster
            ;;
        stop-cluster)
            stop_cluster
            ;;
        clean)
            clean_up
            ;;
        status)
            check_status
            ;;
        connect)
            if [ -z "$2" ]; then
                echo -e "${RED}Please specify a VM to connect to.${NC}"
                echo -e "${YELLOW}Usage: $0 connect [controller|node1|node2]${NC}"
                exit 1
            fi
            connect_to_vm "$2"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            echo -e "${RED}Unknown command: $1${NC}"
            show_help
            exit 1
            ;;
    esac
}

# Call main function with all arguments
main "$@"
