# HPC Cluster ISO Creation with Cubic

## Overview
This guide walks through creating a custom Ubuntu 22.04 ISO with the HPC stack pre-installed, ensuring consistency with the Vagrant-based deployment.

## Prerequisites
- Ubuntu host system with Cubic installed
- At least 8GB free disk space
- Internet connection for downloading packages during customization

## Step-by-Step Instructions

### 1. Launch Cubic
```bash
sudo cubic
```

### 2. Project Setup
- **Select Project Directory**: Choose this directory as the Cubic project directory
- **Import Original ISO**: Select the downloaded Ubuntu 22.04 ISO
- **Project Name**: Use "HPC-Cluster-Ubuntu-22.04"

### 3. Extract and Enter Chroot Environment
Cubic will extract the ISO filesystem. Once ready, you'll be in a chroot environment.

### 4. Install HPC Base System
In the chroot terminal, run the shared setup script:

```bash
# Copy the setup script to a temporary location
cp /cubic-workspace/setup-base.sh /tmp/
chmod +x /tmp/setup-base.sh

# Install the complete HPC stack (this may take 15-20 minutes)
echo "🏗️ Installing HPC base system..."
/tmp/setup-base.sh --clean-for-imaging

# Verify installation
echo "✅ Verifying installations..."
go version
apptainer --version
python3 -c "import numpy, scipy, matplotlib; print('Python packages OK')"

# Check if Slurm was installed
if [ -f "/opt/slurm/bin/sinfo" ]; then
    echo "✅ Slurm installed: $(/opt/slurm/bin/sinfo --version)"
else
    echo "⚠️ Slurm not installed (source not available)"
fi
```

### 5. Copy Additional Resources
```bash
# Copy all scripts and sample jobs
cp -r /cubic-workspace/scripts /tmp/
cp -r /cubic-workspace/sample-jobs /tmp/
cp -r /cubic-workspace/preseed /tmp/

# If Slurm source is available, you can also copy it
if [ -d "/cubic-workspace/slurm-src" ]; then
    echo "📦 Slurm source found, copying for potential later use..."
    cp -r /cubic-workspace/slurm-src /tmp/
fi

# Make scripts executable
chmod +x /tmp/scripts/*.sh
```

### 6. Create Installation Automation
```bash
# Create an auto-setup script for first boot
cat > /etc/rc.local << 'RCLOCAL_EOF'
#!/bin/bash
# Auto-configuration script for HPC cluster nodes

# Check if this is first boot
if [ ! -f /var/log/hpc-first-boot-complete ]; then
    echo "$(date): HPC first boot configuration starting..." >> /var/log/hpc-setup.log
    
    # Copy resources from installation media
    if [ -d /tmp/scripts ]; then
        cp -r /tmp/scripts /opt/hpc-scripts
        cp -r /tmp/sample-jobs /opt/hpc-sample-jobs
        chmod +x /opt/hpc-scripts/*.sh
    fi
    
    echo "$(date): HPC first boot configuration complete" >> /var/log/hpc-setup.log
    touch /var/log/hpc-first-boot-complete
fi

exit 0
RCLOCAL_EOF

chmod +x /etc/rc.local
systemctl enable rc-local
```

### 7. Final Cleanup
```bash
# Clean package cache and temporary files
apt-get clean
apt-get autoremove -y
rm -rf /var/lib/apt/lists/*
rm -rf /tmp/setup-base.sh
rm -rf /root/.cache

# Clear command history
history -c
history -w

# Exit chroot
exit
```

### 8. Customize Boot Menu (Optional)
In Cubic's boot menu customization:
- **Timeout**: Set to 10 seconds
- **Default Option**: "Install Ubuntu Server"
- **Custom Entries**: Add entries for automated installation

### 9. Generate the ISO
- Review the customization summary
- Generate the new ISO
- Save as "ubuntu-22.04-hpc-cluster.iso"

## Deployment Instructions

### Controller Node Installation
1. Boot from the custom ISO
2. Follow standard Ubuntu installation
3. After first boot, run:
```bash
sudo /opt/hpc-scripts/configure-node.sh controller
```

### Compute Node Installation
1. Boot from the custom ISO
2. Follow standard Ubuntu installation
3. After first boot, run:
```bash
sudo /opt/hpc-scripts/configure-node.sh compute 1  # For first compute node
sudo /opt/hpc-scripts/configure-node.sh compute 2  # For second compute node
# etc.
```

## Network Configuration
The scripts assume the following network layout:
- **Controller**: 192.168.1.10 (hpc-controller)
- **Compute Node 1**: 192.168.1.11 (hpc-compute01)
- **Compute Node 2**: 192.168.1.12 (hpc-compute02)
- **Compute Node 3**: 192.168.1.13 (hpc-compute03)

Adjust `/opt/hpc-scripts/configure-node.sh` if your network uses different IP ranges.

## Verification
After deployment, verify the cluster:

### On Controller:
```bash
source /etc/profile.d/slurm.sh
sinfo                    # Check cluster status
sbatch /opt/hpc-sample-jobs/hello_world.sh  # Submit test job
squeue                   # Monitor jobs
```

### On Compute Nodes:
```bash
systemctl status slurmd  # Check Slurm daemon
df -h /shared           # Verify shared storage
```

## Troubleshooting
- **Logs**: Check `/var/log/hpc-setup.log` for setup issues
- **Services**: Use `systemctl status` to check service status
- **Network**: Verify all nodes can ping each other
- **Munge**: Test with `munge -n | unmunge` on each node

## What's Included
- ✅ Complete HPC development stack (build tools, libraries)
- ✅ Go 1.21.5 programming environment
- ✅ Apptainer 1.3.4 for container workloads
- ✅ Python scientific stack (NumPy, SciPy, Matplotlib, etc.)
- ✅ Slurm workload manager (if source was available)
- ✅ Sample job scripts and configuration templates
- ✅ Automated node configuration scripts
