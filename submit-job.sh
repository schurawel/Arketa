#!/bin/bash
# Submit a job from local sample-jobs folder to the remote SLURM cluster

set -e

# Server configuration (same as real-cluster-build.sh)
CONTROLLER_SERVER="server2"
CONTROLLER_IP="192.168.1.202"
CONTROLLER_PASSWORD="Server2Pwd"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

# Check for required tools
if ! command -v sshpass &> /dev/null; then
    echo -e "${RED}sshpass is required but not installed. Installing...${NC}"
    sudo apt-get update && sudo apt-get install -y sshpass
fi

# Check if sample-jobs directory exists
if [ ! -d "./sample-jobs" ]; then
    echo -e "${RED}Error: 'sample-jobs' directory not found in the current directory.${NC}"
    echo -e "${YELLOW}Make sure you are running this script from the PrimedSLURM directory.${NC}"
    exit 1
fi

# Show usage if no arguments provided
if [ $# -eq 0 ]; then
    echo -e "${BLUE}SLURM Job Submission Script${NC}"
    echo -e "${YELLOW}Usage: $0 [job_script] [options]${NC}"
    echo ""
    echo -e "${YELLOW}Available job scripts in sample-jobs/:${NC}"
    ls -1 ./sample-jobs/*.sh | sed 's|./sample-jobs/||' | while read job; do
        echo -e "  ${GREEN}$job${NC}"
    done
    echo ""
    echo -e "${YELLOW}Options:${NC}"
    echo -e "  ${GREEN}--watch${NC}     Monitor job status and show output when complete"
    echo -e "  ${GREEN}--status${NC}    Show current cluster status (sinfo and squeue)"
    echo -e "  ${GREEN}--output${NC}    Show recent job outputs"
    echo ""
    echo -e "${YELLOW}Examples:${NC}"
    echo -e "  $0 hello_world.sh --watch"
    echo -e "  $0 cpu_stress.sh"
    echo -e "  $0 --status"
    echo -e "  $0 --output"
    exit 0
fi

# Handle special options
case "$1" in
    --status)
        echo -e "${BLUE}Checking SLURM cluster status...${NC}"
        remote_exec "$CONTROLLER_IP" "$CONTROLLER_PASSWORD" "
            echo 'Cluster status (sinfo):'
            /opt/slurm/bin/sinfo || sudo /opt/slurm/bin/sinfo
            echo
            echo 'Job queue (squeue):'
            /opt/slurm/bin/squeue || sudo /opt/slurm/bin/squeue
        " "$CONTROLLER_SERVER"
        exit 0
        ;;
    --output)
        echo -e "${BLUE}Checking recent job outputs...${NC}"
        remote_exec "$CONTROLLER_IP" "$CONTROLLER_PASSWORD" "
            echo 'Recent job output files:'
            find ~ -name '*.out' -newer /tmp -exec ls -la {} \\; 2>/dev/null || echo 'No recent job output files found'
            echo
            echo 'Contents of recent output files:'
            find ~ -name '*.out' -newer /tmp -exec echo 'File: {}' \\; -exec cat {} \\; -exec echo '---' \\; 2>/dev/null || echo 'No job outputs to display'
        " "$CONTROLLER_SERVER"
        exit 0
        ;;
esac

# Parse arguments
JOB_SCRIPT="$1"
WATCH_JOB=false

# Check for --watch option
if [ "$2" = "--watch" ] || [ "$1" = "--watch" ]; then
    WATCH_JOB=true
    if [ "$1" = "--watch" ]; then
        echo -e "${RED}Error: Please specify a job script before --watch option${NC}"
        exit 1
    fi
fi

# Validate job script exists
if [ ! -f "./sample-jobs/$JOB_SCRIPT" ]; then
    echo -e "${RED}Error: Job script '$JOB_SCRIPT' not found in sample-jobs directory${NC}"
    echo -e "${YELLOW}Available scripts:${NC}"
    ls -1 ./sample-jobs/*.sh | sed 's|./sample-jobs/||'
    exit 1
fi

echo -e "${BLUE}Submitting job: ${GREEN}$JOB_SCRIPT${NC}"

# Test SSH connectivity
echo -e "${YELLOW}Testing connection to cluster controller...${NC}"
if ! remote_exec "$CONTROLLER_IP" "$CONTROLLER_PASSWORD" "echo 'Connected to SLURM controller'" "$CONTROLLER_SERVER" &>/dev/null; then
    echo -e "${RED}Cannot connect to controller. Please check SSH access and credentials.${NC}"
    exit 1
fi
echo -e "${GREEN}✅ Connected to controller${NC}"

# Copy job script to controller
echo -e "${YELLOW}Copying job script to controller...${NC}"
remote_copy "$CONTROLLER_IP" "$CONTROLLER_PASSWORD" "./sample-jobs/$JOB_SCRIPT" "/tmp/" "$CONTROLLER_SERVER"

# Submit the job
echo -e "${YELLOW}Submitting job to SLURM...${NC}"
JOB_OUTPUT=$(remote_exec "$CONTROLLER_IP" "$CONTROLLER_PASSWORD" "
    chmod +x /tmp/$JOB_SCRIPT
    cd ~
    /opt/slurm/bin/sbatch /tmp/$JOB_SCRIPT || sudo /opt/slurm/bin/sbatch /tmp/$JOB_SCRIPT
" "$CONTROLLER_SERVER")

echo -e "${GREEN}✅ Job submitted successfully!${NC}"
echo -e "${BLUE}Output: ${NC}$JOB_OUTPUT"

# Extract job ID from output
JOB_ID=$(echo "$JOB_OUTPUT" | grep -o '[0-9]\+' | head -1)

if [ -n "$JOB_ID" ]; then
    echo -e "${BLUE}Job ID: ${GREEN}$JOB_ID${NC}"
    
    # Show current queue status
    echo -e "${YELLOW}Current job queue:${NC}"
    remote_exec "$CONTROLLER_IP" "$CONTROLLER_PASSWORD" "
        /opt/slurm/bin/squeue || sudo /opt/slurm/bin/squeue
    " "$CONTROLLER_SERVER"
    
    # Watch job if requested
    if [ "$WATCH_JOB" = "true" ]; then
        echo -e "${BLUE}Monitoring job $JOB_ID (press Ctrl+C to stop monitoring)...${NC}"
        
        # Monitor job status
        while true; do
            JOB_STATUS=$(remote_exec "$CONTROLLER_IP" "$CONTROLLER_PASSWORD" "
                /opt/slurm/bin/squeue -j $JOB_ID -h -o '%T' 2>/dev/null || sudo /opt/slurm/bin/squeue -j $JOB_ID -h -o '%T' 2>/dev/null || echo 'COMPLETED'
            " "$CONTROLLER_SERVER" 2>/dev/null)
            
            if [ -z "$JOB_STATUS" ] || [ "$JOB_STATUS" = "COMPLETED" ]; then
                echo -e "${GREEN}✅ Job $JOB_ID completed!${NC}"
                break
            else
                echo -e "${YELLOW}Job $JOB_ID status: $JOB_STATUS${NC}"
                sleep 5
            fi
        done
        
        # Show job output
        echo -e "${BLUE}Fetching job output...${NC}"
        sleep 2  # Give time for output files to be written
        
        remote_exec "$CONTROLLER_IP" "$CONTROLLER_PASSWORD" "
            echo 'Looking for job output files...'
            
            # Try different possible output file patterns
            if ls ~/*_${JOB_ID}.out 2>/dev/null; then
                echo 'Job output:'
                cat ~/*_${JOB_ID}.out
            elif ls ~/job_outputs/*_${JOB_ID}.out 2>/dev/null; then
                echo 'Job output from job_outputs directory:'
                cat ~/job_outputs/*_${JOB_ID}.out
            elif ls ~/*.out 2>/dev/null | tail -1; then
                echo 'Most recent output file:'
                cat \$(ls -t ~/*.out | head -1)
            else
                echo 'No output files found. Checking for any recent outputs:'
                find ~ -name '*.out' -newer /tmp/$JOB_SCRIPT -exec echo 'Found: {}' \\; -exec cat {} \\; 2>/dev/null || echo 'No job output found'
            fi
            
            # Also check for error files
            if ls ~/*_${JOB_ID}.err 2>/dev/null; then
                echo
                echo 'Job errors (if any):'
                cat ~/*_${JOB_ID}.err
            fi
        " "$CONTROLLER_SERVER"
    else
        echo -e "${YELLOW}Use '$0 --output' to check job results later${NC}"
        echo -e "${YELLOW}Use '$0 --status' to check cluster status${NC}"
    fi
else
    echo -e "${RED}⚠️ Could not extract job ID from output${NC}"
fi

echo -e "${BLUE}Job submission complete!${NC}"
