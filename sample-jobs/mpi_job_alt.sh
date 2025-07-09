#!/bin/bash
#SBATCH --job-name=mpi-hello-alt
#SBATCH --output=mpi-hello-alt-%j.out
#SBATCH --error=mpi-hello-alt-%j.err
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=2
#SBATCH --cpus-per-task=1
#SBATCH --time=00:05:00

# Set environment variables for better MPI behavior
export OMPI_MCA_btl_vader_single_copy_mechanism=none
export OMPI_MCA_btl="^vader,tcp,openib,uct"
export OMPI_MCA_pml=ob1

# It's good practice to clean up previous builds
rm -f ./mpi_hello

# Compile the MPI program inside the job script.
echo "Compiling MPI program..."
mpicc -o mpi_hello /home/vagrant/sample-jobs/mpi_hello.c

# Check if compilation was successful
if [ $? -ne 0 ]; then
    echo "MPI program compilation failed"
    exit 1
fi

echo "Compilation successful, starting MPI job..."

# Try different srun configurations
echo "Attempting to run with default srun..."
timeout 60 srun ./mpi_hello

if [ $? -eq 124 ]; then
    echo "Default srun timed out, trying with pmix..."
    timeout 60 srun --mpi=pmix ./mpi_hello
fi

if [ $? -eq 124 ]; then
    echo "pmix timed out, trying with pmi2..."
    timeout 60 srun --mpi=pmi2 ./mpi_hello
fi

if [ $? -eq 124 ]; then
    echo "pmi2 timed out, trying with mpirun directly..."
    timeout 60 mpirun -np $SLURM_NTASKS ./mpi_hello
fi

echo "MPI job completed."
