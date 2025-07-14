#!/bin/bash
# Slurm Compute Node Setup Script

set -e

NODE_ID=$1

echo "Setting up Slurm Compute Node ${NODE_ID}..."

# Add host entries (moved from Vagrantfile)
grep -q "slurm-controller" /etc/hosts || echo "192.168.7.10 slurm-controller controller" >> /etc/hosts
grep -q "node1" /etc/hosts || echo "192.168.7.11 node1" >> /etc/hosts
grep -q "node2" /etc/hosts || echo "192.168.7.12 node2" >> /etc/hosts

# Set hostname
hostnamectl set-hostname node${NODE_ID}

# Install NFS client and setup shared directory (moved from Vagrantfile)
echo "Installing NFS client and setting up shared directory..."
apt-get update
apt-get install -y nfs-common

# Mount shared directory and setup fstab
mkdir -p /shared
# Add mount to fstab for persistence if not already there
grep -q "slurm-controller:/shared" /etc/fstab || echo "slurm-controller:/shared /shared nfs defaults 0 0" >> /etc/fstab

# Attempt to mount the shared directory
echo "Mounting controller:/shared to /shared..."
mount -t nfs slurm-controller:/shared /shared || echo "⚠️ NFS mount failed, will try later"

# Ensure proper permissions on the shared directory
chmod 777 /shared 2>/dev/null || true

# Ensure SSH service is running and ready
echo "Ensuring SSH service is ready..."
systemctl enable ssh
systemctl start ssh
systemctl status ssh --no-pager || true

# Wait a moment for network to be fully ready
sleep 10

# Source the Slurm environment (should be available from base setup)
# Also ensure environment is available for all shell types
if ! grep -q "/opt/slurm/bin" /etc/environment; then
    sed -i 's|PATH="\(.*\)"|PATH="/opt/slurm/bin:/opt/slurm/sbin:\1"|' /etc/environment
fi

# Add to /etc/bash.bashrc for non-login shells (SSH sessions)
if ! grep -q "opt/slurm" /etc/bash.bashrc; then
    echo '' >> /etc/bash.bashrc
    echo '# Slurm environment' >> /etc/bash.bashrc
    echo 'export PATH="/opt/slurm/bin:/opt/slurm/sbin:$PATH"' >> /etc/bash.bashrc
    echo 'export LD_LIBRARY_PATH="/opt/slurm/lib:$LD_LIBRARY_PATH"' >> /etc/bash.bashrc
fi

if [ -f /etc/profile.d/slurm.sh ]; then
    source /etc/profile.d/slurm.sh
else
    # Fallback environment setup
    export PATH="/opt/slurm/bin:/opt/slurm/sbin:$PATH"
    export LD_LIBRARY_PATH="/opt/slurm/lib:$LD_LIBRARY_PATH"
fi

# Wait for controller to be ready and shared directory to be available
echo "Waiting for controller to be ready..."

# Retry mounting the NFS share with backoff
max_attempts=30
attempt=1
while [ $attempt -le $max_attempts ]; do
    echo "Attempt $attempt/$max_attempts: Trying to mount NFS share..."
    if mount -a 2>/dev/null && [ -f /shared/munge.key ]; then
        echo "Successfully mounted NFS share and found munge.key"
        break
    fi
    
    if [ $attempt -eq $max_attempts ]; then
        echo "ERROR: Failed to mount NFS share after $max_attempts attempts"
        echo "Checking NFS status on controller..."
        ping -c 3 slurm-controller || true
        showmount -e slurm-controller || true
        exit 1
    fi
    
    echo "NFS mount failed, waiting 10 seconds before retry..."
    sleep 10
    attempt=$((attempt + 1))
done

# Setup Munge authentication with shared key
cp /shared/munge.key /etc/munge/munge.key
chown munge:munge /etc/munge/munge.key
chmod 400 /etc/munge/munge.key
systemctl enable munge
systemctl start munge

# Test munge authentication
munge -n | unmunge

# Copy configuration from controller
while [ ! -f /shared/slurm.conf ]; do
    echo "Waiting for slurm.conf from controller..."
    sleep 5
done

cp /shared/slurm.conf /etc/slurm/

# Copy cgroup.conf from controller
while [ ! -f /shared/cgroup.conf ]; do
    echo "Waiting for cgroup.conf from controller..."
    sleep 5
done

cp /shared/cgroup.conf /etc/slurm/

# Ensure proper ownership and permissions (already set in base, but refresh for safety)
mkdir -p /run/slurm /var/log/slurm /var/spool/slurmd
chown slurm:slurm /run/slurm /var/log/slurm /var/spool/slurmd
chmod 755 /run/slurm /var/log/slurm /var/spool/slurmd
rm -f /run/slurm/slurmd.pid



cat > /etc/systemd/system/slurmd.service << 'EOF'
[Unit]
Description=Slurm node daemon
After=network.target munge.service
Requires=munge.service

[Service]
Type=forking
EnvironmentFile=-/etc/default/slurmd
ExecStartPre=/bin/mkdir -p /run/slurm
ExecStartPre=/bin/chown slurm:slurm /run/slurm
ExecStartPre=/bin/chmod 755 /run/slurm
ExecStart=/opt/slurm/sbin/slurmd -f /etc/slurm/slurm.conf -L /var/log/slurm/slurmd.log -c /etc/slurm/cgroup.conf -M /run/slurm
ExecReload=/bin/kill -HUP $MAINPID
PIDFile=/run/slurm/slurmd.pid
KillMode=process
LimitNOFILE=131072
LimitMEMLOCK=infinity
LimitSTACK=infinity
User=root
Group=root
Delegate=yes

[Install]
WantedBy=multi-user.target
EOF

# Enable and start slurmd service
systemctl daemon-reload
systemctl enable slurmd
systemctl start slurmd

echo "Starting slurmd service..."
if ! systemctl start slurmd; then
    echo "ERROR: Failed to start slurmd service"
    echo "=== Service status ==="
    systemctl status slurmd --no-pager -l || true
    echo "=== Journal logs ==="
    journalctl -xeu slurmd.service --no-pager --lines=30 || true
    echo "=== Slurm logs ==="
    tail -50 /var/log/slurm/slurmd.log 2>/dev/null || echo "No slurmd.log found"
    echo "=== Testing manual slurmd run ==="
    timeout 10 /opt/slurm/sbin/slurmd -D -vvv || true
    exit 1
fi

# Add the controller to known hosts for passwordless SSH
if [ -f /shared/ssh/id_rsa.pub ]; then
    mkdir -p ~/.ssh
    cat /shared/ssh/id_rsa.pub >> ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
fi

# Ensure proper NFS server configuration in exports file
if [ -f /etc/exports ]; then
    sed -i 's/192.168.121.0\/24/192.168.7.0\/24/g' /etc/exports
    exportfs -ra 2>/dev/null || true
fi

echo "Slurm Compute Node ${NODE_ID} setup completed!"
