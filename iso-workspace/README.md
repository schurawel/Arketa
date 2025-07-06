# HPC Cluster ISO Documentation

## Overview
This custom Ubuntu 22.04 ISO includes a complete HPC stack pre-installed for automated bare metal deployment.

## What's Included
- ✅ Complete HPC development stack (build tools, libraries)
- ✅ Go 1.21.5 programming environment  
- ✅ Apptainer 1.3.4 for container workloads
- ✅ Python scientific stack (NumPy, SciPy, Matplotlib, etc.)
- ✅ Slurm workload manager (if source was available)
- ✅ Sample job scripts and configuration templates
- ✅ Automated node configuration scripts

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
