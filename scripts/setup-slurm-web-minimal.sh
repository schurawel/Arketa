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
