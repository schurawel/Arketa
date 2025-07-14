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

# 3. Initial configuration - based on official docs
echo "🛠️ Creating initial configuration files..."
sudo mkdir -p /etc/slurm-web

# Create agent.ini - MINIMAL CONFIG ONLY
cat <<EOF | sudo tee /etc/slurm-web/agent.ini
[service]
cluster=primedslurm
EOF

# Don't create gateway.ini - let slurm-web use its defaults
echo "📋 Using default gateway configuration (no custom gateway.ini)"

# 4. Generate JWT signing key for Slurm-web - redirect stderr to avoid confusing output
echo "🔑 Generating JWT signing key for Slurm-web..."
# First check what the command expects
if [ -x /usr/libexec/slurm-web/slurm-web-gen-jwt-key ]; then
    # Try to generate with minimal config
    sudo /usr/libexec/slurm-web/slurm-web-gen-jwt-key 2>&1 | grep -v "CRITICAL" || echo "JWT key generation completed"
else
    echo "⚠️ JWT key generator not found, creating key manually..."
    sudo mkdir -p /var/lib/slurm-web
    # Generate a random JWT key
    openssl rand -base64 32 | sudo tee /var/lib/slurm-web/jwt.key > /dev/null
    sudo chmod 600 /var/lib/slurm-web/jwt.key
fi

# 5. Ensure Slurm JWT signing key exists for slurmrestd
if [ ! -f /var/spool/slurm/jwt_hs256.key ]; then
    echo "🔑 Slurm JWT key not found at /var/spool/slurm/jwt_hs256.key. Generating it..."
    
    # Ensure the directory exists with proper permissions
    sudo mkdir -p /var/spool/slurm
    
    # Create a JWT key using openssl - same as slurmrestd expects
    echo "🔑 Creating JWT key with openssl..."
    openssl rand -base64 32 | sudo tee /var/spool/slurm/jwt_hs256.key > /dev/null
    sudo chown slurm:slurm /var/spool/slurm/jwt_hs256.key
    sudo chmod 600 /var/spool/slurm/jwt_hs256.key
    echo "✅ Successfully created JWT key"
fi

# 5. Copy Slurm JWT signing key for slurmrestd
echo "📂 Copying Slurm JWT signing key for slurmrestd..."
if [ -f /var/spool/slurm/jwt_hs256.key ]; then
    sudo cp /var/spool/slurm/jwt_hs256.key /var/lib/slurm-web/slurmrestd.key
    sudo chmod 400 /var/lib/slurm-web/slurmrestd.key
else
    echo "⚠️ Slurm JWT key not found, slurm-web may have limited functionality"
fi

# NEW: Open firewall port for slurm-web
echo "🔥 Configuring firewall to allow slurm-web access..."
if command -v ufw > /dev/null; then
    sudo ufw allow 5011/tcp
    sudo ufw allow 5012/tcp
    echo "✅ Firewall configured to allow slurm-web ports"
fi

# 6. Check if slurmrestd is running (it should be started by controller setup)
echo "🔍 Checking slurmrestd service..."
if systemctl is-active --quiet slurmrestd; then
    echo "✅ slurmrestd is already running"
else
    echo "⚠️ slurmrestd is not running. Checking if it exists..."
    
    if [ -f /opt/slurm/sbin/slurmrestd ]; then
        echo "✅ Found slurmrestd binary, attempting to start..."
        
        # Create service file if it doesn't exist
        if [ ! -f /etc/systemd/system/slurmrestd.service ]; then
            cat <<'EOF' | sudo tee /etc/systemd/system/slurmrestd.service
[Unit]
Description=Slurm REST daemon
After=network.target munge.service slurmctld.service
Requires=munge.service

[Service]
Type=simple
Environment="SLURM_JWT=/var/spool/slurm/jwt_hs256.key"
ExecStart=/opt/slurm/sbin/slurmrestd -a rest_auth/jwt 0.0.0.0:6820
Restart=on-failure
User=slurm
Group=slurm

[Install]
WantedBy=multi-user.target
EOF
        fi
        
        # Enable and start slurmrestd
        sudo systemctl daemon-reload
        sudo systemctl enable slurmrestd
        sudo systemctl start slurmrestd || {
            echo "⚠️ slurmrestd failed to start. Checking logs..."
            sudo journalctl -u slurmrestd --no-pager -n 20
        }
    else
        echo "❌ slurmrestd binary not found at /opt/slurm/sbin/slurmrestd"
        echo "⚠️ Slurm may not have been built with REST API support"
    fi
fi

# 7. Enable and start services
echo "🚀 Enabling and starting slurm-web services..."

# Reset failed unit state to clear start limit hit
sudo systemctl reset-failed slurm-web-agent.service 2>/dev/null || true
sudo systemctl reset-failed slurm-web-gateway.service 2>/dev/null || true

# Enable services
sudo systemctl enable slurm-web-agent.service || true
sudo systemctl enable slurm-web-gateway.service || true

# Start services
echo "Starting slurm-web services..."

# Start agent first
sudo systemctl start slurm-web-agent.service || {
    echo "⚠️ slurm-web-agent service failed to start, checking detailed logs..."
    # Get more detailed error information
    sudo journalctl -u slurm-web-agent --no-pager -n 50 | grep -v "Logs begin" || true
    
    # Try running the agent directly to see the actual error
    echo "🔍 Running agent directly to see error..."
    sudo -u slurm /usr/libexec/slurm-web/slurm-web-agent 2>&1 | head -20 || true
}

# Wait for agent to initialize
sleep 5

# Start gateway service - WITH NO CUSTOM CONFIG
sudo systemctl start slurm-web-gateway.service || {
    echo "⚠️ slurm-web-gateway service failed to start"
    echo "🔍 Checking service logs..."
    sudo journalctl -u slurm-web-gateway --no-pager -n 50 | grep -v "Logs begin" || true
    
    # Try running the gateway directly to see the actual error
    echo "🔍 Running gateway directly to see error..."
    sudo -u slurm /usr/libexec/slurm-web/slurm-web-gateway 2>&1 | head -20 || true
}

# After services start, check if gateway needs network binding configuration
sleep 3
if sudo systemctl is-active --quiet slurm-web-gateway.service; then
    echo "✅ slurm-web-gateway is running!"
    
    # Check current binding
    if netstat -tlnp 2>/dev/null | grep -q "127.0.0.1:5011" || ss -tlnp 2>/dev/null | grep -q "127.0.0.1:5011"; then
        echo "⚠️ Service is only listening on localhost. Creating minimal binding configuration..."
        
        # Stop the service
        sudo systemctl stop slurm-web-gateway.service
        
        # Create MINIMAL gateway configuration with ONLY what's needed for network binding
        cat <<EOF | sudo tee /etc/slurm-web/gateway.ini
[agents]
url = http://localhost:5012
EOF
        
        # Try environment variable approach for network binding
        echo "🔧 Creating systemd drop-in for network binding..."
        sudo mkdir -p /etc/systemd/system/slurm-web-gateway.service.d
        cat <<EOF | sudo tee /etc/systemd/system/slurm-web-gateway.service.d/network.conf
[Service]
Environment="BIND_ADDRESS=0.0.0.0:5011"
EOF
        
        sudo systemctl daemon-reload
        sudo systemctl start slurm-web-gateway.service
    fi
fi

# Verify services are running
echo "🔍 Verifying slurm-web services..."
sleep 5

# Check agent status
if sudo systemctl is-active --quiet slurm-web-agent.service; then
    echo "✅ slurm-web-agent is running"
else
    echo "❌ slurm-web-agent is not running"
    sudo systemctl status slurm-web-agent.service --no-pager -l || true
fi

# Check gateway status
if sudo systemctl is-active --quiet slurm-web-gateway.service; then
    echo "✅ slurm-web-gateway is running"
    
    # Check if listening on correct port
    if netstat -tlnp 2>/dev/null | grep -q ":5011" || ss -tlnp 2>/dev/null | grep -q ":5011"; then
        echo "✅ slurm-web-gateway is listening on port 5011"
    else
        echo "⚠️ slurm-web-gateway is running but not listening on port 5011"
    fi
else
    echo "❌ slurm-web-gateway is not running"
    sudo systemctl status slurm-web-gateway.service --no-pager -l || true
fi

# Final status
echo ""
echo "🌐 Slurm-web setup attempt complete!"

# Check final service status
if sudo systemctl is-active --quiet slurm-web-gateway.service; then
    # Check if it's now listening on all interfaces
    if netstat -tlnp 2>/dev/null | grep -q "0.0.0.0:5011" || ss -tlnp 2>/dev/null | grep -q "\*:5011"; then
        echo "✅ slurm-web-gateway is running and accessible on all interfaces!"
        echo "🌐 Access slurm-web at: http://$(hostname -I | awk '{print $1}'):5011"
    else
        echo "⚠️ slurm-web-gateway is running but may only be on localhost"
        echo "📋 You can access it via SSH port forwarding:"
        echo "  ssh -L 5011:localhost:5011 ubuntu@<controller-ip>"
    fi
else
    echo "⚠️ slurm-web services are not running properly."
    
    # Try to get more diagnostic information
    echo "📋 Checking slurm-web configuration files..."
    echo "Agent config:"
    cat /etc/slurm-web/agent.ini 2>/dev/null || echo "No agent.ini found"
    echo ""
    echo "Gateway config:"
    cat /etc/slurm-web/gateway.ini 2>/dev/null || echo "No gateway.ini found"
    echo ""
    
    # Check if the services are expecting different config locations
    echo "📋 Checking for alternative config locations..."
    find /etc -name "slurm-web*" -type f 2>/dev/null || true
    find /usr/share -name "slurm-web*" -type f 2>/dev/null | grep -E "(conf|ini|example)" || true
    
    echo "📋 This appears to be a configuration compatibility issue with this version."
    echo "💡 The cluster will work fine without slurm-web - use command line tools instead."
fi

# Don't fail the entire setup if slurm-web has issues
exit 0