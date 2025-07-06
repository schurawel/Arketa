#!/bin/bash
# Slurm Controller Setup Script

set -e

echo "Setting up Slurm Controller Node..."

# Configure time synchronization
systemctl enable chrony
systemctl start chrony

# Setup Munge authentication
systemctl enable munge
dd if=/dev/urandom bs=1 count=1024 > /etc/munge/munge.key
chown munge:munge /etc/munge/munge.key
chmod 400 /etc/munge/munge.key
systemctl start munge

# Copy munge key to shared directory for compute nodes
cp /etc/munge/munge.key /shared/
chown slurm:slurm /shared/munge.key
chmod 400 /shared/munge.key

# Install Python and scientific computing tools (if not using base box)
if [ ! -f /etc/slurm-base-version ] && [ ! -f /etc/hpc-base-version ]; then
    echo "Installing Python and scientific computing packages..."
    apt-get install -y python3 python3-pip python3-venv python3-dev
    pip3 install numpy scipy matplotlib pandas seaborn jupyter notebook scikit-learn

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

    echo "Building Slurm without MySQL..."

    # Configure and build Slurm as vagrant user (without MySQL initially)
    sudo -u vagrant ./configure --prefix=/opt/slurm --sysconfdir=/etc/slurm \
        --enable-pam --with-pam_dir=/lib/x86_64-linux-gnu/security/ \
        --without-shared-libslurm

    sudo -u vagrant make -j$(nproc)

    make install

    # Create necessary directories
    mkdir -p /etc/slurm
    mkdir -p /var/spool/slurmctld
    mkdir -p /var/spool/slurmd
    mkdir -p /var/log/slurm
    mkdir -p /opt/slurm/var/run

    # Set ownership
    chown -R slurm:slurm /var/spool/slurmctld
    chown -R slurm:slurm /var/spool/slurmd
    chown -R slurm:slurm /var/log/slurm
    chown -R slurm:slurm /opt/slurm/var/run

    # Add Slurm binaries to PATH
    echo 'export PATH="/opt/slurm/bin:/opt/slurm/sbin:$PATH"' >> /etc/profile.d/slurm.sh
    echo 'export LD_LIBRARY_PATH="/opt/slurm/lib:$LD_LIBRARY_PATH"' >> /etc/profile.d/slurm.sh
    chmod +x /etc/profile.d/slurm.sh

    echo "Slurm build completed!"
fi

# Source the environment
source /etc/profile.d/slurm.sh

# Create slurm.conf
cat > /etc/slurm/slurm.conf << 'EOF'
# slurm.conf file generated for Vagrant cluster
ClusterName=vagrant-cluster
SlurmctldHost=slurm-controller

# Network
SlurmctldPort=6817
SlurmdPort=6818

# Authentication
AuthType=auth/munge
MpiDefault=none

# Scheduling
SchedulerType=sched/backfill
SelectType=select/cons_tres
SelectTypeParameters=CR_Core

# Process tracking
ProctrackType=proctrack/cgroup
TaskPlugin=task/affinity,task/cgroup

# Logging
SlurmctldDebug=info
SlurmdDebug=info
SlurmctldLogFile=/var/log/slurm/slurmctld.log
SlurmdLogFile=/var/log/slurm/slurmd.log

# State info
StateSaveLocation=/var/spool/slurmctld
SlurmdSpoolDir=/var/spool/slurmd

# Process IDs
SlurmctldPidFile=/opt/slurm/var/run/slurmctld.pid
SlurmdPidFile=/opt/slurm/var/run/slurmd.pid

# Timeouts
SlurmctldTimeout=120
SlurmdTimeout=300
InactiveLimit=0
MinJobAge=300
KillWait=30
Waittime=0

# Return to service
ReturnToService=1

# Job completion
JobCompType=jobcomp/none

# Job accounting  
JobAcctGatherType=jobacct_gather/linux
JobAcctGatherFrequency=30

# Accounting storage (simplified - no database)
AccountingStorageType=accounting_storage/none

# Node definitions
NodeName=node[1-3] CPUs=2 Sockets=1 CoresPerSocket=2 ThreadsPerCore=1 RealMemory=900 State=UNKNOWN

# Partition definitions
PartitionName=compute Nodes=node[1-3] Default=YES MaxTime=INFINITE State=UP
EOF

# Copy slurm.conf to shared directory
cp /etc/slurm/slurm.conf /shared/

# Create systemd service files  
cat > /etc/systemd/system/slurmctld.service << 'EOF'
[Unit]
Description=Slurm controller daemon
After=network.target munge.service
Requires=munge.service

[Service]
Type=forking
EnvironmentFile=-/etc/default/slurmctld
ExecStart=/opt/slurm/sbin/slurmctld
ExecReload=/bin/kill -HUP $MAINPID
PIDFile=/opt/slurm/var/run/slurmctld.pid
LimitNOFILE=65536
LimitMEMLOCK=infinity
LimitSTACK=infinity

[Install]
WantedBy=multi-user.target
EOF

# Enable and start services
systemctl daemon-reload
systemctl enable slurmctld
systemctl start slurmctld

echo "Slurm Controller setup completed!"
echo "You can check the status with: systemctl status slurmctld"

