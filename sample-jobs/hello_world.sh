#!/bin/bash
#SBATCH --job-name=hello_world
#SBATCH --output=hello_world_%j.out
#SBATCH --error=hello_world_%j.err
#SBATCH --time=00:05:00
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=1
#SBATCH --partition=compute

mkdir -p ~/job_outputs
cd ~/job_outputs

echo "Hello World from Slurm!"
echo "Job ID: $SLURM_JOB_ID"
echo "Node name: $SLURM_JOB_NODELIST"
echo "Number of nodes: $SLURM_JOB_NUM_NODES"
echo "Number of tasks: $SLURM_NTASKS"
echo "CPUs per task: $SLURM_CPUS_PER_TASK"
echo "Current working directory: $(pwd)"
echo "Date and time: $(date)"

# Some basic system information
echo "=== System Information ==="
echo "Hostname: $(hostname)"
echo "Operating System: $(uname -a)"
echo "CPU Information:"
lscpu | grep -E "Architecture|CPU\(s\)|Model name|CPU MHz"
echo "Memory Information:"
free -h
echo "Disk usage:"
df -h /

# Simple computation
echo "=== Simple Computation ==="
echo "Calculating sum of numbers 1 to 1000..."
sum=0
for i in {1..1000}; do
    sum=$((sum + i))
done
echo "Sum of 1 to 1000: $sum"

# Sleep for a few seconds to simulate work
echo "Simulating work... sleeping for 10 seconds"
sleep 10

echo "Job completed successfully!"
echo "Output file: hello_world_${SLURM_JOB_ID}.out"
echo "Error file: hello_world_${SLURM_JOB_ID}.err"
echo "To view this output: cat ~/hello_world_${SLURM_JOB_ID}.out"
