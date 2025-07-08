#!/bin/bash
# Exit on any error
set -e

echo "--- Setting up slurm-web from source ---"

# Install dependencies
apt-get update
apt-get install -y git python3 python3-pip python3-dev build-essential \
    libsasl2-dev libldap2-dev libssl-dev

# Clone the repository into tmp directory if not already present
if [ ! -d "/home/vagrant/tmp/slurm-web" ]; then
    echo "--- Cloning slurm-web repository ---"
    cd /home/vagrant/tmp
    git clone https://github.com/rackslab/slurm-web.git
else
    echo "--- slurm-web repository already exists ---"
    cd /home/vagrant/tmp/slurm-web
    git pull
fi

# Install Python dependencies and slurm-web
echo "--- Installing slurm-web ---"
cd /home/vagrant/tmp/slurm-web

# Install pipx for isolated Python package management
echo "--- Installing pipx ---"
apt-get install -y python3-venv
sudo -u vagrant python3 -m pip install --user pipx
sudo -u vagrant python3 -m pipx ensurepath

# Install slurm-web using pipx
echo "--- Installing slurm-web with pipx ---"
sudo -u vagrant /home/vagrant/.local/bin/pipx install /home/vagrant/tmp/slurm-web || {
    echo "❌ ERROR: pipx failed to install slurm-web."
    exit 1
}

# Locate the slurm-web-gateway executable
echo "--- Locating slurm-web-gateway executable ---"
SLURM_WEB_GATEWAY=$(sudo -u vagrant /home/vagrant/.local/bin/pipx list | grep -o '/.*slurm-web-gateway')
if [ -z "$SLURM_WEB_GATEWAY" ]; then
    echo "❌ ERROR: slurm-web-gateway executable not found after pipx installation."
    exit 1
fi
echo "✅ Found slurm-web-gateway at: $SLURM_WEB_GATEWAY"

# Create basic configuration directory and files
sudo mkdir -p /etc/slurm-web
sudo tee /etc/slurm-web/gateway.ini > /dev/null << 'EOF'
[service]
interface = 0.0.0.0
port = 8081
debug = false

[authentication]
enabled = false

[ui]
enabled = false

[jwt]
audience = slurm-web
algorithm = HS256
key = changeme-insecure-default-key
EOF

# Create systemd service file
sudo tee /etc/systemd/system/slurm-web.service > /dev/null << EOF
[Unit]
Description=Slurm-Web - A web interface for Slurm
After=network.target slurmctld.service
Requires=slurmctld.service

[Service]
Type=simple
User=vagrant
Group=vagrant
WorkingDirectory=/home/vagrant/tmp/slurm-web
# Use the dynamically found executable path
ExecStart=$SLURM_WEB_GATEWAY
Environment="PATH=/home/vagrant/.local/bin:/usr/local/bin:/usr/bin:/bin"
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd, enable and start the service
sudo systemctl daemon-reload
sudo systemctl enable slurm-web.service
sudo systemctl restart slurm-web.service

# Health check for slurm-web
echo "--- Verifying slurm-web installation ---"
# Give the service a moment to start up
sleep 5
if curl --silent --fail http://localhost:8081; then
    echo "✅ slurm-web is running."
else
    echo "❌ ERROR: slurm-web failed to start." >&2
    # Show logs for debugging
    journalctl -u slurm-web.service --no-pager -n 50
    exit 1
fi

echo "--- slurm-web setup from source complete ---"
echo "--- Access it at http://localhost:8081 ---"
