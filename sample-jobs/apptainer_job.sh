#!/bin/bash
#SBATCH --job-name=apptainer_test
#SBATCH --output=apptainer_test_%j.out
#SBATCH --error=apptainer_test_%j.err
#SBATCH --time=00:15:00
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=2
#SBATCH --partition=compute

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

# Build Apptainer image locally (outside SLURM job)
# This should be run manually or as a Makefile step, not inside the job script
# Example command to run in the repo root:
#   apptainer build sample-jobs/ubuntu_python.sif sample-jobs/ubuntu_python.def

# In the job, just run the pre-built image
CONTAINER_IMAGE="/home/vagrant/sample-jobs/ubuntu_python.sif"

if [ -f "$CONTAINER_IMAGE" ]; then
    echo "=== Running Python in Apptainer container ==="
    apptainer exec --writable-tmpfs "$CONTAINER_IMAGE" python3 -c "import sys; print('Python in Apptainer:', sys.version)"
else
    echo "Container image $CONTAINER_IMAGE not found!"
    exit 1
fi

echo "=== Final System Check ==="
echo "Available space:"
df -h /tmp
echo "Memory usage:"
free -h

echo "Apptainer job completed on $(date)"

exec > >(tee -a apptainer_test_${SLURM_JOB_ID}.out) 2> >(tee -a apptainer_test_${SLURM_JOB_ID}.err >&2)