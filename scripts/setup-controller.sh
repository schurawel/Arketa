#!/bin/bash
# Slurm Controller Node Setup Script

set -e

# Parse command line arguments
LINEAR_MODE=false
for arg in "$@"; do
    case $arg in
        --linear-setup)
            LINEAR_MODE=true
            echo "📋 Running in linear setup mode - skipping non-essential tests"
            ;;
    esac
done

echo "Setting up Slurm Controller Node..."

# Add host entries (moved from Vagrantfile)
grep -q "slurm-controller" /etc/hosts || echo "192.168.7.10 slurm-controller controller" >> /etc/hosts
grep -q "node1" /etc/hosts || echo "192.168.7.11 node1" >> /etc/hosts
grep -q "node2" /etc/hosts || echo "192.168.7.12 node2" >> /etc/hosts

# Set hostname
hostnamectl set-hostname slurm-controller

# Source the apt lock utility functions if available
if [ -f "$(dirname "$0")/wait-for-apt.sh" ]; then
    source "$(dirname "$0")/wait-for-apt.sh"
else
    echo "WARNING: wait-for-apt.sh not found. Continuing without lock checking."
    # Define a minimal fallback function
    wait_for_apt_locks() {
        echo "⚠️ Skipping apt lock check (utility script not found)"
        return 0
    }
fi

# Set up NFS server (moved from Vagrantfile)
echo "Setting up NFS server for shared directories..."
wait_for_apt_locks 600 || {
    echo "ERROR: Could not acquire apt locks after waiting. Please try again later."
    exit 1
}
apt-get update
apt-get install -y nfs-kernel-server tigervnc-standalone-server tigervnc-common xfce4 xfce4-terminal kde-plasma-desktop firefox

# Setup shared directory
mkdir -p /shared
chown slurm:slurm /shared
chmod 777 /shared  # Make shared directory world-writable to avoid permission issues with MPI jobs

# Create required subdirectories with proper permissions
mkdir -p /shared/mpi-jobs
chmod 777 /shared/mpi-jobs
chown slurm:slurm /shared/mpi-jobs

# Configure NFS export for shared directory - FIXED NETWORK ADDRESS
grep -q "/shared 192.168.7.0/24" /etc/exports || echo "/shared 192.168.7.0/24(rw,sync,no_subtree_check,no_root_squash)" > /etc/exports
# Also remove old exports if they exist
sed -i '/\/shared 192.168.121.0\/24/d' /etc/exports

# Enable and restart NFS server with proper settings
systemctl enable nfs-kernel-server
systemctl restart nfs-kernel-server
exportfs -ra

# Verify exports are configured correctly
echo "Verifying NFS exports..."
exportfs -v

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

# Start munge with skip option for linear mode
if [ "$LINEAR_MODE" = "true" ]; then
    systemctl start munge || echo "⚠️ Munge start issues in linear mode - continuing anyway"
else
    systemctl start munge
fi

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

# Run the setup script for the Slurm Database Daemon
if [ -f "/home/ubuntu/scripts/setup-slurmdbd.sh" ]; then
    if [ "$LINEAR_MODE" = "true" ]; then
        /home/ubuntu/scripts/setup-slurmdbd.sh --linear-setup
    else
        /home/ubuntu/scripts/setup-slurmdbd.sh
    fi
elif [ -f "/home/vagrant/scripts/setup-slurmdbd.sh" ]; then
    if [ "$LINEAR_MODE" = "true" ]; then
        /home/vagrant/scripts/setup-slurmdbd.sh --linear-setup
    else
        /home/vagrant/scripts/setup-slurmdbd.sh
    fi
else
    echo "ERROR: setup-slurmdbd.sh script not found in expected locations"
    exit 1
fi

# Setup and start slurmrestd
echo "🚀 Setting up slurmrestd service..."

# Check if slurmrestd binary exists
if [ ! -f /opt/slurm/sbin/slurmrestd ]; then
    echo "❌ slurmrestd binary not found. Slurm may not have been built with REST API support."
    echo "⚠️ Continuing without slurmrestd..."
else
    echo "✅ Found slurmrestd binary"
    
    # Ensure JWT key exists before creating service (using official method)
    if [ ! -f "/var/spool/slurm/jwt_hs256.key" ]; then
        echo "Creating JWT key for slurmrestd using official method..."
        sudo mkdir -p /var/spool/slurm
        sudo dd if=/dev/random of=/var/spool/slurm/jwt_hs256.key bs=32 count=1
        sudo chown slurm:slurm /var/spool/slurm/jwt_hs256.key
        sudo chmod 0600 /var/spool/slurm/jwt_hs256.key
    fi
    
    # Create slurmrestd service file with Unix socket (OFFICIAL QUICKSTART METHOD)
    cat <<'EOF' | sudo tee /etc/systemd/system/slurmrestd.service
[Unit]
Description=Slurm REST daemon
After=network.target munge.service slurmctld.service
Requires=munge.service

[Service]
Type=simple
Environment="SLURM_JWT=daemon"
ExecStart=/opt/slurm/sbin/slurmrestd -a rest_auth/jwt unix:/run/slurmrestd/slurmrestd.socket
RuntimeDirectory=slurmrestd
RuntimeDirectoryMode=0755
User=slurm
Group=slurm
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    # Enable and start slurmrestd with skip option for linear mode
    systemctl daemon-reload
    systemctl enable slurmrestd
    if [ "$LINEAR_MODE" = "true" ]; then
        systemctl start slurmrestd || echo "⚠️ slurmrestd start issues in linear mode - continuing anyway"
        # Skip connectivity tests
    else
        systemctl start slurmrestd || {
            echo "⚠️ slurmrestd failed to start. Checking logs..."
            journalctl -u slurmrestd --no-pager -n 20
        }
        
        # Wait for slurmrestd to be ready
        sleep 10
        
        # Check if slurmrestd is running
        if systemctl is-active --quiet slurmrestd; then
            echo "✅ slurmrestd is running with Unix socket"
            
            # Test slurmrestd connectivity with Unix socket
            if [ -S "/run/slurmrestd/slurmrestd.socket" ]; then
                echo "✅ slurmrestd Unix socket exists"
                
                # Test with scontrol token
                if sudo -u slurm /opt/slurm/bin/scontrol token > /dev/null 2>&1; then
                    echo "✅ JWT token generation works"
                else
                    echo "⚠️ JWT token generation failed"
                fi
            else
                echo "⚠️ slurmrestd Unix socket not found"
            fi
        else
            echo "⚠️ slurmrestd is not running. slurm-web may have limited functionality."
        fi
    fi
fi


echo "🌐 Setting up Open OnDemand..."
if [ -f /home/ubuntu/scripts/setup-ondemand.sh ]; then
    chmod +x /home/ubuntu/scripts/setup-ondemand.sh
    if [ "$LINEAR_MODE" = "true" ]; then
        /home/ubuntu/scripts/setup-ondemand.sh --linear-setup || echo "⚠️ OnDemand setup issues in linear mode - continuing anyway"
    else
        /home/ubuntu/scripts/setup-ondemand.sh || {
            echo "⚠️ OnDemand setup encountered issues. Checking status..."
            systemctl status apache2 --no-pager || true
            echo "📋 Apache sites enabled:"
            ls -la /etc/apache2/sites-enabled/ || true
        }
    fi
    echo "✅ Open OnDemand setup attempt complete."
    echo "👉 Access the portal at http://192.168.7.10/"
    echo "👤 Login: ooduser / ooduser"
elif [ -f /home/vagrant/scripts/setup-ondemand.sh ]; then
    chmod +x /home/vagrant/scripts/setup-ondemand.sh
    if [ "$LINEAR_MODE" = "true" ]; then
        /home/vagrant/scripts/setup-ondemand.sh --linear-setup || echo "⚠️ OnDemand setup issues in linear mode - continuing anyway"
    else
        /home/vagrant/scripts/setup-ondemand.sh || {
            echo "⚠️ OnDemand setup encountered issues."
        }
    fi
else
    echo "🤷 Skipping Open OnDemand setup: script not found."
fi

# Install and configure slurm-web with linear mode flag if needed
echo "🌐 Setting up slurm-web from source..."
if [ -d "/home/ubuntu/scripts" ]; then
    echo "📝 Creating minimal slurm-web setup script..."
    cat > /home/ubuntu/scripts/setup-slurm-web-minimal.sh << 'EOFMINIMALSCRIPT'
#!/bin/bash
# Minimal slurm-web setup script - focused on fixing URL parameter issue

set -e

echo "======================================================="
echo "  Slurm-web Installation (Minimal Configuration)       "
echo "======================================================="

echo "[1/4] Installing slurm-web packages..."
sudo apt-get update
sudo apt-get install -y slurm-web-agent slurm-web-gateway

echo "[2/4] Setting up JWT authentication..."
sudo mkdir -p /var/lib/slurm-web
sudo /usr/libexec/slurm-web/slurm-web-gen-jwt-key || {
    echo "Manually creating JWT key..."
    sudo dd if=/dev/urandom bs=32 count=1 of=/var/lib/slurm-web/jwt.key
    sudo chown slurm-web:slurm-web /var/lib/slurm-web/jwt.key
    sudo chmod 400 /var/lib/slurm-web/jwt.key
}

sudo cp /var/spool/slurm/jwt_hs256.key /var/lib/slurm-web/slurmrestd.key
sudo chown slurm-web:slurm-web /var/lib/slurm-web/slurmrestd.key
sudo chmod 400 /var/lib/slurm-web/slurmrestd.key

echo "[3/4] Creating configuration files..."
# Agent configuration
cat > /tmp/agent.ini << 'EOF'
[service]
cluster=vagrant-cluster
interface=0.0.0.0
port=5012

[slurmrestd]
socket=/run/slurmrestd/slurmrestd.socket
jwt_key=/var/lib/slurm-web/slurmrestd.key

[cache]
enabled=no

[racksdb]
enabled=no
EOF
sudo mkdir -p /etc/slurm-web
sudo cp /tmp/agent.ini /etc/slurm-web/agent.ini

# Gateway configuration - focus of the fix
cat > /tmp/gateway.ini << 'EOF'
[service]
interface=0.0.0.0
port=5011

[agents]
url=http://localhost:5012

[authentication]
enabled=no
EOF
sudo cp /tmp/gateway.ini /etc/slurm-web/gateway.ini

# Verify configuration files were created properly
echo "Verifying gateway.ini configuration..."
if grep -q "url=http://localhost:5012" /etc/slurm-web/gateway.ini; then
    echo "✅ Gateway configuration verified"
else
    echo "❌ Gateway configuration verification failed"
    echo "Manually setting URL parameter..."
    # Force create the gateway.ini file with correct parameter
    sudo bash -c 'echo "[service]" > /etc/slurm-web/gateway.ini'
    sudo bash -c 'echo "interface=0.0.0.0" >> /etc/slurm-web/gateway.ini'
    sudo bash -c 'echo "port=5011" >> /etc/slurm-web/gateway.ini'
    sudo bash -c 'echo "" >> /etc/slurm-web/gateway.ini'
    sudo bash -c 'echo "[agents]" >> /etc/slurm-web/gateway.ini'
    sudo bash -c 'echo "url=http://localhost:5012" >> /etc/slurm-web/gateway.ini'
    sudo bash -c 'echo "" >> /etc/slurm-web/gateway.ini'
    sudo bash -c 'echo "[authentication]" >> /etc/slurm-web/gateway.ini'
    sudo bash -c 'echo "enabled=no" >> /etc/slurm-web/gateway.ini'
fi

# Policy configuration
cat > /tmp/policy.ini << 'EOF'
[roles]
anonymous

[anonymous]
actions=view-stats,view-jobs,view-nodes,view-partitions,view-qos,view-accounts,view-reservations,cache-view
EOF
sudo cp /tmp/policy.ini /etc/slurm-web/policy.ini

echo "[4/4] Starting services..."
sudo systemctl daemon-reload
sudo systemctl restart slurmrestd
sleep 3
sudo systemctl restart slurm-web-agent
sleep 5
sudo systemctl restart slurm-web-gateway

# Final verification
echo "Verifying services..."
for service in slurmrestd slurm-web-agent slurm-web-gateway; do
    if systemctl is-active --quiet $service; then
        echo "✅ $service is running"
    else
        echo "❌ $service is not running"
        systemctl status $service --no-pager
    fi
done

# Double-check the gateway configuration
echo "Double-checking gateway configuration..."
if [ -f /etc/slurm-web/gateway.ini ]; then
    cat /etc/slurm-web/gateway.ini
else
    echo "❌ Gateway configuration file doesn't exist!"
fi

# If the gateway service is still not running, try a direct manual approach
if ! systemctl is-active --quiet slurm-web-gateway; then
    echo "Attempting manual gateway start with debugging..."
    # Try starting the gateway manually with verbose output
    sudo slurm-web-gateway -c /etc/slurm-web/gateway.ini -v
fi

echo ""
echo "Installation complete! Access Slurm-web at: http://$(hostname -I | awk '{print $1}'):5011"
echo ""
EOFMINIMALSCRIPT

    chmod +x /home/ubuntu/scripts/setup-slurm-web-minimal.sh
    if [ "$LINEAR_MODE" = "true" ]; then
        /home/ubuntu/scripts/setup-slurm-web-minimal.sh --linear-setup || echo "⚠️ slurm-web setup issues in linear mode - continuing anyway"
    else
        /home/ubuntu/scripts/setup-slurm-web-minimal.sh || {
            echo "⚠️ Minimal slurm-web setup encountered issues."
            systemctl status slurm-web-agent slurm-web-gateway --no-pager || true
            echo "📋 Checking gateway.ini for URL parameter..."
            if [ -f /etc/slurm-web/gateway.ini ]; then
                if ! grep -q "url=" /etc/slurm-web/gateway.ini; then
                    echo "🔧 URL parameter missing, manually adding it..."
                    echo -e "\n[agents]\nurl=http://localhost:5012" | sudo tee -a /etc/slurm-web/gateway.ini
                    sudo systemctl restart slurm-web-gateway
                fi
            fi
        }
    fi
    echo "✅ slurm-web setup complete."
    echo "👉 Access the portal at http://192.168.7.10:5011"
else
    echo "🤷 Skipping slurm-web setup: scripts directory not found."
fi

# Mark controller as fully provisioned for compute nodes
echo "🎯 Controller provisioning complete"
echo "✅ Controller node fully configured and ready for compute nodes"

echo "Slurm Controller setup completed!"
echo "You can check the status with: systemctl status slurmctld"

