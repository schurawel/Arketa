#!/bin/bash
#SBATCH --job-name=apptainer_test
#SBATCH --output=apptainer_test_%j.out
#SBATCH --error=apptainer_test_%j.err
#SBATCH --time=00:15:00
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=2
#SBATCH --partition=compute

echo "Apptainer Container Job"
echo "Job ID: $SLURM_JOB_ID"
echo "Node: $SLURM_JOB_NODELIST"
echo "CPUs allocated: $SLURM_CPUS_PER_TASK"
echo "Date: $(date)"

# Check if Apptainer is available
echo "=== Checking Apptainer Installation ==="
which apptainer || echo "Apptainer not found in PATH"
apptainer --version || echo "Cannot get Apptainer version"

# Create a simple Apptainer definition file
echo "=== Creating Apptainer Definition ==="
cat > ubuntu_python.def << 'EOF'
Bootstrap: library
From: ubuntu:20.04

%post
    apt-get update
    apt-get install -y python3 python3-pip
    pip3 install numpy matplotlib scipy pandas

%runscript
    echo "Running Python in container..."
    python3 "$@"

%labels
    Author Your_Name
    Version v1.0

%help
    This container provides Python 3 with scientific libraries
    Usage: apptainer run ubuntu_python.sif script.py
EOF

echo "=== Building Container (if not exists) ==="
CONTAINER_NAME="ubuntu_python_${SLURM_JOB_ID}.sif"

# For demonstration, we'll use a simple approach compatible with Ubuntu 18.04
# Instead of building containers, we'll use exec to run commands
echo "=== Testing Apptainer Functionality ==="

# Test basic apptainer functionality with a simple container
CONTAINER_NAME="ubuntu_test_${SLURM_JOB_ID}.sif"

# Try to pull a simple container (fallback to direct execution if fails)
echo "Attempting to pull a lightweight container..."
if apptainer pull --name $CONTAINER_NAME docker://alpine:latest 2>/dev/null; then
    echo "Successfully pulled Alpine container"
    CONTAINER_MODE=true
    
    echo "=== Running Commands in Container ==="
    apptainer exec $CONTAINER_NAME /bin/sh -c "echo 'Hello from Alpine container!'; uname -a; df -h"
    
    echo "=== Container Information ==="
    apptainer inspect $CONTAINER_NAME 2>/dev/null || echo "Container inspect not available"
    
else
    echo "Container pull failed or not available, testing Apptainer installation..."
    CONTAINER_MODE=false
fi

# Create a Python script to run in container
cat > container_script.py << 'EOF'
#!/usr/bin/env python3
import sys
import os

print("=== Container Environment Test ===")
print(f"Python version: {sys.version}")
print(f"Running in: {os.getcwd()}")
print(f"Hostname: {os.uname().nodename}")
print(f"Platform: {os.uname().system} {os.uname().machine}")

# Simple computation
print("\n=== Running Computation ===")
try:
    import math
    result = sum(math.sqrt(i) for i in range(1, 10000))
    print(f"Sum of square roots 1-9999: {result:.2f}")
    
    # Test file I/O
    with open('/tmp/container_test.txt', 'w') as f:
        f.write(f"Container job completed successfully\nResult: {result}\n")
    print("Created test file: /tmp/container_test.txt")
    
except Exception as e:
    print(f"Error in computation: {e}")

print("Container script completed!")
EOF

if [ "$CONTAINER_MODE" = "true" ]; then
    echo "=== Running Python Script in Container ==="
    # Create a simple Python script that works in Alpine
    cat > simple_script.py << 'EOF'
import sys
import os
print("=== Container Python Test ===")
print(f"Python version: {sys.version}")
print(f"Working directory: {os.getcwd()}")
print(f"Environment: Container")

# Simple computation
result = sum(i**2 for i in range(1, 1000))
print(f"Sum of squares 1-999: {result}")
print("Container Python test completed!")
EOF
    
    # Install Python in Alpine and run script
    apptainer exec $CONTAINER_NAME /bin/sh -c "
        apk update && apk add python3 2>/dev/null || echo 'Python install failed, trying basic commands';
        python3 simple_script.py 2>/dev/null || echo 'Python script failed, but container exec works'
    "
    
    echo "=== Cleanup ==="
    ls -la $CONTAINER_NAME
    rm -f $CONTAINER_NAME  # Clean up container file
else
    echo "=== Running Script Directly (Container unavailable) ==="
    echo "Testing Apptainer installation status..."
    apptainer --help | head -5 || echo "Apptainer help not available"
    python3 container_script.py
fi

echo "=== Final System Check ==="
echo "Available space:"
df -h /tmp
echo "Memory usage:"
free -h

echo "Apptainer job completed on $(date)"
