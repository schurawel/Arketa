#!/bin/bash
# setup-ondemand.sh - Automated Open OnDemand setup (official system package method)

# Exit on any error
set -e

# Function for error handling
handle_error() {
  echo "❌ ERROR: $1" >&2
  exit 1
}

echo "🌐 Setting up Open OnDemand using the official package repository"

# 1. Enable dependencies
echo "📦 Installing required packages..."
apt update
apt install -y curl gnupg2 ca-certificates lsb-release wget || handle_error "Failed to install required packages"

# 2. Add Open OnDemand repository and install
echo "📦 Adding Open OnDemand repository..."

sudo apt install -y apt-transport-https ca-certificates
wget -O /tmp/ondemand-release-web_4.0.0-jammy_all.deb https://apt.osc.edu/ondemand/4.0/ondemand-release-web_4.0.0-jammy_all.deb
sudo apt install -y /tmp/ondemand-release-web_4.0.0-jammy_all.deb
sudo apt update

sudo apt install -y ondemand

# 3. Fix Apache configuration issues
echo "🛠️ Fixing Apache configuration..."

# Stop Apache if it's running
sudo systemctl stop apache2 || true

# Check if something is already listening on port 80
if lsof -i :80 >/dev/null 2>&1; then
  echo "⚠️ Port 80 is already in use. Checking what's using it..."
  sudo lsof -i :80 || true
  echo "Attempting to stop the process..."
  sudo fuser -k 80/tcp || true
  sleep 2
fi

# Disable the default Apache site
sudo a2dissite 000-default || true

# Remove all Listen directives from ports.conf to avoid conflicts
echo "🔧 Cleaning up Apache ports configuration..."
sudo cp /etc/apache2/ports.conf /etc/apache2/ports.conf.backup
sudo tee /etc/apache2/ports.conf > /dev/null <<'EOF'
# This file is managed by Open OnDemand
# Listen directives are handled by ood-portal.conf
EOF

# Enable required Apache modules
sudo a2enmod headers
sudo a2enmod rewrite
sudo a2enmod proxy
sudo a2enmod proxy_http
sudo a2enmod proxy_wstunnel
sudo a2enmod lua

# 4. Configure authentication (basic auth for testing)
echo "🔐 Setting up basic authentication for testing..."
# Create a test user 'ooduser' with password 'ooduser'
sudo mkdir -p /etc/ood/config
htpasswd -b -c /etc/ood/config/htpasswd ooduser ooduser

# 5. Create a minimal but complete portal configuration
cat <<'EOF' | sudo tee /etc/ood/config/ood_portal.yml
---
# /etc/ood/config/ood_portal.yml
servername: slurm-controller
port: 80
listen_addr_port:
  - "80"

# Authentication
auth:
  - "AuthType Basic"
  - "AuthName \"Open OnDemand\""
  - "AuthUserFile /etc/ood/config/htpasswd"
  - "RequestHeader unset Authorization"
  - "Require valid-user"

# Disable SSL for local testing
ssl: null

# Portal configuration
public_root: "/public"
public_uri: "/public"

# Log configuration
logroot: "/var/log/ondemand"
errorlog: "error.log"
accesslog: "access.log"

# Ensure we don't have conflicting server names
server_aliases: []
EOF

# Create log directory
sudo mkdir -p /var/log/ondemand
sudo chown www-data:www-data /var/log/ondemand

# Generate the Apache configuration from the portal config
echo "🔧 Generating Apache configuration..."
sudo /opt/ood/ood-portal-generator/sbin/update_ood_portal || handle_error "Failed to generate OnDemand portal configuration"

# Enable the OnDemand portal site
sudo a2ensite ood-portal || handle_error "Failed to enable OnDemand portal site"

# 6. Restart Apache
echo "🛠️ Starting Apache web server..."
sudo systemctl daemon-reload
sudo systemctl restart apache2 || {
  echo "❌ Failed to start Apache. Checking error logs..."
  sudo journalctl -u apache2 --no-pager -n 50
  sudo apache2ctl configtest
  handle_error "Apache failed to start"
}

# 7. Create Slurm cluster config for Open OnDemand
sudo mkdir -p /etc/ood/config/clusters.d
cat <<EOF | sudo tee /etc/ood/config/clusters.d/primedslurm.yml
---
v2:
  metadata:
    title: "PrimedSLURM Cluster"
  login:
    host: "controller"
  job:
    adapter: "slurm"
    bin: "/opt/slurm/bin"
    conf: "/etc/slurm/slurm.conf"
    # copy_environment: true
EOF

# 8. Set up user mapping for OnDemand
echo "👤 Setting up user mapping..."
# Ensure the ubuntu/vagrant user can use OnDemand
sudo mkdir -p /etc/ood/config/clusters.d
sudo usermod -a -G ood ubuntu 2>/dev/null || true
sudo usermod -a -G ood vagrant 2>/dev/null || true

# 9. Final check
sleep 5
echo -n "Checking Open OnDemand accessibility... "
if curl --silent --fail --max-time 10 -u ooduser:ooduser http://localhost/ 2>&1 | grep -q "Open OnDemand"; then
  echo "✅ OnDemand is accessible!"
else
  echo "⚠️ OnDemand may not be fully configured yet"
  echo "Checking Apache status..."
  sudo systemctl status apache2 --no-pager || true
  echo "Checking Apache error logs..."
  sudo tail -20 /var/log/apache2/error.log || true
  sudo tail -20 /var/log/ondemand/error.log || true
fi

echo
echo "✅ Open OnDemand setup complete!"
echo "🌐 Access Open OnDemand at: http://$(hostname -I | awk '{print $1}')/"
echo "👤 Login with username: ooduser, password: ooduser"
echo
echo "Next steps:"
echo "  • For production, set up proper authentication (LDAP, CAS, etc.)"
echo "  • Configure SSL certificates"
echo "  • Customize the portal appearance in /etc/ood/config/ood_portal.yml"