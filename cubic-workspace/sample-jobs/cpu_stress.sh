#!/bin/bash
#SBATCH --job-name=cpu_stress_test
#SBATCH --output=cpu_stress_%j.out
#SBATCH --error=cpu_stress_%j.err
#SBATCH --time=00:15:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --partition=compute

echo "CPU Stress Test Job"
echo "Job ID: $SLURM_JOB_ID"
echo "Node: $SLURM_JOB_NODELIST"
echo "CPUs allocated: $SLURM_CPUS_PER_TASK"

# Function to perform CPU-intensive calculation
cpu_stress() {
    local thread_id=$1
    local duration=$2
    echo "Thread $thread_id starting CPU stress test for $duration seconds"
    
    local end_time=$(($(date +%s) + duration))
    local count=0
    
    while [ $(date +%s) -lt $end_time ]; do
        # Perform some CPU-intensive operations
        result=$(echo "scale=10; sqrt($count * 3.14159265359)" | bc -l)
        count=$((count + 1))
        
        # Print progress every 10000 iterations
        if [ $((count % 10000)) -eq 0 ]; then
            echo "Thread $thread_id: Iteration $count, current result: $result"
        fi
    done
    
    echo "Thread $thread_id completed $count iterations"
}

# Install bc if not available
which bc > /dev/null || {
    echo "Installing bc calculator..."
    sudo apt-get update && sudo apt-get install -y bc
}

echo "Starting CPU stress test with $SLURM_CPUS_PER_TASK threads..."

# Start background processes for each CPU
pids=()
for ((i=1; i<=SLURM_CPUS_PER_TASK; i++)); do
    cpu_stress $i 60 &  # Run for 60 seconds
    pids+=($!)
done

# Wait for all background processes to complete
echo "Waiting for all threads to complete..."
for pid in "${pids[@]}"; do
    wait $pid
done

echo "CPU stress test completed!"

# Show final system status
echo "=== Final System Status ==="
echo "Load average:"
uptime
echo "Memory usage:"
free -h
