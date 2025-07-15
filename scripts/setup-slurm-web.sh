#!/bin/bash
# setup-slurm-web.sh - Automated Slurm-web setup for Ubuntu 24.04 LTS (Noble Numbat)
set -e

echo "🌐 Setting up slurm-web - Official Quickstart Configuration"

# Source the apt lock utility functions if available
if [ -f "$(dirname "$0")/wait-for-apt.sh" ]; then
    source "$(dirname "$0")/wait-for-apt.sh"
else
    echo "WARNING: wait-for-apt.sh not found. Continuing without lock checking."
    # Define a minimal fallback function
    wait_for_apt_locks() {
        echo "⚠️ Skipping apt lock check (utility script not found)"
        return 0
    }
fi

# 1. Add Rackslab APT repository and key for Ubuntu 24.04
echo "🔑 Adding Rackslab APT repository..."
wait_for_apt_locks 600 || {
    echo "ERROR: Could not acquire apt locks after waiting. Please try again later."
    exit 1
}
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

# Verify packages were installed correctly
if ! dpkg -s slurm-web-agent &>/dev/null || ! dpkg -s slurm-web-gateway &>/dev/null; then
    echo "❌ Failed to install slurm-web packages. Check repository configuration."
    echo "📋 Available packages:"
    apt-cache search slurm-web
    exit 1
fi

# 2a. Ensure slurm-web system user exists (should be created by packages)
if ! id slurm-web &>/dev/null; then
    echo "Creating slurm-web system user..."
    sudo useradd --system --no-create-home --shell /bin/false slurm-web
else
    echo "✅ slurm-web user already exists"
fi

# 3. Setup JWT key for slurmrestd authentication
echo "🔑 Setting up JWT authentication..."

# Ensure slurm-web data directory exists
sudo mkdir -p /var/lib/slurm-web
sudo chown slurm:slurm /var/lib/slurm-web

# Create JWT key for slurmrestd if it doesn't exist (OFFICIAL METHOD)
if [ ! -f "/var/spool/slurm/jwt_hs256.key" ]; then
    echo "Creating JWT key for slurmrestd using official method..."
    sudo mkdir -p /var/spool/slurm
    sudo dd if=/dev/random of=/var/spool/slurm/jwt_hs256.key bs=32 count=1
    sudo chown slurm:slurm /var/spool/slurm/jwt_hs256.key
    sudo chmod 0600 /var/spool/slurm/jwt_hs256.key
    
    # Restart slurmrestd to use new key
    echo "Restarting slurmrestd to use new JWT key..."
    sudo systemctl restart slurmrestd || echo "⚠️ Could not restart slurmrestd"
    
    # Wait for slurmrestd to start
    sleep 5
    
    # Check if slurmrestd is running
    if sudo systemctl is-active --quiet slurmrestd; then
        echo "✅ slurmrestd is running with JWT authentication"
    else
        echo "❌ slurmrestd failed to start"
        sudo systemctl status slurmrestd --no-pager || true
    fi
else
    echo "✅ JWT key for slurmrestd already exists"
fi

# Setup slurmrestd with Unix socket (OFFICIAL QUICKSTART METHOD)
echo "🔧 Configuring slurmrestd with Unix socket..."
sudo mkdir -p /etc/systemd/system/slurmrestd.service.d
sudo tee /etc/systemd/system/slurmrestd.service.d/slurm-web.conf > /dev/null << 'EOF'
[Service]
# Unset vendor unit ExecStart and Environment to avoid cumulative definition
ExecStart=
Environment=
Environment="SLURM_JWT=daemon"
ExecStart=/opt/slurm/sbin/slurmrestd -a rest_auth/jwt unix:/run/slurmrestd/slurmrestd.socket
RuntimeDirectory=slurmrestd
RuntimeDirectoryMode=0755
User=slurm
Group=slurm
EOF

# Generate slurm-web JWT signing key using official tool
echo "🔑 Generating slurm-web JWT signing key..."
if [ ! -f "/var/lib/slurm-web/jwt.key" ]; then
    sudo /usr/libexec/slurm-web/slurm-web-gen-jwt-key || {
        echo "❌ Failed to generate JWT key, creating manually..."
        sudo dd if=/dev/urandom bs=32 count=1 of=/var/lib/slurm-web/jwt.key
        sudo chown slurm-web:slurm-web /var/lib/slurm-web/jwt.key
        sudo chmod 400 /var/lib/slurm-web/jwt.key
    }
else
    echo "✅ slurm-web JWT key already exists"
fi

# Copy Slurm JWT key for slurm-web agent (OFFICIAL METHOD)
echo "🔑 Setting up slurm-web slurmrestd key..."
sudo cp /var/spool/slurm/jwt_hs256.key /var/lib/slurm-web/slurmrestd.key
sudo chown slurm-web:slurm-web /var/lib/slurm-web/slurmrestd.key
sudo chmod 400 /var/lib/slurm-web/slurmrestd.key

# Ensure proper ownership of slurm-web directory
sudo chown -R slurm-web:slurm-web /var/lib/slurm-web

# 3a. Configure JWT authentication in Slurm
echo "🔧 Configuring JWT authentication in Slurm..."
if ! grep -q "AuthAltTypes=auth/jwt" /etc/slurm/slurm.conf; then
    echo "Adding JWT authentication to slurm.conf..."
    sudo cp /etc/slurm/slurm.conf /etc/slurm/slurm.conf.backup
    sudo sed -i '/^AuthType=auth\/munge/a AuthAltTypes=auth/jwt\nAuthAltParameters=jwt_key=/var/spool/slurm/jwt_hs256.key' /etc/slurm/slurm.conf
    
    echo "Restarting Slurm services to apply JWT configuration..."
    sudo systemctl daemon-reload
    sudo systemctl restart slurmctld slurmrestd || echo "⚠️ Could not restart Slurm services"
    sleep 5
    
    # Verify JWT token generation works
    if sudo -u slurm /opt/slurm/bin/scontrol token > /dev/null 2>&1; then
        echo "✅ JWT authentication configured successfully"
    else
        echo "❌ JWT authentication configuration failed"
    fi
else
    echo "✅ JWT authentication already configured in slurm.conf"
fi

# 4. Configure slurm-web agent with OFFICIAL QUICKSTART settings
# FIXED: using socket parameter instead of unix
echo "⚙️ Configuring slurm-web agent..."
sudo tee /etc/slurm-web/agent.ini > /dev/null << 'EOF'
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

# 5. Configure slurm-web gateway with OFFICIAL QUICKSTART settings
echo "⚙️ Configuring slurm-web gateway..."
sudo tee /etc/slurm-web/gateway.ini > /dev/null << 'EOF'
[service]
interface=0.0.0.0
port=5011

[agents]
url=http://localhost:5012

[authentication]
enabled=no
EOF

# 5a. Create anonymous access policy
echo "⚙️ Configuring anonymous access policy..."
sudo mkdir -p /etc/slurm-web
sudo tee /etc/slurm-web/policy.ini > /dev/null << 'EOF'
# Custom Slurm-web RBAC policy for anonymous access

[roles]
# Enable anonymous role with full access for testing
anonymous

[anonymous]
actions=view-stats,view-jobs,view-nodes,view-partitions,view-qos,view-accounts,view-reservations,cache-view
EOF

# 6. Remove custom systemd service overrides - use default services
echo "🔧 Removing any custom systemd service overrides..."
if [ -d /etc/systemd/system/slurm-web-agent.service.d ]; then
    sudo rm -rf /etc/systemd/system/slurm-web-agent.service.d
fi
if [ -d /etc/systemd/system/slurm-web-gateway.service.d ]; then
    sudo rm -rf /etc/systemd/system/slurm-web-gateway.service.d
fi

# 6a. Check that systemd service files exist
if [ ! -f /lib/systemd/system/slurm-web-agent.service ]; then
    echo "❌ slurm-web-agent.service file not found. Installation may be incomplete."
    sudo find /lib/systemd/system -name "*slurm*" || true
    echo "Attempting to reinstall packages..."
    sudo apt-get install --reinstall slurm-web-agent slurm-web-gateway
fi

# Reload systemd to pick up changes
sudo systemctl daemon-reload

# 7. Validate configuration files before starting services
echo "🔍 Validating configuration files..."

# Check if configuration files exist and are readable
config_files=(
    "/etc/slurm-web/agent.ini"
    "/etc/slurm-web/gateway.ini"
    "/var/lib/slurm-web/jwt.key"
    "/var/lib/slurm-web/slurmrestd.key"
)

for file in "${config_files[@]}"; do
    if [ ! -f "$file" ]; then
        echo "❌ Configuration file missing: $file"
        exit 1
    else
        echo "✅ Configuration file exists: $file"
    fi
done

# Validate configuration syntax
echo "🔍 Validating configuration syntax..."
echo "Agent configuration:"
sudo cat /etc/slurm-web/agent.ini | grep -E "^\[|^[a-zA-Z]" | head -10

echo "Gateway configuration:"
sudo cat /etc/slurm-web/gateway.ini | grep -E "^\[|^[a-zA-Z]" | head -10

# 8. Verify slurm-web packages provide expected files
echo "🔍 Verifying slurm-web package files..."
for cmd in slurm-web-agent slurm-web-gateway; do
    if ! which $cmd &>/dev/null; then
        echo "❌ $cmd command not found. Installation may be incomplete."
        echo "📋 Listing installed files from package:"
        dpkg -L $(dpkg -S $cmd 2>/dev/null | cut -d: -f1) 2>/dev/null || echo "Package not found"
    else
        echo "✅ $cmd command found at $(which $cmd)"
    fi
done

# 9. Enable and start services using OFFICIAL METHOD
echo "🚀 Starting slurm-web services..."

# Ensure slurmrestd is running first
echo "Checking slurmrestd status..."
if ! sudo systemctl is-active --quiet slurmrestd; then
    echo "⚠️ slurmrestd is not running. Attempting to start it..."
    sudo systemctl start slurmrestd || echo "❌ Failed to start slurmrestd"
    sleep 5
fi

# Start agent first, then gateway
echo "Starting slurm-web-agent service..."
sudo systemctl enable slurm-web-agent.service
sudo systemctl restart slurm-web-agent.service || {
    echo "❌ Failed to start slurm-web-agent. Checking status..."
    sudo systemctl status slurm-web-agent.service --no-pager || true
    echo "📋 Agent logs:"
    sudo journalctl -u slurm-web-agent.service --no-pager -n 20 || true
}

sleep 5

# Wait for agent to be ready before starting gateway
echo "Testing agent readiness before starting gateway..."
for i in {1..5}; do
    if curl -s -f http://localhost:5012/ &>/dev/null; then
        echo "✅ Agent is responding on port 5012"
        break
    fi
    if [ $i -eq 5 ]; then
        echo "⚠️ Agent is not responding after 5 attempts"
    else
        echo "⏳ Waiting for agent to start (attempt $i/5)..."
        sleep 5
    fi
done

echo "Starting slurm-web-gateway service..."
sudo systemctl enable slurm-web-gateway.service
sudo systemctl restart slurm-web-gateway.service || {
    echo "❌ Failed to start slurm-web-gateway. Checking status..."
    sudo systemctl status slurm-web-gateway.service --no-pager || true
    echo "📋 Gateway logs:"
    sudo journalctl -u slurm-web-gateway.service --no-pager -n 20 || true
}

sleep 3

# Verify gateway can reach agent with explicit config check
echo "🔌 Verifying gateway configuration..."
if grep -q "url=http://0.0.0.0:5012" /etc/slurm-web/gateway.ini; then
    echo "⚠️ Found potential issue: agent URL using 0.0.0.0 instead of localhost"
    echo "🔧 Fixing gateway configuration..."
    sudo sed -i 's|url=http://0.0.0.0:5012|url=http://localhost:5012|g' /etc/slurm-web/gateway.ini
    sudo systemctl restart slurm-web-gateway
    sleep 2
fi

# 10. Final status check
echo ""
echo "📊 Service Status Summary:"
echo "========================="

# Check services
for service in slurm-web-agent slurm-web-gateway; do
    if sudo systemctl is-active --quiet $service; then
        echo "✅ $service: Running"
    else
        echo "❌ $service: Not running"
        sudo systemctl status $service --no-pager || true
    fi
done

# Check ports
echo ""
echo "🔌 Port Status:"
echo "==============="
if sudo lsof -i :5011 > /dev/null 2>&1; then
    echo "✅ Port 5011 (gateway): Listening"
else
    echo "❌ Port 5011 (gateway): Not listening"
    echo "📋 Process using port 5011 (if any):"
    sudo ss -tulpn | grep 5011 || echo "No process using port 5011"
fi

if sudo lsof -i :5012 > /dev/null 2>&1; then
    echo "✅ Port 5012 (agent): Listening"
else
    echo "❌ Port 5012 (agent): Not listening"
    echo "📋 Process using port 5012 (if any):"
    sudo ss -tulpn | grep 5012 || echo "No process using port 5012"
fi

# Test connectivity
echo ""
echo "🔗 Connectivity Tests:"
echo "======================"

# Test slurmrestd socket
if [ -S "/run/slurmrestd/slurmrestd.socket" ]; then
    echo "✅ slurmrestd Unix socket: Exists"
    # Test JWT token generation
    if sudo -u slurm /opt/slurm/bin/scontrol token > /dev/null 2>&1; then
        echo "✅ JWT token generation: Working"
    else
        echo "❌ JWT token generation: Failed"
    fi
else
    echo "❌ slurmrestd Unix socket: Missing"
    echo "📋 Debug: Checking /run/slurmrestd/"
    sudo ls -la /run/slurmrestd/ 2>/dev/null || echo "Directory does not exist"
fi

# Test gateway
echo "Testing gateway connectivity..."
if curl -s -f http://localhost:5011/ > /dev/null 2>&1; then
    echo "✅ Gateway HTTP endpoint: Accessible"
else
    echo "❌ Gateway HTTP endpoint: Not accessible"
    echo "📋 Debug: Testing with verbose curl..."
    curl -v http://localhost:5011/ 2>&1 | head -10 || true
fi

# If services failed, attempt a last-ditch fix
if ! sudo systemctl is-active --quiet slurm-web-agent || ! sudo systemctl is-active --quiet slurm-web-gateway; then
    echo ""
    echo "🔧 Attempting last-ditch fix for failed services..."
    
    # Check Python modules
    echo "Checking Python modules for slurm-web..."
    sudo apt-get install -y python3-pip
    
    # Try manual agent start with debug output
    echo "Trying manual agent start with debug..."
    sudo slurm-web-agent -c /etc/slurm-web/agent.ini -v || echo "Manual agent start failed"
    
    # Try restart services with debug output
    sudo systemctl restart slurm-web-agent
    sudo systemctl restart slurm-web-gateway
    
    sleep 5
    
    # Final check
    for service in slurm-web-agent slurm-web-gateway; do
        if sudo systemctl is-active --quiet $service; then
            echo "✅ $service: Running after fix"
        else
            echo "❌ $service: Still not running after fix"
        fi
    done
fi

echo ""
echo "🎯 Final Setup Results:"
echo "======================="

if sudo systemctl is-active --quiet slurm-web-agent && sudo systemctl is-active --quiet slurm-web-gateway; then
    echo "✅ Slurm-web installation completed successfully!"
    echo ""
    echo "📱 Access Information:"
    echo "Web Interface: http://$(hostname -I | awk '{print $1}'):5011"
    echo "Local Access:  http://localhost:5011"
    echo ""
    echo "🔧 Troubleshooting Commands:"
    echo "sudo systemctl status slurm-web-agent slurm-web-gateway"
    echo "sudo journalctl -u slurm-web-agent -u slurm-web-gateway -f"
    echo ""
    echo "🔄 To restart services:"
    echo "sudo systemctl restart slurm-web-agent slurm-web-gateway"
else
    echo "❌ Slurm-web installation had issues. Check the logs above."
    echo ""
    echo "🔍 Debug commands:"
    echo "sudo journalctl -u slurm-web-agent --no-pager -n 20"
    echo "sudo journalctl -u slurm-web-gateway --no-pager -n 20"
    echo "sudo journalctl -u slurmrestd --no-pager -n 20"
    echo "sudo lsof -i :5011"
    echo "sudo lsof -i :5012"
    echo "sudo ls -la /run/slurmrestd/"
    echo "sudo systemctl status slurm-web-agent slurm-web-gateway slurmrestd"
    echo ""
    echo "📋 Recent agent logs:"
    sudo journalctl -u slurm-web-agent --no-pager -n 10 | tail -5 || true
    echo ""
    echo "📋 Recent gateway logs:"  
    sudo journalctl -u slurm-web-gateway --no-pager -n 10 | tail -5 || true
    echo ""
    echo "📋 Recent slurmrestd logs:"
    sudo journalctl -u slurmrestd --no-pager -n 10 | tail -5 || true
fi

echo ""
echo "🏁 Setup script completed!"