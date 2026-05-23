#!/bin/bash
# filepath: /home/thinclient2/Documents/PrimedSLURM/real-cluster-build.sh

set -e

# Server configuration
SERVERS=("server2" "server3" "server4")
IPS=("192.168.1.202" "192.168.1.203" "192.168.1.204")
PASSWORDS=("Server2Pwd" "Server3Pwd" "Server4Pwd")

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to execute commands on remote server
remote_exec() {
    local server=$1
    local password=$2
    local command=$3
    local username=$4
    
    # Replace sudo with echo password | sudo -S for all sudo commands
    local modified_command="${command//sudo /echo \"$password\" | sudo -S }"
    
    sshpass -p "$password" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password -o PubkeyAuthentication=no $username@$server "$modified_command"
}

# Function to copy files to remote server
remote_copy() {
    local server=$1
    local password=$2
    local source=$3
    local dest=$4
    local username=$5
    
    sshpass -p "$password" scp -r -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password -o PubkeyAuthentication=no "$source" $username@$server:"$dest"
}

echo -e "${GREEN}Starting SLURM cluster deployment on physical servers...${NC}"

# Ask user what they want to do
echo -e "${YELLOW}What would you like to do?${NC}"
echo "1. Full cluster deployment (base setup + SLURM + tools)"
echo "2. Skip base setup (SLURM + tools only)"
echo "3. Tools setup only (OnDemand, slurm-web)"
echo "4. Test cluster functionality only"
read -p "Choose option (1-4): " -n 1 -r
echo

SKIP_BASE_SETUP=false
TOOLS_ONLY=false
TEST_ONLY=false

case $REPLY in
    1)
        echo -e "${GREEN}Full deployment selected${NC}"
        ;;
    2)
        SKIP_BASE_SETUP=true
        echo -e "${YELLOW}Base setup will be skipped${NC}"
        ;;
    3)
        SKIP_BASE_SETUP=true
        TOOLS_ONLY=true
        echo -e "${YELLOW}Tools setup only - skipping SLURM deployment${NC}"
        ;;
    4)
        SKIP_BASE_SETUP=true
        TOOLS_ONLY=true
        TEST_ONLY=true
        echo -e "${YELLOW}Test cluster functionality only${NC}"
        ;;
    *)
        echo -e "${GREEN}Default: Full deployment${NC}"
        ;;
esac

# Check for required tools
if ! command -v sshpass &> /dev/null; then
    echo -e "${RED}sshpass is required but not installed. Installing...${NC}"
    sudo apt-get update && sudo apt-get install -y sshpass
fi

# Test SSH connectivity
echo -e "${YELLOW}Testing SSH connectivity to all servers...${NC}"
for i in {0..2}; do
    echo -n "Testing ${SERVERS[$i]} (${IPS[$i]})... "
    if remote_exec "${IPS[$i]}" "${PASSWORDS[$i]}" "echo 'Connected'" "${SERVERS[$i]}" &>/dev/null; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC}"
        echo "Cannot connect to ${SERVERS[$i]}. Please check SSH access and credentials."
        exit 1
    fi
done

# Update /etc/hosts on all servers
echo -e "${YELLOW}Updating /etc/hosts on all servers...${NC}"
HOSTS_CONTENT="
192.168.1.202 server2 slurm-controller
192.168.1.203 server3 node1
192.168.1.204 server4 node2
"

for i in {0..2}; do
    echo "Updating ${SERVERS[$i]}..."
    remote_exec "${IPS[$i]}" "${PASSWORDS[$i]}" "
        # Backup original hosts file
        sudo cp /etc/hosts /etc/hosts.backup
        
        # Remove any existing server entries
        sudo sed -i '/server[2-4]/d' /etc/hosts
        sudo sed -i '/slurm-controller/d' /etc/hosts
        sudo sed -i '/node[1-2]/d' /etc/hosts
        
        # Add new entries
        echo '$HOSTS_CONTENT' | sudo tee -a /etc/hosts > /dev/null
    " "${SERVERS[$i]}"
done

# Set proper hostnames for SLURM cluster
echo -e "${YELLOW}Setting hostnames for SLURM cluster...${NC}"
SLURM_HOSTNAMES=("slurm-controller" "node1" "node2")

for i in {0..2}; do
    echo "Setting hostname on ${SERVERS[$i]} to ${SLURM_HOSTNAMES[$i]}..."
    remote_exec "${IPS[$i]}" "${PASSWORDS[$i]}" "
        # Set the hostname immediately
        sudo hostnamectl set-hostname ${SLURM_HOSTNAMES[$i]}
        
        # Verify the hostname was set
        echo 'New hostname:' \$(hostname)
        
        # Update /etc/hostname to persist across reboots
        echo '${SLURM_HOSTNAMES[$i]}' | sudo tee /etc/hostname > /dev/null
    " "${SERVERS[$i]}"
done

# Check if scripts directory exists locally
if [ ! -d "./scripts" ]; then
    echo -e "${RED}Error: 'scripts' directory not found in the current directory.${NC}"
    echo -e "${YELLOW}Make sure you are running this script from the PrimedSLURM directory with the 'scripts' subdirectory.${NC}"
    exit 1
fi

# Create configs directory if it doesn't exist
echo -e "${YELLOW}Creating configs directory for Slurm...${NC}"
mkdir -p "./scripts/configs"

# Create shared munge key for cluster authentication
echo -e "${YELLOW}Creating shared munge key for cluster authentication...${NC}"
MUNGE_KEY_PATH="./scripts/configs/munge.key"

# Create munge key if it doesn't exist
if [ ! -f "$MUNGE_KEY_PATH" ]; then
    echo -e "${YELLOW}Generating new munge key...${NC}"
    dd if=/dev/urandom bs=1 count=1024 > "$MUNGE_KEY_PATH" 2>/dev/null
    chmod 644 "$MUNGE_KEY_PATH"  # Temporarily more permissive for copying
    echo -e "${GREEN}Shared munge key created at: ${MUNGE_KEY_PATH}${NC}"
else
    echo -e "${GREEN}Using existing shared munge key: ${MUNGE_KEY_PATH}${NC}"
    # Ensure permissions allow copying
    chmod 644 "$MUNGE_KEY_PATH"
fi

# Install base packages on all servers
echo -e "${YELLOW}Installing base packages on all servers...${NC}"
for i in {0..2}; do
    echo "Installing base packages on ${SERVERS[$i]}..."
    remote_exec "${IPS[$i]}" "${PASSWORDS[$i]}" "
        export DEBIAN_FRONTEND=noninteractive
        sudo apt-get update
        sudo apt-get install -y build-essential git python3 python3-pip openssh-server
    " "${SERVERS[$i]}"
done

# Disable sleep mode and power management on all servers
echo -e "${YELLOW}Disabling sleep mode and power management on all servers...${NC}"
for i in {0..2}; do
    echo "Configuring power settings on ${SERVERS[$i]}..."
    remote_exec "${IPS[$i]}" "${PASSWORDS[$i]}" "
        echo 'Disabling sleep, suspend, and hibernation...'
        
        # Disable systemd sleep/suspend/hibernate targets
        sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
        
        # Disable power management in systemd
        sudo mkdir -p /etc/systemd/sleep.conf.d
        echo '[Sleep]
AllowSuspend=no
AllowHibernation=no
AllowSuspendThenHibernate=no
AllowHybridSleep=no' | sudo tee /etc/systemd/sleep.conf.d/disable-sleep.conf
        
        # Configure systemd-logind to ignore power button and lid events
        sudo mkdir -p /etc/systemd/logind.conf.d
        echo '[Login]
HandlePowerKey=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
IdleAction=ignore' | sudo tee /etc/systemd/logind.conf.d/disable-power-management.conf
        
        # Disable CPU frequency scaling (set to performance mode)
        echo 'Setting CPU governor to performance mode...'
        echo 'performance' | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null || echo 'CPU frequency scaling not available or already configured'
        
        # Install and configure cpufrequtils for persistent CPU performance mode
        sudo apt-get install -y cpufrequtils 2>/dev/null || echo 'cpufrequtils installation skipped'
        echo 'GOVERNOR=\"performance\"' | sudo tee /etc/default/cpufrequtils 2>/dev/null || true
        
        # Disable automatic suspend in GNOME/Ubuntu desktop (if present)
        gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing' 2>/dev/null || true
        gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing' 2>/dev/null || true
        gsettings set org.gnome.desktop.session idle-delay 0 2>/dev/null || true
        
        # Reload systemd configuration
        sudo systemctl daemon-reload
        sudo systemctl restart systemd-logind
        
        echo '✅ Power management disabled on ${SERVERS[$i]}'
        
        # Verify power management settings
        echo 'Verifying power management configuration:'
        echo '- Sleep targets status:'
        sudo systemctl is-enabled sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null || echo 'Sleep targets are masked'
        echo '- Current CPU governor:'
        cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo 'CPU frequency scaling not available'
        echo '- Power management verification complete'
    " "${SERVERS[$i]}"
done

# Copy scripts directory to all servers
echo -e "${YELLOW}Copying setup scripts to all servers...${NC}"
for i in {0..2}; do
    echo "Copying scripts to ${SERVERS[$i]}..."
    
    # Remove existing scripts directory and recreate to ensure clean copy
    remote_exec "${IPS[$i]}" "${PASSWORDS[$i]}" "rm -rf ~/scripts && mkdir -p ~/scripts" "${SERVERS[$i]}"
    
    # Copy the contents of scripts directory (not the directory itself)
    sshpass -p "${PASSWORDS[$i]}" scp -r -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password -o PubkeyAuthentication=no "./scripts/"* "${SERVERS[$i]}@${IPS[$i]}:~/scripts/"
    
    # Verify files were copied before setting permissions
    echo "Verifying files were copied to ${SERVERS[$i]}..."
    remote_exec "${IPS[$i]}" "${PASSWORDS[$i]}" "ls -la ~/scripts/" "${SERVERS[$i]}"
    
    # Set execute permissions on scripts only if they exist
    remote_exec "${IPS[$i]}" "${PASSWORDS[$i]}" "
        if ls ~/scripts/*.sh 1> /dev/null 2>&1; then
            chmod +x ~/scripts/*.sh
            echo 'Execute permissions set on shell scripts'
        else
            echo 'No shell scripts found to set permissions on'
        fi
    " "${SERVERS[$i]}"
    
    # Verify the pip commands have --break-system-packages in the copied scripts
    echo "Verifying pip commands in copied scripts on ${SERVERS[$i]}..."
    remote_exec "${IPS[$i]}" "${PASSWORDS[$i]}" "
        if [ -f ~/scripts/setup-base.sh ]; then
            echo 'Checking setup-base.sh for --break-system-packages flag:'
            grep -n 'pip.*install.*--break-system-packages' ~/scripts/setup-base.sh || echo 'WARNING: --break-system-packages not found in setup-base.sh'
        else
            echo 'ERROR: setup-base.sh not found after copying!'
        fi
    " "${SERVERS[$i]}"
done

# Step 1: Run base setup on all servers (if not skipped)
if [ "$SKIP_BASE_SETUP" = "true" ]; then
    echo -e "${YELLOW}Skipping base setup as requested${NC}"
else
    echo -e "${YELLOW}Running base setup on all servers...${NC}"
    for i in {0..2}; do
        echo "Setting up base environment on ${SERVERS[$i]}..."
        remote_exec "${IPS[$i]}" "${PASSWORDS[$i]}" "
            echo 'Running setup-base.sh...'
            cd ~
            sudo ./scripts/setup-base.sh
        " "${SERVERS[$i]}"
    done
fi

# If TEST_ONLY is selected, skip to testing
if [ "$TEST_ONLY" = "true" ]; then
    echo -e "${BLUE}Jumping directly to cluster testing...${NC}"
    # Jump to the test section (we'll add a label here)
    goto_test_section=true
else
    goto_test_section=false
fi

# Skip SLURM setup if TOOLS_ONLY or TEST_ONLY
if [ "$TOOLS_ONLY" = "false" ]; then

# Step 2: Setup the controller node (server2)
echo -e "${YELLOW}Setting up controller node (server2)...${NC}"
remote_exec "${IPS[0]}" "${PASSWORDS[0]}" "
    echo 'Running setup-controller.sh...'
    cd ~
    sudo ./scripts/setup-controller.sh
" "${SERVERS[0]}"

# Step 4: Setup the slurm database daemon on controller
echo -e "${YELLOW}Setting up slurm database daemon on controller...${NC}"
remote_exec "${IPS[0]}" "${PASSWORDS[0]}" "
    echo 'Running setup-slurmdbd.sh...'
    cd ~
    sudo ./scripts/setup-slurmdbd.sh
" "${SERVERS[0]}"

# Step 5: Setup compute nodes (server3 and server4)
for i in {1..2}; do
    echo -e "${YELLOW}Setting up compute node ${SERVERS[$i]}...${NC}"
    # Pass the node ID (1 or 2) to the setup script
    node_id=$i
    remote_exec "${IPS[$i]}" "${PASSWORDS[$i]}" "
        echo 'Running setup-compute.sh with node ID $node_id...'
        cd ~
        sudo ./scripts/setup-compute.sh $node_id
    " "${SERVERS[$i]}"
done

fi  # End of SLURM setup section

# Tools and Testing Section (runs for TOOLS_ONLY, TEST_ONLY, or normal deployment)
if [ "$goto_test_section" = "false" ] || [ "$TOOLS_ONLY" = "true" ]; then

# Step 5.5: Restart SLURM services on all nodes after full setup (skip if TEST_ONLY or TOOLS_ONLY)
if [ "$TEST_ONLY" = "false" ] && [ "$TOOLS_ONLY" = "false" ]; then
echo -e "${YELLOW}Restarting SLURM services on all nodes after full cluster setup...${NC}"

# Restart services on controller first
echo "Restarting services on controller (server2)..."
remote_exec "${IPS[0]}" "${PASSWORDS[0]}" "
    echo 'Restarting munge, slurmctld, and slurmd on controller...'
    sudo systemctl restart munge
    sleep 3
    sudo systemctl restart slurmctld
    sleep 3
    sudo systemctl restart slurmd
    sleep 3
    
    echo 'Checking controller service status...'
    if sudo systemctl is-active --quiet munge; then
        echo '✅ Munge service is running on controller'
    else
        echo '❌ Munge service is not running on controller'
    fi
    
    if sudo systemctl is-active --quiet slurmctld; then
        echo '✅ Slurmctld service is running on controller'
    else
        echo '❌ Slurmctld service is not running on controller'
    fi
    
    if sudo systemctl is-active --quiet slurmd; then
        echo '✅ Slurmd service is running on controller'
    else
        echo '❌ Slurmd service is not running on controller'
    fi
" "${SERVERS[0]}"

# Restart services on compute nodes
for i in {1..2}; do
    echo "Restarting services on compute node ${SERVERS[$i]}..."
    remote_exec "${IPS[$i]}" "${PASSWORDS[$i]}" "
        echo 'Restarting munge and slurmd on ${SERVERS[$i]}...'
        sudo systemctl restart munge
        sleep 3
        sudo systemctl restart slurmd
        sleep 3
        
        echo 'Checking compute node service status...'
        if sudo systemctl is-active --quiet munge; then
            echo '✅ Munge service is running on ${SERVERS[$i]}'
        else
            echo '❌ Munge service is not running on ${SERVERS[$i]}'
        fi
        
        if sudo systemctl is-active --quiet slurmd; then
            echo '✅ Slurmd service is running on ${SERVERS[$i]}'
        else
            echo '❌ Slurmd service is not running on ${SERVERS[$i]}'
        fi
    " "${SERVERS[$i]}"
done

fi  # End of service restart section

# Test Section - runs for normal deployment and TEST_ONLY mode (skip for TOOLS_ONLY)
if [ "$TOOLS_ONLY" = "false" ]; then
echo -e "${BLUE}=== CLUSTER TESTING SECTION ===${NC}"

# Test full cluster functionality
echo -e "${GREEN}Testing SLURM cluster functionality...${NC}"
remote_exec "${IPS[0]}" "${PASSWORDS[0]}" "
    echo 'Waiting for cluster to stabilize...'
    sleep 10
    
    echo 'Running sinfo to check cluster status:'
    /opt/slurm/bin/sinfo || sudo /opt/slurm/bin/sinfo || echo 'sinfo command failed'
    
    echo 'Running squeue to check job queue:'
    /opt/slurm/bin/squeue || sudo /opt/slurm/bin/squeue || echo 'squeue command failed'
    
    echo 'Testing simple job submission using sample job:'
    
    # Use the hello_world.sh test job from sample-jobs
    if [ -f /shared/sample-jobs/hello_world.sh ]; then
        echo 'Using hello_world.sh from sample-jobs...'
        cp /shared/sample-jobs/hello_world.sh /tmp/test_job.sh
    else
        echo 'Sample jobs not found, creating basic test job...'
        echo '#!/bin/bash
#SBATCH --job-name=test_job
#SBATCH --output=test_job.out
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --time=00:01:00

echo \"🎉 SUCCESS! SLURM cluster is working!\"
hostname
date
' > /tmp/test_job.sh
    fi
    
    chmod +x /tmp/test_job.sh
    
    if /opt/slurm/bin/sbatch /tmp/test_job.sh; then
        echo '✅ Test job submitted successfully!'
        echo 'Checking job status:'
        sleep 5
        /opt/slurm/bin/squeue || true
        echo 'Job output (waiting for completion):'
        sleep 15
        
        # Check for job output files (both possible patterns)
        if [ -f ~/test_job.out ]; then
            echo 'Job output from test_job.out:'
            cat ~/test_job.out
        elif [ -f ~/hello_world_*.out ]; then
            echo 'Job output from hello_world job:'
            cat ~/hello_world_*.out
        elif [ -f ~/job_outputs/hello_world_*.out ]; then
            echo 'Job output from job_outputs directory:'
            cat ~/job_outputs/hello_world_*.out
        else
            echo 'Job output not yet available. Checking for any recent job output files:'
            find ~ -name \"*.out\" -newer /tmp/test_job.sh -exec echo \"Found: {}\" \\; -exec cat {} \\; 2>/dev/null || echo 'No job output files found'
        fi
    else
        echo '❌ Test job submission failed'
    fi
" "${SERVERS[0]}"

fi  # End of cluster testing section

# Step 6: Setup OnDemand on controller if requested (skip if TEST_ONLY)
if [ "$TEST_ONLY" = "false" ]; then
echo -e "${YELLOW}Setting up OnDemand web portal on controller...${NC}"

# Ensure OnDemand setup script is available locally
echo "Ensuring OnDemand setup script is available locally..."
if [ ! -f "scripts/setup-ondemand-real.sh" ]; then
    echo -e "${RED}Error: setup-ondemand-real.sh not found in local scripts directory${NC}"
    echo -e "${RED}This script is required for OnDemand setup. No fallbacks will be used.${NC}"
    exit 1
fi

# ALWAYS copy OnDemand setup script to controller (to ensure latest version)
echo "Copying OnDemand setup script to controller (ensuring latest version)..."
remote_exec "${IPS[0]}" "${PASSWORDS[0]}" "mkdir -p ~/scripts" "${SERVERS[0]}"

# Copy the OnDemand setup script
echo "Copying setup-ondemand-real.sh..."
sshpass -p "${PASSWORDS[0]}" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password -o PubkeyAuthentication=no "./scripts/setup-ondemand-real.sh" "${SERVERS[0]}@${IPS[0]}:~/scripts/"

# Also copy the main OnDemand setup script that setup-ondemand-real.sh depends on
echo "Copying setup-ondemand.sh (dependency)..."
if [ -f "./scripts/setup-ondemand.sh" ]; then
    sshpass -p "${PASSWORDS[0]}" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password -o PubkeyAuthentication=no "./scripts/setup-ondemand.sh" "${SERVERS[0]}@${IPS[0]}:~/scripts/"
    echo "✅ OnDemand dependency script copied"
else
    echo "⚠️  Warning: setup-ondemand.sh not found locally"
fi

# Set execute permissions on the copied script
remote_exec "${IPS[0]}" "${PASSWORDS[0]}" "chmod +x ~/scripts/setup-ondemand-real.sh" "${SERVERS[0]}"

# Verify the script was copied successfully
echo "Verifying OnDemand setup script was copied..."
remote_exec "${IPS[0]}" "${PASSWORDS[0]}" "
    if [ -f ~/scripts/setup-ondemand-real.sh ]; then
        echo '✅ OnDemand setup script successfully copied to server'
        ls -la ~/scripts/setup-ondemand-real.sh
    else
        echo '❌ FAILED: OnDemand setup script not found on server after copy'
        exit 1
    fi
" "${SERVERS[0]}"

# Run the OnDemand setup
echo "Running enhanced OnDemand setup for real cluster..."
remote_exec "${IPS[0]}" "${PASSWORDS[0]}" "
    cd ~
    sudo ./scripts/setup-ondemand-real.sh
" "${SERVERS[0]}"

echo -e "${GREEN}OnDemand setup completed on controller!${NC}"
echo -e "${BLUE}Access OnDemand at: http://192.168.1.202/${NC}"
echo -e "${BLUE}Default credentials: ooduser / ooduser${NC}"

fi  # End of OnDemand setup

fi  # End of tools section

# Final status and completion

# Restore restrictive permissions on munge key
chmod 400 "$MUNGE_KEY_PATH"

echo -e "${GREEN}SLURM cluster deployment completed!${NC}"
echo -e "Controller (server2): ${IPS[0]}"
echo -e "Compute nodes: server3 (${IPS[1]}), server4 (${IPS[2]})"
echo -e "${YELLOW}You can check the status of the SLURM cluster by running:${NC}"
echo -e "sshpass -p \"${PASSWORDS[0]}\" ssh -o StrictHostKeyChecking=no ${SERVERS[0]}@${IPS[0]} \"sudo sinfo\""