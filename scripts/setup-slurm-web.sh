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

# 3. Check where configuration files should go
echo "🔍 Detecting slurm-web configuration locations..."

# Check if the package installed config files in /usr/share location
if [ -f "/usr/share/slurm-web/wsgi/agent/slurm-web-agent.ini" ]; then
    AGENT_CONFIG="/usr/share/slurm-web/wsgi/agent/slurm-web-agent.ini"
    echo "✅ Found agent config at: $AGENT_CONFIG"
else
    AGENT_CONFIG="/etc/slurm-web/agent.ini"
    sudo mkdir -p /etc/slurm-web
    echo "📋 Using standard agent config location: $AGENT_CONFIG"
fi

if [ -f "/usr/share/slurm-web/wsgi/gateway/slurm-web-gateway.ini" ]; then
    GATEWAY_CONFIG="/usr/share/slurm-web/wsgi/gateway/slurm-web-gateway.ini"
    echo "✅ Found gateway config at: $GATEWAY_CONFIG"
else
    GATEWAY_CONFIG="/etc/slurm-web/gateway.ini"
    sudo mkdir -p /etc/slurm-web
    echo "📋 Using standard gateway config location: $GATEWAY_CONFIG"
fi

# 4. Configure agent - MINIMAL configuration
echo "🛠️ Configuring slurm-web agent..."

# Backup existing config if it exists
if [ -f "$AGENT_CONFIG" ]; then
    sudo cp "$AGENT_CONFIG" "${AGENT_CONFIG}.backup"
fi

# Create minimal agent configuration - slurm-web v5 expects different format
cat <<EOF | sudo tee "$AGENT_CONFIG"
[service]
cluster = primedslurm

[slurm]
# Explicitly set paths to Slurm binaries
sinfo = /opt/slurm/bin/sinfo
scontrol = /opt/slurm/bin/scontrol
sacct = /opt/slurm/bin/sacct
squeue = /opt/slurm/bin/squeue
EOF

# 5. Configure gateway - MINIMAL configuration
echo "🛠️ Configuring slurm-web gateway..."

# Backup existing config if it exists  
if [ -f "$GATEWAY_CONFIG" ]; then
    sudo cp "$GATEWAY_CONFIG" "${GATEWAY_CONFIG}.backup"
fi

# Create minimal gateway configuration
cat <<EOF | sudo tee "$GATEWAY_CONFIG"
[server]
host = 0.0.0.0
port = 5011

[agents]
primedslurm = http://localhost:5012
EOF

# 6. Set proper permissions
echo "🔒 Setting proper permissions..."
sudo chown root:root "$AGENT_CONFIG" "$GATEWAY_CONFIG"
sudo chmod 644 "$AGENT_CONFIG" "$GATEWAY_CONFIG"

# 7. Create proper systemd drop-ins with correct user
echo "🔧 Creating systemd service overrides..."

# Create systemd drop-in directories
sudo mkdir -p /etc/systemd/system/slurm-web-agent.service.d
sudo mkdir -p /etc/systemd/system/slurm-web-gateway.service.d

# Override agent service to run as slurm user with proper environment
cat <<EOF | sudo tee /etc/systemd/system/slurm-web-agent.service.d/override.conf
[Service]
User=slurm
Group=slurm
Environment="PATH=/opt/slurm/bin:/opt/slurm/sbin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="PYTHONPATH=/usr/lib/python3/dist-packages"
Environment="SLURM_CONF=/etc/slurm/slurm.conf"
WorkingDirectory=/usr/share/slurm-web/wsgi/agent
ExecStart=
ExecStart=/usr/bin/python3 /usr/libexec/slurm-web/slurm-web-agent
EOF

# Override gateway service with proper environment
cat <<EOF | sudo tee /etc/systemd/system/slurm-web-gateway.service.d/override.conf
[Service]
User=slurm
Group=slurm
Environment="PATH=/opt/slurm/bin:/opt/slurm/sbin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="PYTHONPATH=/usr/lib/python3/dist-packages"
WorkingDirectory=/usr/share/slurm-web/wsgi/gateway
ExecStart=
ExecStart=/usr/bin/python3 /usr/libexec/slurm-web/slurm-web-gateway
EOF

# 8. Ensure slurm user can access required files
echo "🔧 Setting up permissions for slurm user..."
sudo chown -R slurm:slurm /var/lib/slurm-web 2>/dev/null || sudo mkdir -p /var/lib/slurm-web && sudo chown -R slurm:slurm /var/lib/slurm-web

# 9. Test Slurm command accessibility
echo "🔍 Testing Slurm command accessibility..."
if sudo -u slurm /opt/slurm/bin/sinfo --version >/dev/null 2>&1; then
    echo "✅ Slurm commands are accessible to slurm user"
else
    echo "❌ Slurm commands not accessible. Setting up wrapper scripts..."
    
    # Create wrapper scripts if needed
    sudo mkdir -p /usr/local/bin
    for cmd in sinfo scontrol sacct squeue; do
        cat <<EOF | sudo tee /usr/local/bin/$cmd
#!/bin/bash
exec /opt/slurm/bin/$cmd "\$@"
EOF
        sudo chmod +x /usr/local/bin/$cmd
    done
fi

# 10. Configure firewall
echo "🔥 Configuring firewall to allow slurm-web access..."
if command -v ufw > /dev/null && sudo ufw status | grep -q "Status: active"; then
    sudo ufw allow 5011/tcp
    sudo ufw allow 5012/tcp
    echo "✅ Firewall rules added"
else
    echo "⚠️ UFW is not active. Checking iptables..."
    # Add iptables rules if needed
    sudo iptables -I INPUT -p tcp --dport 5011 -j ACCEPT 2>/dev/null || true
    sudo iptables -I INPUT -p tcp --dport 5012 -j ACCEPT 2>/dev/null || true
fi

# 11. Enable and start services
echo "🚀 Enabling and starting slurm-web services..."

# Reload systemd to pick up changes
sudo systemctl daemon-reload

# Reset failed unit states
sudo systemctl reset-failed slurm-web-agent.service 2>/dev/null || true
sudo systemctl reset-failed slurm-web-gateway.service 2>/dev/null || true

# Enable services
sudo systemctl enable slurm-web-agent.service || true
sudo systemctl enable slurm-web-gateway.service || true

# Start agent first
echo "Starting slurm-web-agent..."
sudo systemctl start slurm-web-agent.service || {
    echo "⚠️ slurm-web-agent failed to start. Checking detailed logs..."
    echo "=== Journal logs ==="
    sudo journalctl -u slurm-web-agent --no-pager -n 50
    
    echo "=== Trying manual run for debugging ==="
    cd /usr/share/slurm-web/wsgi/agent
    sudo -u slurm python3 /usr/libexec/slurm-web/slurm-web-agent --help 2>&1 || true
    
    echo "=== Checking Python imports ==="
    sudo -u slurm python3 -c "import sys; print('Python path:', sys.path)" || true
}

# Wait a moment
sleep 3

# Start gateway
echo "Starting slurm-web-gateway..."
sudo systemctl start slurm-web-gateway.service || {
    echo "⚠️ slurm-web-gateway failed to start. Checking detailed logs..."
    echo "=== Journal logs ==="
    sudo journalctl -u slurm-web-gateway --no-pager -n 50
}

# 12. Verify services
sleep 5
echo "🔍 Verifying slurm-web services..."

if sudo systemctl is-active --quiet slurm-web-agent.service; then
    echo "✅ slurm-web-agent is running"
else
    echo "❌ slurm-web-agent is not running"
    sudo systemctl status slurm-web-agent.service --no-pager || true
fi

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
    sudo systemctl status slurm-web-gateway.service --no-pager || true
fi

# Final status
echo ""
echo "🌐 Slurm-web setup attempt complete!"

if sudo systemctl is-active --quiet slurm-web-gateway.service && sudo systemctl is-active --quiet slurm-web-agent.service; then
    echo "✅ Both slurm-web services are running!"
    echo "🌐 Access slurm-web at: http://$(hostname -I | awk '{print $1}'):5011"
else
    echo "⚠️ Slurm-web services are having issues."
    echo ""
    echo "📋 Configuration locations:"
    echo "  Agent config: $AGENT_CONFIG"
    echo "  Gateway config: $GATEWAY_CONFIG"
    echo ""
    echo "💡 To debug further:"
    echo "  sudo journalctl -u slurm-web-agent -f"
    echo "  sudo journalctl -u slurm-web-gateway -f"
    echo ""
    echo "💡 The cluster will work fine without slurm-web - use command line tools instead."
fi

# Don't fail the entire setup
exit 0