#!/bin/bash
#SBATCH --job-name=ml_sim
#SBATCH --output=ml_simulation_%j.out
#SBATCH --error=ml_simulation_%j.err
#SBATCH --time=00:05:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --partition=compute

mkdir -p ~/job_outputs
cd ~/job_outputs

echo "ML Simulation Job"
echo "Job ID: $SLURM_JOB_ID"
echo "Node: $SLURM_JOB_NODELIST"
echo "Date: $(date)"

python3 -c "print('Simulating ML...')"
