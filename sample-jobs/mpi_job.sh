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

# Use shared directory for compiled executable so it's accessible to all nodes
SHARED_DIR="/shared/mpi-jobs"
mkdir -p "$SHARED_DIR"

# Clean up previous builds
rm -f "$SHARED_DIR/mpi_hello"
rm -f ./mpi_hello.c

echo "Starting MPI job compilation and execution..."
echo "SLURM_JOB_ID: $SLURM_JOB_ID"
echo "SLURM_NTASKS: $SLURM_NTASKS" 
echo "SLURM_NNODES: $SLURM_NNODES"

# Create the MPI C source file directly within the job script
cat > mpi_hello.c << 'EOF'
#include <mpi.h>
#include <stdio.h>
#include <unistd.h>
#include <stdlib.h>

int main(int argc, char** argv) {
    int provided;
    
    // Initialize the MPI environment with thread support query
    MPI_Init_thread(&argc, &argv, MPI_THREAD_SINGLE, &provided);
    
    // Add some debug output
    printf("MPI Init completed\n");
    fflush(stdout);

    // Get the number of processes
    int world_size;
    MPI_Comm_size(MPI_COMM_WORLD, &world_size);
    printf("World size: %d\n", world_size);
    fflush(stdout);

    // Get the rank of the process
    int world_rank;
    MPI_Comm_rank(MPI_COMM_WORLD, &world_rank);
    printf("Rank %d: Got rank\n", world_rank);
    fflush(stdout);

    // Get the name of the processor
    char processor_name[MPI_MAX_PROCESSOR_NAME];
    int name_len;
    MPI_Get_processor_name(processor_name, &name_len);

    // Print off a hello world message
    printf("Hello world from processor %s, rank %d out of %d processors\n",
           processor_name, world_rank, world_size);
    fflush(stdout);
    
    // Add a barrier to synchronize all processes
    printf("Rank %d: Before barrier\n", world_rank);
    fflush(stdout);
    MPI_Barrier(MPI_COMM_WORLD);
    printf("Rank %d: After barrier\n", world_rank);
    fflush(stdout);
    
    // Sleep for a bit to make sure the output is captured
    sleep(1);

    printf("Rank %d: Before finalize\n", world_rank);
    fflush(stdout);
    
    // Finalize the MPI environment.
    MPI_Finalize();
    
    printf("Rank %d: After finalize\n", world_rank);
    fflush(stdout);
    
    return 0;
}
EOF

# Compile the MPI program to shared location
echo "Compiling MPI program to shared directory..."
mpicc -o "$SHARED_DIR/mpi_hello" mpi_hello.c

# Check if compilation was successful
if [ $? -ne 0 ]; then
    echo "MPI program compilation failed"
    exit 1
fi

# Ensure executable permissions
chmod +x "$SHARED_DIR/mpi_hello"

echo "Compilation successful. Starting MPI execution..."

# Run the MPI program using srun with absolute path to the executable
timeout 120 srun --mpi=pmix "$SHARED_DIR/mpi_hello"

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

# Clean up temporary files
rm -f ./mpi_hello.c
