#!/bin/bash
#
# Script to set up slurmdbd (Slurm Database Daemon)
#

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

echo "Setting up Slurm Database Daemon (slurmdbd)..."

# --- Configuration ---
DB_PASS="slurmdbpassword"
LOG_FILE="/var/log/slurm/setup-slurmdbd.log"
SLURM_CONF_DIR="/etc/slurm"
SLURMDBD_CONF_FILE="$SLURM_CONF_DIR/slurmdbd.conf"

# --- Logging ---
exec > >(tee -a "$LOG_FILE") 2>&1
echo "--- Starting slurmdbd setup at $(date) ---"

# --- Idempotency Check ---
if [ -f "$SLURMDBD_CONF_FILE" ] && systemctl is-active --quiet slurmdbd; then
    echo "✅ slurmdbd is already configured and running. Skipping setup."
    exit 0
fi

# Source the apt lock utility functions
if [ -f "$(dirname "$0")/wait-for-apt.sh" ]; then
    source "$(dirname "$0")"/wait-for-apt.sh
else
    echo "ERROR: wait-for-apt.sh not found. Continuing without lock checking."
    # Define a minimal fallback function
    wait_for_apt_locks() {
        echo "⚠️ Skipping apt lock check (utility script not found)"
        return 0
    }
fi

# Install MariaDB with lock handling
echo "📦 Installing MariaDB server..."
wait_for_apt_locks 600 || {
    echo "ERROR: Could not acquire apt locks after waiting. Please try again later."
    exit 1
}

# Check that MariaDB was installed in setup-base.sh
if ! command -v mysql >/dev/null 2>&1; then
    echo "ERROR: MariaDB server not found. Should have been installed in setup-base.sh"
    exit 1
fi

echo "✅ MariaDB server already installed in base system"

# Configure MariaDB for slurmdbd
echo "🔧 Configuring MariaDB for slurmdbd..."

# Ensure MariaDB is running
systemctl enable --now mariadb || {
    echo "ERROR: Failed to enable MariaDB service"
    exit 1
}

# Create database and user non-interactively
mysql -e "CREATE DATABASE IF NOT EXISTS slurm_acct_db CHARACTER SET utf8mb4;" || {
    echo "ERROR: Failed to create Slurm database"
    exit 1
}

# Create slurm user with password 'slurmdbpass'
mysql -e "GRANT ALL ON slurm_acct_db.* TO 'slurm'@'localhost' IDENTIFIED BY 'slurmdbpass';" || {
    echo "ERROR: Failed to create Slurm database user"
    exit 1
}

# Flush privileges
mysql -e "FLUSH PRIVILEGES;" || {
    echo "ERROR: Failed to flush privileges"
    exit 1
}

# Create slurmdbd.conf
echo "🔧 Creating slurmdbd configuration..."
cat > /etc/slurm/slurmdbd.conf << 'EOF'
# slurmdbd.conf
ArchiveEvents=yes
ArchiveJobs=yes
ArchiveResvs=yes
ArchiveSteps=no
ArchiveSuspend=no
ArchiveTXN=no
ArchiveUsage=no

AuthType=auth/munge
DbdHost=localhost
DbdPort=6819
DebugLevel=info

LogFile=/var/log/slurm/slurmdbd.log
PidFile=/opt/slurm/var/run/slurmdbd.pid

SlurmUser=slurm

StorageType=accounting_storage/mysql
StorageUser=slurm
StoragePass=slurmdbpass
StorageLoc=slurm_acct_db
EOF

# Set secure permissions
chmod 600 /etc/slurm/slurmdbd.conf
chown slurm:slurm /etc/slurm/slurmdbd.conf

# Create systemd service file for slurmdbd
echo "🔧 Creating slurmdbd systemd service..."
cat > /etc/systemd/system/slurmdbd.service << 'EOF'
[Unit]
Description=Slurm Database Daemon
After=network.target munge.service mariadb.service
Requires=munge.service mariadb.service

[Service]
Type=forking
EnvironmentFile=-/etc/default/slurmdbd
ExecStartPre=/bin/mkdir -p /opt/slurm/var/run
ExecStartPre=/bin/chown slurm:slurm /opt/slurm/var/run
ExecStart=/opt/slurm/sbin/slurmdbd
ExecReload=/bin/kill -HUP $MAINPID
PIDFile=/opt/slurm/var/run/slurmdbd.pid
LimitNOFILE=65536
LimitMEMLOCK=infinity
LimitSTACK=infinity
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF

# Enable and start slurmdbd service with proper error handling
echo "🚀 Starting slurmdbd service..."
systemctl daemon-reload
systemctl enable slurmdbd

if [ "$LINEAR_MODE" = "true" ]; then
    systemctl start slurmdbd || echo "⚠️ slurmdbd start issues in linear mode - continuing anyway"
    # Skip wait and verification steps for linear mode
else
    systemctl start slurmdbd || {
        echo "ERROR: Failed to start slurmdbd service"
        echo "=== Service status ==="
        systemctl status slurmdbd --no-pager -l || true
        echo "=== Journal logs ==="
        journalctl -xeu slurmdbd.service --no-pager --lines=30 || true
        exit 1
    }

    # Wait for slurmdbd to be fully available
    echo "⏳ Waiting for slurmdbd to become available..."
    sleep 10
fi

# Initialize accounting
echo "🔧 Initializing Slurm accounting..."
if [ "$LINEAR_MODE" = "true" ]; then
    /opt/slurm/bin/sacctmgr --immediate add cluster vagrant-cluster || echo "⚠️ Cluster accounting issues in linear mode - continuing anyway"
else
    /opt/slurm/bin/sacctmgr --immediate add cluster vagrant-cluster || {
        echo "WARNING: Failed to add cluster to accounting. This might be OK if it already exists."
        # Check if cluster exists
        if /opt/slurm/bin/sacctmgr list cluster format=cluster,controlhost,controlport -n | grep -q vagrant-cluster; then
            echo "✅ Cluster 'vagrant-cluster' already exists in accounting database."
        else
            echo "ERROR: Failed to add or verify cluster in accounting database."
            exit 1
        fi
    }
fi

# Final verification - skip in linear mode
if [ "$LINEAR_MODE" != "true" ]; then
    echo "🔍 Verifying slurmdbd service..."
    if systemctl is-active --quiet slurmdbd; then
        echo "✅ slurmdbd is running successfully"
    else
        echo "❌ slurmdbd is not running. Please check the logs."
        systemctl status slurmdbd --no-pager -l
        exit 1
    fi
fi

echo "✅ Slurm Database Daemon setup completed!"
