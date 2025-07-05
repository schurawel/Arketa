#!/bin/bash
# Quick test script to verify the controller is working

echo "🔍 Testing Controller Setup..."

# Test 1: Check if Slurm is installed
echo "Testing Slurm installation..."
./vagrant-wrapper.sh ssh controller -c "source /etc/profile.d/slurm.sh && which sinfo" 2>/dev/null
if [ $? -eq 0 ]; then
    echo "✅ Slurm commands available"
else
    echo "❌ Slurm commands not found"
fi

# Test 2: Check if services are running
echo "Testing Slurm services..."
./vagrant-wrapper.sh ssh controller -c "systemctl is-active slurmctld" 2>/dev/null
if [ $? -eq 0 ]; then
    echo "✅ slurmctld service running"
else
    echo "❌ slurmctld service not running"
fi

# Test 3: Check if we can submit a simple job
echo "Testing job submission..."
./vagrant-wrapper.sh ssh controller -c "source /etc/profile.d/slurm.sh && echo -e '#!/bin/bash\necho Hello from Slurm' | sbatch" 2>/dev/null
if [ $? -eq 0 ]; then
    echo "✅ Job submission works"
else
    echo "❌ Job submission failed"
fi

echo ""
echo "🏁 Controller test completed!"
echo "If all tests pass, run: make cluster"
echo "Then run: make test"
