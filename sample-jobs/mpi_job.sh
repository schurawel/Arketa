#!/bin/bash
#SBATCH --job-name=mpi-hello
#SBATCH --output=mpi-hello-%j.out
#SBATCH --error=mpi-hello-%j.err
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=2
#SBATCH --cpus-per-task=1
#SBATCH --time=00:05:00

# Set some environment variables to improve MPI behavior
export OMPI_MCA_btl_vader_single_copy_mechanism=none

# It's good practice to clean up previous builds
rm -f ./mpi_hello

echo "Starting MPI job compilation and execution..."
echo "SLURM_JOB_ID: $SLURM_JOB_ID"
echo "SLURM_NTASKS: $SLURM_NTASKS" 
echo "SLURM_NNODES: $SLURM_NNODES"

# Compile the MPI program inside the job script.
# The source file is expected to be in the same directory as the job script.
# /home/vagrant/sample-jobs/ is the synced folder inside the VM.
echo "Compiling MPI program..."
mpicc -o mpi_hello /home/vagrant/sample-jobs/mpi_hello.c

# Check if compilation was successful
if [ $? -ne 0 ]; then
    echo "MPI program compilation failed"
    exit 1
fi

echo "Compilation successful. Starting MPI execution..."

# Run the MPI program using srun with timeout to prevent hanging
# Use available MPI plugins: none, pmi2, pmix, pmix_v4
timeout 120 srun --mpi=pmix ./mpi_hello

exit_code=$?
if [ $exit_code -eq 124 ]; then
    echo "MPI job timed out after 120 seconds"
    exit 1
elif [ $exit_code -ne 0 ]; then
    echo "MPI job failed with exit code: $exit_code"
    exit $exit_code
else
    echo "MPI job completed successfully"
fi
