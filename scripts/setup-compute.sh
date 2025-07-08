#!/bin/bash
# Slurm Compute Node Setup Script

set -e

NODE_ID=$1

echo "Setting up Slurm Compute Node ${NODE_ID}..."

# Verify base system is available
if [ ! -f /etc/hpc-base-version ]; then
    echo "ERROR: HPC base system not found. Run setup-base.sh first."
    exit 1
fi

# Source the Slurm environment (should be available from base setup)
source /etc/profile.d/slurm.sh

# Wait for controller to be ready and shared directory to be available
echo "Waiting for controller to be ready..."
while [ ! -f /shared/munge.key ]; do
    sleep 5
    mount -a 2>/dev/null || true
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
mkdir -p /run/slurm
chown root:root /run/slurm
chmod 777 /run/slurm
rm -f /run/slurm/slurmd.pid
chown -R slurm:slurm /var/log/slurm
chown -R slurm:slurm /var/spool/slurmd



cat > /etc/systemd/system/slurmd.service << 'EOF'
[Unit]
Description=Slurm node daemon
After=network.target munge.service
Requires=munge.service

[Service]
Type=forking
EnvironmentFile=-/etc/default/slurmd
ExecStartPre=/bin/mkdir -p /run/slurm
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

echo "Slurm Compute Node ${NODE_ID} setup completed!"
