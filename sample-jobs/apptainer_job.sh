#!/bin/bash
#SBATCH --job-name=apptainer_test
#SBATCH --output=apptainer_test_%j.out
#SBATCH --error=apptainer_test_%j.err
#SBATCH --time=00:15:00
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=2
#SBATCH --partition=compute

# Save original directory path where job was submitted
SUBMIT_DIR=$(pwd)

# Ensure all outputs are explicitly captured in SLURM output files
mkdir -p ~/job_outputs
cd ~/job_outputs

echo "Apptainer Container Job"
echo "Job ID: $SLURM_JOB_ID"
echo "Node: $SLURM_JOB_NODELIST"
echo "CPUs allocated: $SLURM_CPUS_PER_TASK"
echo "Date: $(date)"

# Check if Apptainer is available
echo "=== Checking Apptainer Installation ==="
which apptainer || echo "Apptainer not found in PATH"
apptainer --version || echo "Cannot get Apptainer version"

# Use the correct path to the container image directly
CONTAINER_IMAGE="/home/ubuntu/sample-jobs/ubuntu_python.sif"

# Run the container
if [ -f "$CONTAINER_IMAGE" ]; then
    echo "=== Running Python in Apptainer container ==="
    echo "Using container at: $CONTAINER_IMAGE"
    apptainer exec --writable-tmpfs "$CONTAINER_IMAGE" python3 -c "import sys; print('Python in Apptainer:', sys.version)"
else
    echo "Container image not found at $CONTAINER_IMAGE!"
    echo "Available files in sample-jobs directory:"
    ls -la /home/ubuntu/sample-jobs/
    exit 1
fi

echo "=== Final System Check ==="
echo "Available space:"
df -h /tmp
echo "Memory usage:"
free -h

echo "Apptainer job completed on $(date)"

exec > >(tee -a apptainer_test_${SLURM_JOB_ID}.out) 2> >(tee -a apptainer_test_${SLURM_JOB_ID}.err >&2)