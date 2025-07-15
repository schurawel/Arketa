#!/bin/bash
# Simplified Slurm-web setup following the official quickstart guide
# https://docs.rackslab.io/slurm-web/install/quickstart.html

set -e  # Exit immediately if a command exits with a non-zero status

echo "======================================================="
echo "      Slurm-web Installation (Official Method)         "
echo "======================================================="

# Step 1: Add the Rackslab repository
echo "[1/6] Adding Rackslab repository..."
curl -fsSL https://pkgs.rackslab.io/keyring.asc | sudo gpg --dearmor -o /usr/share/keyrings/rackslab.gpg

# Create repository source file
cat <<EOF | sudo tee /etc/apt/sources.list.d/rackslab.sources
Types: deb
URIs: https://pkgs.rackslab.io/deb
Suites: ubuntu24.04
Components: main slurmweb-5
Architectures: amd64
Signed-By: /usr/share/keyrings/rackslab.gpg
EOF

# Update package lists
sudo apt update

# Step 2: Install packages
echo "[2/6] Installing Slurm-web packages..."
sudo apt install -y slurm-web-agent slurm-web-gateway

# Step 3: Generate JWT keys
echo "[3/6] Setting up JWT authentication..."

# Generate JWT key for Slurm-web
sudo /usr/libexec/slurm-web/slurm-web-gen-jwt-key

# Copy slurmrestd JWT key (assuming it already exists)
if [ -f "/var/spool/slurm/jwt_hs256.key" ]; then
    sudo cp /var/spool/slurm/jwt_hs256.key /var/lib/slurm-web/slurmrestd.key
    sudo chown slurm-web:slurm-web /var/lib/slurm-web/slurmrestd.key
    sudo chmod 400 /var/lib/slurm-web/slurmrestd.key
else
    echo "ERROR: slurmrestd JWT key not found at /var/spool/slurm/jwt_hs256.key"
    echo "Please ensure slurmrestd is configured with JWT authentication"
    exit 1
fi

# Step 4: Configure agent
echo "[4/6] Configuring Slurm-web agent..."
cat <<EOF | sudo tee /etc/slurm-web/agent.ini
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

# Step 5: Configure gateway
echo "[5/6] Configuring Slurm-web gateway..."
cat <<EOF | sudo tee /etc/slurm-web/gateway.ini
[service]
interface=0.0.0.0
port=5011

[agents]
url=http://localhost:5012

[authentication]
enabled=no
EOF

# Create anonymous access policy for demo purposes
cat <<EOF | sudo tee /etc/slurm-web/policy.ini
[roles]
anonymous

[anonymous]
actions=view-stats,view-jobs,view-nodes,view-partitions,view-qos,view-accounts,view-reservations,cache-view
EOF

# Step 6: Start services
echo "[6/6] Starting Slurm-web services..."
sudo systemctl daemon-reload
sudo systemctl restart slurmrestd
sleep 2
sudo systemctl enable --now slurm-web-agent
sleep 5
sudo systemctl enable --now slurm-web-gateway

# Verify services are running
echo "Verifying service status..."
for service in slurmrestd slurm-web-agent slurm-web-gateway; do
    if systemctl is-active --quiet $service; then
        echo "✅ $service is running"
    else
        echo "❌ $service is not running"
        systemctl status $service --no-pager
    fi
done

echo ""
echo "===================== INSTALLATION COMPLETE ====================="
echo "Access Slurm-web at: http://$(hostname -I | awk '{print $1}'):5011"
echo "If you encounter issues, check these logs:"
echo "  - sudo journalctl -u slurm-web-agent"
echo "  - sudo journalctl -u slurm-web-gateway"
echo "  - sudo journalctl -u slurmrestd"
echo "================================================================"
