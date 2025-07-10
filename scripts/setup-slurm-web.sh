#!/bin/bash
# setup-slurm-web.sh - Automated Slurm-web setup for Ubuntu 24.04 LTS (Noble Numbat)
set -e

echo "🌐 Setting up slurm-web - Official Quickstart Configuration"

# 1. Add Rackslab APT repository and key for Ubuntu 24.04
echo "🔑 Adding Rackslab APT repository..."
sudo apt-get update
sudo apt-get install -y curl gpg
curl -sS https://pkgs.rackslab.io/keyring.asc | gpg --dearmor | sudo tee /usr/share/keyrings/rackslab.gpg > /dev/null

cat <<EOF | sudo tee /etc/apt/sources.list.d/rackslab.sources
Types: deb
URIs: https://pkgs.rackslab.io/deb
Suites: ubuntu24.04
Components: main slurmweb-5
Architectures: amd64
Signed-By: /usr/share/keyrings/rackslab.gpg
EOF

sudo apt-get update

# 2. Install Slurm-web agent and gateway
echo "📦 Installing slurm-web agent and gateway..."
sudo apt-get install -y slurm-web-agent slurm-web-gateway

# 3. Initial configuration
echo "🛠️ Creating initial configuration files..."
sudo mkdir -p /etc/slurm-web
cat <<EOF | sudo tee /etc/slurm-web/agent.ini
[service]
cluster=primedslurm
EOF

cat <<EOF | sudo tee /etc/slurm-web/gateway.ini
[agents]
url=http://localhost:5012
EOF

# 4. Generate JWT signing key for Slurm-web
echo "🔑 Generating JWT signing key for Slurm-web..."
sudo /usr/libexec/slurm-web/slurm-web-gen-jwt-key

# 5. Ensure Slurm JWT signing key exists for slurmrestd
if [ ! -f /var/spool/slurm/jwt_hs256.key ]; then
  echo "🔑 Slurm JWT key not found at /var/spool/slurm/jwt_hs256.key. Generating it..."
  
  # Ensure the directory exists with proper permissions
  sudo mkdir -p /var/spool/slurm
  sudo chown slurm:slurm /var/spool/slurm
  sudo chmod 700 /var/spool/slurm
  
  # Use direct path to Slurm libraries
  SLURM_LIB_PATH="/opt/slurm/lib"
  
  # Create the key directly with openssl
  echo "🔑 Creating JWT key with openssl..."
  sudo -u slurm bash -c 'umask 077; openssl rand -base64 32 > /var/spool/slurm/jwt_hs256.key'
  
  # Verify the key was created
  if [ -f /var/spool/slurm/jwt_hs256.key ]; then
    echo "✅ Successfully created JWT key"
  else
    echo "❌ Failed to create JWT key as slurm user - trying with sudo"
    sudo bash -c 'umask 077; openssl rand -base64 32 > /var/spool/slurm/jwt_hs256.key'
    sudo chown slurm:slurm /var/spool/slurm/jwt_hs256.key
    sudo chmod 600 /var/spool/slurm/jwt_hs256.key
  fi
fi

# 5. Copy Slurm JWT signing key for slurmrestd
echo "📂 Copying Slurm JWT signing key for slurmrestd..."
if [ -f /var/spool/slurm/jwt_hs256.key ]; then
  sudo cp /var/spool/slurm/jwt_hs256.key /var/lib/slurm-web/slurmrestd.key
  sudo chown slurm-web:slurm-web /var/lib/slurm-web/slurmrestd.key
  sudo chmod 400 /var/lib/slurm-web/slurmrestd.key
else
  echo "❌ Slurm JWT key could not be generated at /var/spool/slurm/jwt_hs256.key. Please check your Slurm installation and permissions."
  exit 1
fi

# 6. Enable and start services
echo "🚀 Enabling and starting slurm-web services..."
sudo systemctl enable --now slurm-web-agent.service
sudo systemctl enable --now slurm-web-gateway.service

# 7. Print access info
echo "✅ Slurm-web setup complete!"
echo "🌐 Access Slurm-web at: http://localhost:5011"

# Health check
echo "🔍 Waiting for slurm-web to initialize..."
max_wait=120
wait_time=0

while [ $wait_time -lt $max_wait ]; do
  echo "Checking slurm-web status... ($wait_time/$max_wait seconds)"
  
  # Check if service is active
  if systemctl is-active --quiet slurm-web-gateway.service; then
    echo "✅ Service is active"
    
    # Check if port is responding
    if curl --silent --fail --max-time 5 http://localhost:5011/ >/dev/null 2>&1; then
      echo "✅ slurm-web is responding on port 5011!"
      break
    else
      echo "⏳ Service is active but not responding on port 5011 yet..."
    fi
  else
    echo "⏳ Service is not active yet..."
  fi
  
  # Show detailed status every 30 seconds
  if [ $((wait_time % 30)) -eq 0 ]; then
    echo "--- Service status at $wait_time seconds ---"
    systemctl status slurm-web-gateway.service --no-pager || true
    
    echo "--- Recent logs ---"
    journalctl -u slurm-web-gateway.service --no-pager --lines=10 || true
    
    echo "--- Port status ---"
    netstat -tlnp | grep 5011 || echo "No process listening on port 5011"
    
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
  systemctl status slurm-web-gateway.service --no-pager -l
  echo "--- Complete logs ---"
  journalctl -u slurm-web-gateway.service --no-pager
  exit 1
else
  echo "✅ slurm-web setup complete!"
  echo "🌐 Access slurm-web at: http://localhost:5011"
fi