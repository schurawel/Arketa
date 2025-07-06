#!/bin/bash
# Slurm Compute Node Setup Script

set -e

NODE_ID=$1

echo "Setting up Slurm Compute Node ${NODE_ID}..."

# Configure time synchronization
systemctl enable chrony
systemctl start chrony

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

# Install Python and scientific computing tools (if not using base box)
if [ ! -f /etc/slurm-base-version ] && [ ! -f /etc/hpc-base-version ]; then
    echo "Installing Python and scientific computing packages..."
    apt-get install -y python3 python3-pip python3-venv python3-dev
    pip3 install numpy scipy matplotlib pandas seaborn scikit-learn

    # Install additional tools for simulation work
    apt-get install -y git htop tree tmux screen
else
    echo "Using base box - Python and tools already installed"
fi

# Build and install Slurm
# Check if Slurm is already installed
if [ -f "/opt/slurm/bin/sinfo" ]; then
    echo "Slurm already installed, skipping build..."
else
    echo "Building Slurm from source..."
    # Copy source to writable location and build as vagrant user
    sudo -u vagrant cp -r /home/vagrant/slurm-src /tmp/slurm-build
    cd /tmp/slurm-build

    echo "Building Slurm without MySQL on compute node..."

    # Configure and build Slurm as vagrant user (without MySQL for compute nodes)
    sudo -u vagrant ./configure --prefix=/opt/slurm --sysconfdir=/etc/slurm \
        --enable-pam --with-pam_dir=/lib/x86_64-linux-gnu/security/ \
        --without-shared-libslurm

    sudo -u vagrant make -j$(nproc)

    make install

    # Create necessary directories
    mkdir -p /etc/slurm
    mkdir -p /var/spool/slurmd
    mkdir -p /var/log/slurm
    mkdir -p /opt/slurm/var/run

    # Set ownership
    chown -R slurm:slurm /var/spool/slurmd
    chown -R slurm:slurm /var/log/slurm
    chown -R slurm:slurm /opt/slurm/var/run

    # Add Slurm binaries to PATH
    echo 'export PATH="/opt/slurm/bin:/opt/slurm/sbin:$PATH"' >> /etc/profile.d/slurm.sh
    echo 'export LD_LIBRARY_PATH="/opt/slurm/lib:$LD_LIBRARY_PATH"' >> /etc/profile.d/slurm.sh
    chmod +x /etc/profile.d/slurm.sh

    echo "Slurm build completed!"
fi

source /etc/profile.d/slurm.sh

# Copy configuration from controller
while [ ! -f /shared/slurm.conf ]; do
    echo "Waiting for slurm.conf from controller..."
    sleep 5
done

cp /shared/slurm.conf /etc/slurm/

# Create systemd service file for slurmd
cat > /etc/systemd/system/slurmd.service << 'EOF'
[Unit]
Description=Slurm node daemon
After=network.target munge.service
Requires=munge.service

[Service]
Type=forking
EnvironmentFile=-/etc/default/slurmd
ExecStart=/opt/slurm/sbin/slurmd
ExecReload=/bin/kill -HUP $MAINPID
PIDFile=/opt/slurm/var/run/slurmd.pid
KillMode=process
LimitNOFILE=131072
LimitMEMLOCK=infinity
LimitSTACK=infinity
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF

# Configure cgroups for Slurm
cat > /etc/slurm/cgroup.conf << 'EOF'
CgroupMountpoint="/sys/fs/cgroup"
ConstrainCores=yes
ConstrainRAMSpace=yes
ConstrainSwapSpace=no
ConstrainDevices=yes
EOF

# Remove any problematic TaskAffinity lines that might exist
sed -i '/TaskAffinity/d' /etc/slurm/cgroup.conf 2>/dev/null || true

# Enable and start slurmd service
systemctl daemon-reload
systemctl enable slurmd
systemctl start slurmd

echo "Slurm Compute Node ${NODE_ID} setup completed!"
echo "You can check the status with: systemctl status slurmd"
