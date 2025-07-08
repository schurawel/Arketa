#!/bin/bash
#
# Script to set up slurmdbd (Slurm Database Daemon)
#

set -e

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

echo "📦 Installing MariaDB server..."
apt-get update
apt-get install -y mariadb-server

echo "🚀 Starting and enabling MariaDB..."
systemctl start mariadb
systemctl enable mariadb

echo "🔐 Securing MariaDB and setting up database..."
# Create database and user
mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS slurm_acct_db;
CREATE USER IF NOT EXISTS 'slurm'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON slurm_acct_db.* TO 'slurm'@'localhost';
FLUSH PRIVILEGES;
EOF

echo "📄 Creating slurmdbd.conf..."
cat << EOF > "$SLURMDBD_CONF_FILE"
# slurmdbd.conf
AuthType=auth/munge
DbdHost=localhost
DbdPort=6819
SlurmUser=slurm
LogFile=/var/log/slurm/slurmdbd.log
PidFile=/var/run/slurm/slurmdbd.pid
StorageType=accounting_storage/mysql
StorageHost=localhost
StoragePort=3306
StoragePass=$DB_PASS
StorageUser=slurm
StorageLoc=slurm_acct_db
EOF

echo "🔒 Setting permissions for slurmdbd.conf..."
chown slurm:slurm "$SLURMDBD_CONF_FILE"
chmod 600 "$SLURMDBD_CONF_FILE"

echo "🚀 Creating and starting slurmdbd service..."
# Ensure log and pid directories exist
mkdir -p /var/log/slurm /var/run/slurm
chown -R slurm:slurm /var/log/slurm /var/run/slurm

# Create systemd service file for slurmdbd
cat << EOF > /etc/systemd/system/slurmdbd.service
[Unit]
Description=Slurm DBD accounting daemon
After=network.target munge.service mariadb.service
Requires=mariadb.service
ConditionPathExists=/etc/slurm/slurmdbd.conf

[Service]
Type=forking
EnvironmentFile=-/etc/default/slurm-llnl
ExecStart=/opt/slurm/sbin/slurmdbd \$SLURMDBD_OPTIONS
ExecReload=/bin/kill -HUP \$MAINPID
PIDFile=/var/run/slurm/slurmdbd.pid
User=slurm
Group=slurm
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable slurmdbd
systemctl restart slurmdbd # Use restart to ensure it picks up new dependencies

# Wait for slurmdbd to become active and listen on its port
echo "⏳ Waiting for slurmdbd to start and listen on port 6819..."
for i in {1..15}; do
    if systemctl is-active --quiet slurmdbd && ss -tln | grep -q 6819; then
        echo "✅ slurmdbd started and is listening successfully."
        break
    fi
    echo "Still waiting for slurmdbd... attempt $i"
    sleep 2
done

if ! ss -tln | grep -q 6819; then
    echo "❌ ERROR: slurmdbd failed to start or listen on port 6819. Check /var/log/slurm/slurmdbd.log"
    exit 1
fi

# Add a small delay for good measure before running sacctmgr
sleep 2

echo "🔗 Associating cluster with the accounting database..."
# The -i flag makes it idempotent
/opt/slurm/bin/sacctmgr -i add cluster vagrant-cluster

echo "--- slurmdbd setup complete at $(date) ---"
