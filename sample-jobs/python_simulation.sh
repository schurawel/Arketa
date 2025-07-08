#!/bin/bash
#SBATCH --job-name=python_simulation
#SBATCH --output=python_simulation_%j.out
#SBATCH --error=python_simulation_%j.err
#SBATCH --time=00:10:00
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=2
#SBATCH --partition=compute

mkdir -p ~/job_outputs
cd ~/job_outputs

echo "Python Scientific Simulation Job"
echo "Job ID: $SLURM_JOB_ID"
echo "Node: $SLURM_JOB_NODELIST"
echo "CPUs allocated: $SLURM_CPUS_PER_TASK"
echo "Date: $(date)"

# Create a Python script for simulation
cat > simulation.py << 'EOF'
#!/usr/bin/env python3
"""
Monte Carlo Pi Estimation Simulation
This script estimates the value of π using Monte Carlo method
"""

import numpy as np
import matplotlib
matplotlib.use('Agg')  # Use non-interactive backend
import matplotlib.pyplot as plt
import time
import sys

def monte_carlo_pi(n_samples):
    """Estimate π using Monte Carlo method"""
    print(f"Starting Monte Carlo simulation with {n_samples:,} samples...")
    
    # Generate random points in unit square
    x = np.random.uniform(-1, 1, n_samples)
    y = np.random.uniform(-1, 1, n_samples)
    
    # Check if points are inside unit circle
    inside_circle = (x**2 + y**2) <= 1
    
    # Estimate π
    pi_estimate = 4 * np.sum(inside_circle) / n_samples
    
    return pi_estimate, x, y, inside_circle

def run_simulation():
    """Run the main simulation"""
    print("=== Monte Carlo Pi Estimation ===")
    print(f"Running on node: {os.environ.get('SLURMD_NODENAME', 'unknown')}")
    print(f"Job ID: {os.environ.get('SLURM_JOB_ID', 'unknown')}")
    
    # Different sample sizes to show convergence
    sample_sizes = [1000, 10000, 100000, 500000]
    results = []
    
    for n in sample_sizes:
        start_time = time.time()
        pi_est, x, y, inside = monte_carlo_pi(n)
        end_time = time.time()
        
        error = abs(pi_est - np.pi)
        results.append((n, pi_est, error, end_time - start_time))
        
        print(f"Samples: {n:8,} | π estimate: {pi_est:.6f} | Error: {error:.6f} | Time: {end_time - start_time:.3f}s")
    
    # Create visualization for the largest sample
    print("\nCreating visualization...")
    n_viz = 5000  # Smaller sample for visualization
    pi_est, x, y, inside = monte_carlo_pi(n_viz)
    
    plt.figure(figsize=(10, 8))
    plt.subplot(2, 2, 1)
    colors = ['red' if not inside_circle else 'blue' for inside_circle in inside]
    plt.scatter(x, y, c=colors, alpha=0.6, s=1)
    plt.xlim(-1, 1)
    plt.ylim(-1, 1)
    plt.gca().set_aspect('equal')
    plt.title(f'Monte Carlo Simulation\nπ ≈ {pi_est:.4f} (n={n_viz:,})')
    plt.xlabel('x')
    plt.ylabel('y')
    
    # Convergence plot
    plt.subplot(2, 2, 2)
    samples, estimates, errors, times = zip(*results)
    plt.semilogx(samples, estimates, 'bo-', label='Estimates')
    plt.axhline(y=np.pi, color='r', linestyle='--', label='True π')
    plt.xlabel('Number of Samples')
    plt.ylabel('π Estimate')
    plt.title('Convergence to π')
    plt.legend()
    plt.grid(True)
    
    # Error plot
    plt.subplot(2, 2, 3)
    plt.loglog(samples, errors, 'ro-')
    plt.xlabel('Number of Samples')
    plt.ylabel('Absolute Error')
    plt.title('Error vs Sample Size')
    plt.grid(True)
    
    # Timing plot
    plt.subplot(2, 2, 4)
    plt.loglog(samples, times, 'go-')
    plt.xlabel('Number of Samples')
    plt.ylabel('Computation Time (s)')
    plt.title('Scaling Performance')
    plt.grid(True)
    
    plt.tight_layout()
    output_file = f'monte_carlo_pi_{os.environ.get("SLURM_JOB_ID", "test")}.png'
    plt.savefig(output_file, dpi=150, bbox_inches='tight')
    print(f"Plot saved as: {output_file}")
    
    # Summary
    print("\n=== Simulation Summary ===")
    print(f"Best estimate: {results[-1][1]:.6f}")
    print(f"True value:    {np.pi:.6f}")
    print(f"Final error:   {results[-1][2]:.6f}")
    print(f"Total samples: {results[-1][0]:,}")

if __name__ == "__main__":
    import os
    run_simulation()
    print("\nSimulation completed successfully!")
EOF

echo "Running Python simulation..."
python3 simulation.py

echo "=== Simulation Results ==="
ls -la *.png 2>/dev/null || echo "No plots generated"
echo "Job completed on $(date)"
