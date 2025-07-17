# Slurm Configuration Files

This directory contains the Slurm configuration files that are used across the cluster.

## Files

- **`slurm.conf`** - Main Slurm configuration file
- **`cgroup.conf`** - Cgroups configuration for resource management
- **`munge.key`** - Shared authentication key for the cluster (auto-generated)

## How it works

1. **Munge Key Generation**: The `qemu-cluster-build.sh` script automatically generates a shared munge key (`munge.key`) in this directory during the build process.

2. **Controller Setup**: The `setup-controller.sh` script copies these configuration files from this directory to `/etc/slurm/` on the controller node and also places them in the shared directory.

3. **Compute Node Setup**: The `setup-compute.sh` script automatically copies the configuration files from the controller using `scp` (primary method) or falls back to the NFS shared directory.

4. **Manual Editing**: You can edit these files directly in this directory. After making changes:
   - Re-run the controller setup to apply changes to the controller
   - The compute nodes will automatically get the updated configs via scp during their setup
   - For existing running nodes, you can use the manual sync option in `qemu-cluster-build.sh`

## Key Configuration Points

### slurm.conf
- **ClusterName**: Set to "vagrant-cluster"
- **Node Definitions**: Currently configured for controller + 2 compute nodes
- **Authentication**: Uses Munge
- **Process Tracking**: Uses cgroups v2
- **Scheduling**: Backfill scheduler with cons_tres selection

### cgroup.conf
- **Plugin**: Uses cgroup/v2 for modern cgroup support
- **Constraints**: Enables CPU cores, RAM, and device constraints
- **Mount Point**: Uses `/sys/fs/cgroup`

### munge.key
- **Purpose**: Provides shared authentication across all cluster nodes
- **Generation**: Automatically created during cluster build process
- **Security**: 1024 bytes of random data, permissions set to 400 (read-only for owner)
- **Distribution**: Copied to all nodes during setup for consistent authentication

## Making Changes

1. Edit the configuration files in this directory
2. If the controller is already set up, copy the changes:
   ```bash
   # Copy updated config to controller
   sudo cp scripts/configs/slurm.conf /etc/slurm/
   sudo cp scripts/configs/cgroup.conf /etc/slurm/
   
   # Restart services to pick up changes
   sudo systemctl restart slurmctld
   ```
3. For compute nodes, they will automatically get updated configs during setup, or you can use the manual sync function in the cluster build script

## Automation Benefits

- **No Manual Sync**: Configuration files are automatically copied during setup
- **Centralized Management**: Edit files in one location
- **Fallback Support**: scp is tried first, with NFS as fallback
- **Linear Mode Support**: Works in both regular and linear setup modes

## Previous Manual Process (Now Automated)

Previously, you had to manually sync configuration files between nodes. This is now handled automatically by:
- `setup-controller.sh` - Copies configs from this directory to controller
- `setup-compute.sh` - Copies configs from controller via scp
- Fallback to NFS shared directory if scp fails
