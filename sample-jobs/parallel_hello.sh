#!/bin/bash
#SBATCH --job-name=parallel_hello
#SBATCH --output=~/job_outputs/parallel_hello_%j.out
#SBATCH --error=~/job_outputs/parallel_hello_%j.err
#SBATCH --time=00:10:00
#SBATCH --nodes=2
#SBATCH --ntasks=4
#SBATCH --cpus-per-task=1
#SBATCH --partition=compute

mkdir -p ~/job_outputs
cd ~/job_outputs

echo "Parallel Hello World from Slurm!"
echo "Job ID: $SLURM_JOB_ID"
echo "Node list: $SLURM_JOB_NODELIST"
echo "Number of nodes: $SLURM_JOB_NUM_NODES"
echo "Number of tasks: $SLURM_NTASKS"
echo "Task ID: $SLURM_PROCID"
echo "Local task ID: $SLURM_LOCALID"

# Run a command on each task
srun bash -c '
    echo "Task $SLURM_PROCID running on node $(hostname)"
    echo "Local task ID: $SLURM_LOCALID"
    echo "Working directory: $(pwd)"
    
    # Each task does some computation
    task_id=$SLURM_PROCID
    start=$((task_id * 250 + 1))
    end=$(((task_id + 1) * 250))
    
    echo "Task $task_id calculating sum from $start to $end"
    sum=0
    for i in $(seq $start $end); do
        sum=$((sum + i))
    done
    echo "Task $task_id: Sum from $start to $end = $sum"
    
    # Simulate some work
    sleep $((5 + RANDOM % 10))
    
    echo "Task $task_id completed"
'

echo "All parallel tasks completed!"
