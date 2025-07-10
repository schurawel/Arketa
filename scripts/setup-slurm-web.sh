#!/bin/bash
# setup-slurm-web.sh - Simplified slurm-web setup script
# Installs slurm-web with minimal configuration in the correct location

set -e

echo "🌐 Setting up slurm-web - Minimal Configuration"

# Install dependencies and development tools
echo "📦 Installing dependencies..."
apt-get update
apt-get install -y git python3 python3-pip python3-venv python3-dev build-essential python3-setuptools python3-wheel

# Create the exact directory structure slurm-web is looking for
echo "📂 Creating configuration directory..."
mkdir -p /usr/share/slurm-web/conf

# Create the gateway.yml file exactly where slurm-web is looking for it
echo "📝 Creating minimal configuration in the CORRECT location..."
cat > /usr/share/slurm-web/conf/gateway.yml << 'EOF'
---
service:
  interface: 0.0.0.0
  port: 8081
  debug: false

authentication:
  enabled: false

jwt:
  audience: slurm-web
  algorithm: HS256
  key: changeme-insecure-default-key

clusters:
  - name: default
    description: PrimedSLURM Cluster
    controller: localhost
    authentication: none
EOF

# Install slurm-web from existing source code
echo "🔧 Installing slurm-web from existing source code..."

# Check if the source code exists
if [ ! -d "/home/vagrant/tmp/slurm-web" ]; then
  echo "❌ Source code not found at /home/vagrant/tmp/slurm-web"
  echo "Expected to find slurm-web source code in this location"
  exit 1
fi

# Change to the source directory
cd /home/vagrant/tmp/slurm-web

# Create a setup.py file to support editable installs
echo "📝 Creating setup.py file to support editable installs..."
cat > setup.py << 'EOF'
from setuptools import setup, find_packages

setup(
    name="slurm-web",
    version="0.1.0",
    packages=find_packages(),
    install_requires=[
        "flask",
        "pyyaml",
        "pyjwt",
        "requests",
    ],
    entry_points={
        'console_scripts': [
            'slurm-web-gateway=slurmweb.gateway:main',
        ],
    },
)
EOF

# Install using pip in development mode with our custom setup.py
echo "📦 Installing from source in development mode..."
pip3 install -e .

# Ensure binary is in PATH for vagrant user
echo "🔗 Setting up PATH for slurm-web binaries..."
if ! grep -q "/home/vagrant/.local/bin" /home/vagrant/.bashrc; then
  echo 'export PATH="/home/vagrant/.local/bin:$PATH"' >> /home/vagrant/.bashrc
fi

# Make sure the binary exists
if [ ! -f "/home/vagrant/.local/bin/slurm-web-gateway" ]; then
  # Try alternative installation location
  if [ -f "/usr/local/bin/slurm-web-gateway" ]; then
    echo "📍 Found slurm-web-gateway in /usr/local/bin/"
    SLURM_WEB_BINARY="/usr/local/bin/slurm-web-gateway"
  else
    echo "🔍 Searching for slurm-web-gateway binary..."
    find /home/vagrant /usr/local /usr -name "slurm-web-gateway" 2>/dev/null || true
    # Use which to find it in PATH
    SLURM_WEB_BINARY=$(which slurm-web-gateway 2>/dev/null || echo "/home/vagrant/.local/bin/slurm-web-gateway")
  fi
else
  SLURM_WEB_BINARY="/home/vagrant/.local/bin/slurm-web-gateway"
fi

echo "🎯 Using slurm-web binary: $SLURM_WEB_BINARY"

# Verify installation
echo "🔍 Verifying slurm-web installation..."
echo "Source directory contents:"
ls -la /home/vagrant/tmp/slurm-web/

echo "Python packages installed:"
pip3 list | grep -i slurm || echo "No slurm packages found in pip list"

echo "Binary locations:"
find /home/vagrant /usr/local /usr -name "*slurm*web*" 2>/dev/null || echo "No slurm-web binaries found"

# Test if we can import slurm-web
echo "Testing Python import:"
python3 -c "import slurmweb; print('slurm-web imported successfully')" 2>/dev/null || echo "Could not import slurmweb module"

# Create systemd service file - using the detected binary location
echo "⚙️ Creating systemd service..."
cat > /etc/systemd/system/slurm-web.service << EOF
[Unit]
Description=Slurm-Web - A web interface for Slurm
After=network.target

[Service]
Type=simple
User=vagrant
Group=vagrant
ExecStart=$SLURM_WEB_BINARY
Environment="PATH=/home/vagrant/.local/bin:/usr/local/bin:/usr/bin:/bin"
WorkingDirectory=/home/vagrant/tmp/slurm-web
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Enable and start the service
echo "🚀 Starting slurm-web service..."
systemctl daemon-reload
systemctl enable slurm-web.service
systemctl restart slurm-web.service

# Health check
echo "🔍 Waiting for slurm-web to initialize..."
max_wait=120
wait_time=0

while [ $wait_time -lt $max_wait ]; do
  echo "Checking slurm-web status... ($wait_time/$max_wait seconds)"
  
  # Check if service is active
  if systemctl is-active --quiet slurm-web.service; then
    echo "✅ Service is active"
    
    # Check if port is responding
    if curl --silent --fail --max-time 5 http://localhost:8081/ >/dev/null 2>&1; then
      echo "✅ slurm-web is responding on port 8081!"
      break
    else
      echo "⏳ Service is active but not responding on port 8081 yet..."
    fi
  else
    echo "⏳ Service is not active yet..."
  fi
  
  # Show detailed status every 30 seconds
  if [ $((wait_time % 30)) -eq 0 ]; then
    echo "--- Service status at $wait_time seconds ---"
    systemctl status slurm-web.service --no-pager || true
    
    echo "--- Recent logs ---"
    journalctl -u slurm-web.service --no-pager --lines=10 || true
    
    echo "--- Port status ---"
    netstat -tlnp | grep 8081 || echo "No process listening on port 8081"
    
    echo "--- Process status ---"
    ps aux | grep slurm-web-gateway | grep -v grep || echo "No slurm-web-gateway process found"
  fi
  
  sleep 10
  wait_time=$((wait_time + 10))
done

# Final verification
if [ $wait_time -ge $max_wait ]; then
  echo "❌ slurm-web failed to start within $max_wait seconds"
  echo "--- Final service status ---"
  systemctl status slurm-web.service --no-pager -l
  echo "--- Complete logs ---"
  journalctl -u slurm-web.service --no-pager
  exit 1
else
  echo "✅ slurm-web setup complete!"
  echo "🌐 Access slurm-web at: http://localhost:8081"
  
  # Add port forwarding info
  echo "📋 If using Vagrant, remember to forward port 8081 to access from host machine"
  echo "   Example: config.vm.network 'forwarded_port', guest: 8081, host: 8081"
fi