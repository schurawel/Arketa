#!/bin/bash
# Exit on any error
set -e

echo "--- Setting up slurm-web from source ---"

# Install dependencies
apt-get update
apt-get install -y git python3 python3-pip

# Clone the repository
if [ ! -d "/opt/slurm-web" ]; then
  git clone https://github.com/rackslab/slurm-web.git /opt/slurm-web
else
  echo "slurm-web repository already exists. Pulling latest changes."
  cd /opt/slurm-web
  git pull
fi

# Install Python dependencies
pip3 install -r /opt/slurm-web/requirements.txt

# Create systemd service file
cat > /etc/systemd/system/slurm-web.service << 'EOF'
[Unit]
Description=Slurm-Web - A web interface for Slurm
After=network.target slurmctld.service
Requires=slurmctld.service

[Service]
Type=simple
User=vagrant
Group=vagrant
WorkingDirectory=/opt/slurm-web
ExecStart=/usr/bin/python3 /opt/slurm-web/app.py
Environment="SLURM_WEB_HOST=0.0.0.0"
Environment="SLURM_WEB_PORT=8081"
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd, enable and start the service
systemctl daemon-reload
systemctl enable slurm-web.service
systemctl restart slurm-web.service

echo "--- slurm-web setup from source complete ---"
echo "--- Access it at http://localhost:8081 ---"
