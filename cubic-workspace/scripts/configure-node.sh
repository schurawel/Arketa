#!/bin/bash
# Configure HPC node after installation
# This script leverages the existing setup-controller.sh and setup-compute.sh scripts

set -e

NODE_TYPE="$1"  # controller or compute
NODE_ID="$2"    # node number (for compute nodes)

if [ -z "$NODE_TYPE" ]; then
    echo "Usage: $0 <controller|compute> [node_id]"
    exit 1
fi

echo "🚀 Configuring HPC ${NODE_TYPE} node ${NODE_ID:-}"

# Set up hosts file for cluster networking (bare metal uses different IP range)
cat > /etc/hosts << 'HOSTS_EOF'
127.0.0.1 localhost
192.168.1.10 hpc-controller controller
192.168.1.11 hpc-compute01 node1
192.168.1.12 hpc-compute02 node2
192.168.1.13 hpc-compute03 node3

# IPv6 entries
::1 ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
HOSTS_EOF

# Configure hostname
if [ "$NODE_TYPE" = "controller" ]; then
    hostnamectl set-hostname hpc-controller
    
    # Create shared directory
    mkdir -p /shared
    chown slurm:slurm /shared 2>/dev/null || true
    chmod 755 /shared
    
    # Configure NFS export for shared directory
    echo "/shared 192.168.1.0/24(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports
    systemctl enable nfs-kernel-server
    systemctl start nfs-kernel-server
    exportfs -a
    
    # Run controller setup using existing script
    echo "🔧 Running controller-specific setup..."
    if [ -f "/tmp/scripts/setup-controller.sh" ]; then
        bash /tmp/scripts/setup-controller.sh
    else
        echo "⚠️ Controller setup script not found, manual configuration needed"
    fi
    
elif [ "$NODE_TYPE" = "compute" ]; then
    if [ -z "$NODE_ID" ]; then
        echo "❌ Node ID required for compute nodes"
        exit 1
    fi
    
    hostnamectl set-hostname "hpc-compute$(printf "%02d" "$NODE_ID")"
    
    # Create shared directory mount point
    mkdir -p /shared
    echo "hpc-controller:/shared /shared nfs defaults 0 0" >> /etc/fstab
    
    # Run compute setup using existing script
    echo "🔧 Running compute node setup..."
    if [ -f "/tmp/scripts/setup-compute.sh" ]; then
        bash /tmp/scripts/setup-compute.sh "$NODE_ID"
    else
        echo "⚠️ Compute setup script not found, manual configuration needed"
    fi
else
    echo "❌ Invalid node type: $NODE_TYPE"
    echo "Valid types: controller, compute"
    exit 1
fi

echo "✅ Node configuration complete for ${NODE_TYPE} ${NODE_ID:-}"
echo "📋 Next steps:"
if [ "$NODE_TYPE" = "controller" ]; then
    echo "  • Check cluster status: sinfo"
    echo "  • Submit test job: sbatch /tmp/sample-jobs/hello_world.sh"
else
    echo "  • Check node registration on controller: sinfo"
    echo "  • Verify shared storage: ls -la /shared"
fi
