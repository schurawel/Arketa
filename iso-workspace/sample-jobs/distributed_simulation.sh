#!/bin/bash
#SBATCH --job-name=multi_container
#SBATCH --output=multi_container_%j.out
#SBATCH --error=multi_container_%j.err
#SBATCH --time=00:25:00
#SBATCH --nodes=2
#SBATCH --ntasks=4
#SBATCH --cpus-per-task=1
#SBATCH --partition=compute

echo "Multi-Node Container Simulation"
echo "Job ID: $SLURM_JOB_ID"
echo "Node list: $SLURM_JOB_NODELIST"
echo "Number of tasks: $SLURM_NTASKS"
echo "Date: $(date)"

# Create a distributed simulation script
cat > distributed_sim.py << 'EOF'
#!/usr/bin/env python3
"""
Distributed Simulation using Python
Simulates a distributed computation across multiple nodes
"""

import os
import sys
import time
import numpy as np
import json
from datetime import datetime

def get_task_info():
    """Get Slurm task information"""
    return {
        'job_id': os.environ.get('SLURM_JOB_ID', 'unknown'),
        'task_id': int(os.environ.get('SLURM_PROCID', '0')),
        'local_id': int(os.environ.get('SLURM_LOCALID', '0')),
        'node_name': os.environ.get('SLURMD_NODENAME', 'unknown'),
        'num_tasks': int(os.environ.get('SLURM_NTASKS', '1')),
        'cpus_per_task': int(os.environ.get('SLURM_CPUS_PER_TASK', '1'))
    }

def distributed_pi_calculation(task_id, num_tasks, samples_per_task):
    """Calculate pi using distributed Monte Carlo method"""
    
    # Set different random seed for each task
    np.random.seed(42 + task_id)
    
    print(f"Task {task_id}: Starting calculation with {samples_per_task:,} samples")
    
    # Generate random points
    x = np.random.uniform(-1, 1, samples_per_task)
    y = np.random.uniform(-1, 1, samples_per_task)
    
    # Count points inside circle
    inside_circle = np.sum((x**2 + y**2) <= 1)
    
    # Partial pi estimate
    partial_pi = 4.0 * inside_circle / samples_per_task
    
    return inside_circle, samples_per_task, partial_pi

def matrix_multiplication_task(task_id, matrix_size):
    """Distributed matrix operations"""
    print(f"Task {task_id}: Performing matrix operations (size {matrix_size}x{matrix_size})")
    
    # Create task-specific matrices
    np.random.seed(100 + task_id)
    A = np.random.randn(matrix_size, matrix_size)
    B = np.random.randn(matrix_size, matrix_size)
    
    start_time = time.time()
    
    # Matrix multiplication
    C = np.dot(A, B)
    
    # Additional operations
    eigenvals = np.linalg.eigvals(C)
    det = np.linalg.det(C)
    trace = np.trace(C)
    
    end_time = time.time()
    
    return {
        'computation_time': end_time - start_time,
        'matrix_size': matrix_size,
        'determinant': float(det),
        'trace': float(trace),
        'max_eigenval': float(np.max(np.real(eigenvals))),
        'min_eigenval': float(np.min(np.real(eigenvals)))
    }

def main():
    """Main distributed simulation"""
    info = get_task_info()
    
    print("=== Distributed Container Simulation ===")
    print(f"Task {info['task_id']} of {info['num_tasks']} on {info['node_name']}")
    print(f"Local task ID: {info['local_id']}")
    print(f"CPUs per task: {info['cpus_per_task']}")
    print(f"Job ID: {info['job_id']}")
    
    # Simulation parameters
    total_samples = 1000000
    samples_per_task = total_samples // info['num_tasks']
    matrix_size = 200 + info['task_id'] * 50  # Different sizes per task
    
    results = {
        'task_info': info,
        'timestamp': datetime.now().isoformat(),
        'simulations': {}
    }
    
    # Monte Carlo Pi calculation
    print(f"\n=== Monte Carlo Pi Estimation (Task {info['task_id']}) ===")
    start_time = time.time()
    inside, samples, partial_pi = distributed_pi_calculation(
        info['task_id'], info['num_tasks'], samples_per_task
    )
    mc_time = time.time() - start_time
    
    results['simulations']['monte_carlo'] = {
        'inside_circle': int(inside),
        'total_samples': int(samples),
        'partial_pi_estimate': float(partial_pi),
        'computation_time': mc_time
    }
    
    print(f"Task {info['task_id']}: {inside:,} points inside circle out of {samples:,}")
    print(f"Task {info['task_id']}: Partial π estimate = {partial_pi:.6f}")
    print(f"Task {info['task_id']}: Computation time = {mc_time:.3f}s")
    
    # Matrix operations
    print(f"\n=== Matrix Operations (Task {info['task_id']}) ===")
    matrix_results = matrix_multiplication_task(info['task_id'], matrix_size)
    results['simulations']['matrix'] = matrix_results
    
    print(f"Task {info['task_id']}: Matrix {matrix_size}x{matrix_size} operations completed")
    print(f"Task {info['task_id']}: Computation time = {matrix_results['computation_time']:.3f}s")
    print(f"Task {info['task_id']}: Determinant = {matrix_results['determinant']:.2e}")
    
    # Save task results
    output_file = f"task_{info['task_id']}_results.json"
    with open(output_file, 'w') as f:
        json.dump(results, f, indent=2)
    
    print(f"Task {info['task_id']}: Results saved to {output_file}")
    
    # Simulation barrier (simple file-based synchronization)
    barrier_file = f"task_{info['task_id']}_done"
    with open(barrier_file, 'w') as f:
        f.write(f"Task {info['task_id']} completed at {datetime.now()}\n")
    
    print(f"Task {info['task_id']}: Simulation completed!")

if __name__ == "__main__":
    main()
EOF

# Run the distributed simulation
echo "=== Starting Distributed Simulation ==="
srun python3 distributed_sim.py

# Wait a bit for all tasks to complete
sleep 5

# Collect and summarize results (run on first task only)
if [ "$SLURM_PROCID" = "0" ]; then
    echo ""
    echo "=== Collecting Results (Task 0) ==="
    
    python3 << 'EOF'
import json
import glob
import numpy as np

print("=== Distributed Simulation Summary ===")

# Find all result files
result_files = glob.glob("task_*_results.json")
result_files.sort()

if not result_files:
    print("No result files found!")
    exit(1)

print(f"Found {len(result_files)} result files")

# Aggregate Monte Carlo results
total_inside = 0
total_samples = 0
task_times = []
matrix_times = []
pi_estimates = []

for file in result_files:
    with open(file, 'r') as f:
        data = json.load(f)
    
    task_id = data['task_info']['task_id']
    node = data['task_info']['node_name']
    
    # Monte Carlo data
    mc_data = data['simulations']['monte_carlo']
    total_inside += mc_data['inside_circle']
    total_samples += mc_data['total_samples']
    task_times.append(mc_data['computation_time'])
    pi_estimates.append(mc_data['partial_pi_estimate'])
    
    # Matrix data
    matrix_data = data['simulations']['matrix']
    matrix_times.append(matrix_data['computation_time'])
    
    print(f"Task {task_id} on {node}:")
    print(f"  Monte Carlo: {mc_data['partial_pi_estimate']:.6f} in {mc_data['computation_time']:.3f}s")
    print(f"  Matrix {matrix_data['matrix_size']}x{matrix_data['matrix_size']}: {matrix_data['computation_time']:.3f}s")

# Final distributed pi estimate
final_pi = 4.0 * total_inside / total_samples

print(f"\n=== Final Results ===")
print(f"Distributed π estimate: {final_pi:.6f}")
print(f"True π value: {np.pi:.6f}")
print(f"Error: {abs(final_pi - np.pi):.6f}")
print(f"Total samples: {total_samples:,}")
print(f"Average task time: {np.mean(task_times):.3f}s")
print(f"Total matrix computation time: {sum(matrix_times):.3f}s")
print(f"Speedup efficiency: {(max(task_times) / np.mean(task_times)):.2f}")

print("\nDistributed simulation completed successfully!")
EOF

    echo ""
    echo "=== Cleanup ==="
    ls -la task_*.json task_*_done
    
fi

echo "Multi-container job completed on $(date)"
