#!/bin/bash
# Slurm Controller Setup Script

set -e

echo "Setting up Slurm Controller Node..."

# Verify base system is available
if [ ! -f /etc/hpc-base-version ]; then
    echo "ERROR: HPC base system not found. Run setup-base.sh first."
    exit 1
fi

# Source the Slurm environment (should be available from base setup)
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

# Setup Munge authentication with new key for controller
systemctl enable munge
dd if=/dev/urandom bs=1 count=1024 > /etc/munge/munge.key
chown munge:munge /etc/munge/munge.key
chmod 400 /etc/munge/munge.key
systemctl start munge

# Copy munge key to shared directory for compute nodes
cp /etc/munge/munge.key /shared/
chown slurm:slurm /shared/munge.key
chmod 400 /shared/munge.key

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
MpiDefault=pmix

# Scheduling
SchedulerType=sched/backfill
SelectType=select/cons_tres
SelectTypeParameters=CR_Core

# Process tracking with cgroups v2
ProctrackType=proctrack/cgroup
TaskPlugin=task/affinity,task/cgroup
SlurmdUser=root

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
SlurmdPidFile=/run/slurm/slurmd.pid

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

# Job accounting with cgroups v2 support
JobAcctGatherType=jobacct_gather/cgroup
JobAcctGatherFrequency=30

# Accounting storage (connect to slurmdbd)
AccountingStorageType=accounting_storage/slurmdbd
AccountingStorageHost=localhost

# Node definitions (controller + 2 compute nodes)
NodeName=controller,node[1-2] CPUs=2 Sockets=1 CoresPerSocket=2 ThreadsPerCore=1 RealMemory=1800 State=UNKNOWN

# Partition definitions (controller + 2 compute nodes)
PartitionName=compute Nodes=controller,node[1-2] Default=YES MaxTime=INFINITE State=UP
EOF

# Copy slurm.conf to shared directory
cp /etc/slurm/slurm.conf /shared/

# Create cgroup.conf for cgroups v2 support
cat > /etc/slurm/cgroup.conf << 'EOF'
# Cgroup configuration for Slurm with cgroups v2
CgroupMountpoint="/sys/fs/cgroup"
CgroupPlugin=cgroup/v2

# Enable resource constraints
ConstrainCores=yes
ConstrainRAMSpace=yes
ConstrainSwapSpace=no
ConstrainDevices=yes
EOF

# Copy cgroup.conf to shared directory too
cp /etc/slurm/cgroup.conf /shared/

# Create systemd service files  
cat > /etc/systemd/system/slurmctld.service << 'EOF'
[Unit]
Description=Slurm controller daemon
After=network.target munge.service
Requires=munge.service

[Service]
Type=forking
EnvironmentFile=-/etc/default/slurmctld
ExecStartPre=/bin/mkdir -p /opt/slurm/var/run
ExecStartPre=/bin/chown slurm:slurm /opt/slurm/var/run
ExecStart=/opt/slurm/sbin/slurmctld
ExecReload=/bin/kill -HUP $MAINPID
PIDFile=/opt/slurm/var/run/slurmctld.pid
LimitNOFILE=65536
LimitMEMLOCK=infinity
LimitSTACK=infinity
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF

# Create slurmd service file for the controller
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

# Create required directories for slurmd
mkdir -p /var/spool/slurmd /var/log/slurm /run/slurm
chown slurm:slurm /var/spool/slurmd /var/log/slurm /run/slurm
chmod 755 /var/spool/slurmd /var/log/slurm /run/slurm

# Enable and start services
systemctl daemon-reload
systemctl enable slurmctld
systemctl start slurmctld
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

echo "Slurm Controller setup completed!"
echo "You can check the status with: systemctl status slurmctld"

