#!/bin/bash
# Minimal slurm-web setup script - focused on fixing URL parameter issue

# Parse command line arguments
LINEAR_MODE=false
for arg in "$@"; do
    case $arg in
        --linear-setup)
            LINEAR_MODE=true
            echo "📋 Running in linear setup mode - skipping non-essential tests"
            ;;
    esac
done

set -e

echo "======================================================="
echo "  Slurm-web Installation (Source Build)                "
echo "======================================================="

echo "[1/7] Installing dependencies..."
sudo apt-get update
sudo apt-get install -y git python3-pip python3-venv build-essential curl

echo "[2/7] Installing Node.js using NVM to avoid package conflicts..."
# Install NVM (Node Version Manager)
export NVM_DIR="$HOME/.nvm"
if [ ! -d "$NVM_DIR" ]; then
    echo "Installing NVM..."
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.3/install.sh | bash
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
    [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion
    echo "NVM installed successfully"
else
    echo "NVM already installed, loading it..."
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
fi

# Make sure NVM is in the current environment
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm

# Install Node.js LTS version
nvm install --lts
nvm use --lts
echo "Node.js $(node -v) and npm $(npm -v) installed successfully"

echo "[3/7] Setting up directories..."
SLURM_WEB_DIR="/opt/slurm-web"
sudo mkdir -p $SLURM_WEB_DIR
sudo mkdir -p /etc/slurm-web
sudo mkdir -p /var/lib/slurm-web
sudo mkdir -p /var/log/slurm-web

echo "[4/7] Cloning slurm-web repository..."
export GIT_TERMINAL_PROMPT=0
if [ -d "$SLURM_WEB_DIR/.git" ]; then
    echo "Repository already exists, updating..."
    cd $SLURM_WEB_DIR
    sudo git pull
else
    echo "Cloning fresh repository..."
    sudo git clone https://github.com/rackslab/Slurm-web.git $SLURM_WEB_DIR
    cd $SLURM_WEB_DIR
fi

echo "[5/7] Setting up Python environment and installing backend..."
sudo python3 -m venv $SLURM_WEB_DIR/venv

# Install pip packages properly with error handling
echo "Installing agent package..."
if [ -f "$SLURM_WEB_DIR/python/agent/setup.py" ]; then
    # First try: Use regular pip install if setup.py exists
    sudo $SLURM_WEB_DIR/venv/bin/pip install $SLURM_WEB_DIR/python/agent || {
        echo "Standard install failed, trying alternative methods..."
        # Second try: Install requirements directly if requirements.txt exists
        if [ -f "$SLURM_WEB_DIR/python/agent/requirements.txt" ]; then
            sudo $SLURM_WEB_DIR/venv/bin/pip install -r $SLURM_WEB_DIR/python/agent/requirements.txt
        fi
        # Copy the agent module to site-packages manually if needed
        SITE_PACKAGES=$(sudo $SLURM_WEB_DIR/venv/bin/python -c "import site; print(site.getsitepackages()[0])")
        sudo mkdir -p $SITE_PACKAGES/slurm_web_agent
        sudo cp -r $SLURM_WEB_DIR/python/agent/slurm_web_agent/* $SITE_PACKAGES/slurm_web_agent/
    }
else
    echo "Warning: No setup.py found in agent directory. Trying direct installation..."
    # Try to find and install the agent package using a more basic method
    if [ -d "$SLURM_WEB_DIR/python/agent/slurm_web_agent" ]; then
        SITE_PACKAGES=$(sudo $SLURM_WEB_DIR/venv/bin/python -c "import site; print(site.getsitepackages()[0])")
        sudo mkdir -p $SITE_PACKAGES/slurm_web_agent
        sudo cp -r $SLURM_WEB_DIR/python/agent/slurm_web_agent/* $SITE_PACKAGES/slurm_web_agent/
        # Create an __init__.py file if it doesn't exist
        sudo touch $SITE_PACKAGES/slurm_web_agent/__init__.py
    fi
fi

echo "Installing gateway package..."
if [ -f "$SLURM_WEB_DIR/python/gateway/setup.py" ]; then
    # First try: Use regular pip install if setup.py exists
    sudo $SLURM_WEB_DIR/venv/bin/pip install $SLURM_WEB_DIR/python/gateway || {
        echo "Standard install failed, trying alternative methods..."
        # Second try: Install requirements directly if requirements.txt exists
        if [ -f "$SLURM_WEB_DIR/python/gateway/requirements.txt" ]; then
            sudo $SLURM_WEB_DIR/venv/bin/pip install -r $SLURM_WEB_DIR/python/gateway/requirements.txt
        fi
        # Copy the gateway module to site-packages manually if needed
        SITE_PACKAGES=$(sudo $SLURM_WEB_DIR/venv/bin/python -c "import site; print(site.getsitepackages()[0])")
        sudo mkdir -p $SITE_PACKAGES/slurm_web_gateway
        sudo cp -r $SLURM_WEB_DIR/python/gateway/slurm_web_gateway/* $SITE_PACKAGES/slurm_web_gateway/
    }
else
    echo "Warning: No setup.py found in gateway directory. Trying direct installation..."
    # Try to find and install the gateway package using a more basic method
    if [ -d "$SLURM_WEB_DIR/python/gateway/slurm_web_gateway" ]; then
        SITE_PACKAGES=$(sudo $SLURM_WEB_DIR/venv/bin/python -c "import site; print(site.getsitepackages()[0])")
        sudo mkdir -p $SITE_PACKAGES/slurm_web_gateway
        sudo cp -r $SLURM_WEB_DIR/python/gateway/slurm_web_gateway/* $SITE_PACKAGES/slurm_web_gateway/
        # Create an __init__.py file if it doesn't exist
        sudo touch $SITE_PACKAGES/slurm_web_gateway/__init__.py
    fi
fi

# Install any additional required packages
sudo $SLURM_WEB_DIR/venv/bin/pip install fastapi uvicorn pyjwt flask flask-restful

# Verify installation by checking for the entry point scripts
if [ ! -f "$SLURM_WEB_DIR/venv/bin/slurm-web-agent" ]; then
    echo "Creating slurm-web-agent entry point script..."
    cat > /tmp/slurm-web-agent << 'EOF'
#!/usr/bin/env python3
from slurm_web_agent.app import main

if __name__ == "__main__":
    main()
EOF
    sudo cp /tmp/slurm-web-agent $SLURM_WEB_DIR/venv/bin/slurm-web-agent
    sudo chmod +x $SLURM_WEB_DIR/venv/bin/slurm-web-agent
fi

if [ ! -f "$SLURM_WEB_DIR/venv/bin/slurm-web-gateway" ]; then
    echo "Creating slurm-web-gateway entry point script..."
    cat > /tmp/slurm-web-gateway << 'EOF'
#!/usr/bin/env python3
from slurm_web_gateway.app import main

if __name__ == "__main__":
    main()
EOF
    sudo cp /tmp/slurm-web-gateway $SLURM_WEB_DIR/venv/bin/slurm-web-gateway
    sudo chmod +x $SLURM_WEB_DIR/venv/bin/slurm-web-gateway
fi

echo "[6/7] Building frontend..."
cd $SLURM_WEB_DIR/dashboard
# Give current user ownership of the directory temporarily
sudo chown -R $(whoami):$(whoami) .

# Use the NVM-installed Node.js and npm
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
nvm use --lts

# Install dependencies and build
npm install
npm run build

# Restore ownership
sudo chown -R root:root .

echo "[7/7] Setting up JWT authentication..."
sudo dd if=/dev/urandom bs=32 count=1 of=/var/lib/slurm-web/jwt.key
sudo chmod 400 /var/lib/slurm-web/jwt.key

# Try to copy the slurmrestd JWT key if it exists
if [ -f "/var/spool/slurm/jwt_hs256.key" ]; then
    sudo cp /var/spool/slurm/jwt_hs256.key /var/lib/slurm-web/slurmrestd.key
    sudo chmod 400 /var/lib/slurm-web/slurmrestd.key
else
    echo "WARNING: slurmrestd JWT key not found, creating a new one"
    sudo dd if=/dev/urandom bs=32 count=1 of=/var/lib/slurm-web/slurmrestd.key
    sudo chmod 400 /var/lib/slurm-web/slurmrestd.key
fi

echo "Creating configuration files..."
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
sudo cp /tmp/agent.ini /etc/slurm-web/agent.ini

# Gateway configuration
cat > /tmp/gateway.ini << 'EOF'
[service]
interface=0.0.0.0
port=5011

[agents]
url=http://localhost:5012

[authentication]
enabled=no

[static]
path=/opt/slurm-web/dashboard/dist
EOF
sudo cp /tmp/gateway.ini /etc/slurm-web/gateway.ini

# Policy configuration
cat > /tmp/policy.ini << 'EOF'
[roles]
anonymous

[anonymous]
actions=view-stats,view-jobs,view-nodes,view-partitions,view-qos,view-accounts,view-reservations,cache-view
EOF
sudo cp /tmp/policy.ini /etc/slurm-web/policy.ini

# Create systemd service files
echo "Creating systemd service files..."

# Agent service
cat > /tmp/slurm-web-agent.service << EOF
[Unit]
Description=Slurm-web Agent Service
After=network.target slurmrestd.service
Requires=slurmrestd.service

[Service]
Type=simple
ExecStart=$SLURM_WEB_DIR/venv/bin/slurm-web-agent -c /etc/slurm-web/agent.ini
Restart=on-failure
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
sudo cp /tmp/slurm-web-agent.service /etc/systemd/system/

# Gateway service
cat > /tmp/slurm-web-gateway.service << EOF
[Unit]
Description=Slurm-web Gateway Service
After=network.target slurm-web-agent.service
Requires=slurm-web-agent.service

[Service]
Type=simple
ExecStart=$SLURM_WEB_DIR/venv/bin/slurm-web-gateway -c /etc/slurm-web/gateway.ini
Restart=on-failure
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
sudo cp /tmp/slurm-web-gateway.service /etc/systemd/system/

echo "Starting services..."
sudo systemctl daemon-reload
sudo systemctl enable slurm-web-agent
sudo systemctl enable slurm-web-gateway

# Make sure slurmrestd is running first
echo "Ensuring slurmrestd is running..."
sudo systemctl restart slurmrestd
sleep 3

# Start the agent and gateway services
sudo systemctl restart slurm-web-agent
sleep 3
sudo systemctl restart slurm-web-gateway

# Final verification - skip in linear mode
if [ "$LINEAR_MODE" != "true" ]; then
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
fi

echo ""
echo "Installation complete! Access Slurm-web at: http://$(hostname -I | awk '{print $1}'):5011"
echo ""
