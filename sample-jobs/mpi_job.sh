#!/bin/bash
#SBATCH --job-name=mpi-hello
#SBATCH --output=mpi-hello-%j.out
#SBATCH --error=mpi-hello-%j.err
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=2
#SBATCH --cpus-per-task=1
#SBATCH --time=00:05:00

# It's good practice to clean up previous builds
rm -f ./mpi_hello

# Compile the MPI program inside the job script.
# The source file is expected to be in the same directory as the job script.
# /home/vagrant/sample-jobs/ is the synced folder inside the VM.
mpicc -o mpi_hello /home/vagrant/sample-jobs/mpi_hello.c

# Check if compilation was successful
if [ $? -ne 0 ]; then
    echo "MPI program compilation failed"
    exit 1
fi

# Run the MPI program using srun
srun ./mpi_hello
