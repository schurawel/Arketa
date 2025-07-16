#!/bin/bash
# setup-ondemand.sh - Automated Open OnDemand setup (official system package method)

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

# Exit on any error
set -e

# Function for error handling
handle_error() {
  if [ "$LINEAR_MODE" = "true" ]; then
    echo "⚠️ WARNING (linear mode): $1" >&2
    return 0
  else
    echo "❌ ERROR: $1" >&2
    exit 1
  fi
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

# Create corresponding system user
sudo useradd -m -s /bin/bash ooduser 2>/dev/null || echo "User ooduser already exists"
echo 'ooduser:ooduser' | sudo chpasswd

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

# Allow access by IP address as well as hostname
server_aliases:
  - "192.168.7.10"
  - "localhost"
EOF

# Create log directory
sudo mkdir -p /var/log/ondemand
sudo chown www-data:www-data /var/log/ondemand

# Create proper /public directory symlink
echo "🔗 Setting up /public directory symlink..."
sudo rm -rf /public 2>/dev/null || true
sudo ln -sf /var/www/ood/public /public

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

# 8.1. Configure Interactive Desktop app
echo "🖥️ Configuring Interactive Desktop app..."
# Fix the cluster configuration for bc_desktop app
sudo cp /var/www/ood/apps/sys/bc_desktop/submit.yml.erb /var/www/ood/apps/sys/bc_desktop/submit.yml.erb.backup 2>/dev/null || true

cat <<EOF | sudo tee /var/www/ood/apps/sys/bc_desktop/submit.yml.erb
---
cluster: primedslurm
batch_connect:
  template: vnc
EOF

# Update form.yml to include cluster and better defaults
sudo cp /var/www/ood/apps/sys/bc_desktop/form.yml /var/www/ood/apps/sys/bc_desktop/form.yml.backup 2>/dev/null || true

cat <<EOF | sudo tee /var/www/ood/apps/sys/bc_desktop/form.yml
---
cluster: primedslurm
attributes:
  desktop:
    label: "Desktop Environment"
    widget: select
    options:
      - ["XFCE Desktop", "xfce"]
      - ["KDE Plasma Desktop", "kde"]
      - ["GNOME Desktop", "gnome"]
    value: "xfce"
  bc_vnc_idle: 0
  bc_vnc_resolution:
    required: true
    value: "1024x768"
  node_type: null
  bc_num_hours:
    value: 1
  bc_num_slots:
    value: 1

form:
  - bc_vnc_idle
  - desktop
  - bc_num_hours
  - bc_num_slots
  - bc_vnc_resolution
  - bc_email_on_started
EOF

# Install desktop environments for the Interactive Desktop feature
echo "📦 Installing desktop environments..."
sudo apt update
sudo apt install -y xfce4 xfce4-terminal kde-plasma-desktop firefox || echo "⚠️ Desktop packages installation had issues"

# Install VNC server for OnDemand Interactive Desktop
sudo apt install -y tigervnc-standalone-server tigervnc-common || echo "⚠️ VNC server installation had issues"

# Install Python and Jupyter for OnDemand Jupyter app
echo "📊 Installing Python and Jupyter..."
sudo apt install -y python3 python3-pip python3-venv || echo "⚠️ Python packages installation had issues"
sudo pip3 install jupyter jupyterlab numpy pandas matplotlib seaborn || echo "⚠️ Jupyter/ML packages installation had issues"

# 8.3. Configure Jupyter Notebook app
echo "📊 Configuring Jupyter Notebook app..."
# Check if Jupyter app exists and create one if it doesn't
if [ ! -d "/var/www/ood/apps/sys/bc_jupyter" ]; then
    sudo mkdir -p /var/www/ood/apps/sys/bc_jupyter
    
    # Create Jupyter submit configuration
    cat <<EOF | sudo tee /var/www/ood/apps/sys/bc_jupyter/submit.yml.erb
---
cluster: primedslurm
batch_connect:
  template: basic
EOF

    # Create Jupyter form configuration
    cat <<EOF | sudo tee /var/www/ood/apps/sys/bc_jupyter/form.yml
---
cluster: primedslurm
attributes:
  bc_num_hours:
    label: "Number of hours"
    value: 1
    min: 1
    max: 24
  bc_num_slots:
    label: "Number of cores"  
    value: 1
    min: 1
    max: 8
  jupyter_type:
    label: "Jupyter Type"
    widget: select
    options:
      - ["Jupyter Notebook", "notebook"]
      - ["JupyterLab", "lab"]
    value: "lab"

form:
  - bc_num_hours
  - bc_num_slots
  - jupyter_type
  - bc_email_on_started
EOF

    # Create Jupyter manifest
    cat <<EOF | sudo tee /var/www/ood/apps/sys/bc_jupyter/manifest.yml
---
name: Jupyter
category: Interactive Apps
subcategory: Machine Learning & Data Science
role: batch_connect
description: |
  This app will launch a Jupyter Notebook/Lab server on one or more compute
  nodes. You can use this to run interactive data analysis, machine learning,
  and scientific computing workflows.
EOF

    # Create template directory and script
    sudo mkdir -p /var/www/ood/apps/sys/bc_jupyter/template
    
    # Create the main Jupyter script template
    cat <<'EOF' | sudo tee /var/www/ood/apps/sys/bc_jupyter/template/script.sh.erb
#!/usr/bin/env bash

# Clean the environment
module purge

# Set working directory to user's home directory
cd "${HOME}"

# Set up Python environment
export PATH="/usr/bin:$PATH"

# Create a working directory for this session
WORK_DIR="${HOME}/ondemand/jupyter/$(date +%Y%m%d_%H%M%S)"
mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"

# Create a basic config directory for Jupyter
export JUPYTER_CONFIG_DIR="${WORK_DIR}/.jupyter"
mkdir -p "${JUPYTER_CONFIG_DIR}"

# Generate Jupyter config
jupyter-<%= context.jupyter_type %> --generate-config

# Set up password file from connection info
export JUPYTER_PASSWORD_FILE="${WORK_DIR}/jupyter_password"
echo "Password: <%= password %>" > "${JUPYTER_PASSWORD_FILE}"

# Start Jupyter
echo "Starting Jupyter <%= context.jupyter_type %> server..."

<%- if context.jupyter_type == "lab" -%>
jupyter-lab \
  --ip="*" \
  --port="<%= port %>" \
  --no-browser \
  --NotebookApp.token="<%= password %>" \
  --NotebookApp.password="" \
  --NotebookApp.allow_origin="*" \
  --NotebookApp.base_url="<%= base_url %>/jupyter/lab" \
  --notebook-dir="${WORK_DIR}"
<%- else -%>
jupyter-notebook \
  --ip="*" \
  --port="<%= port %>" \
  --no-browser \
  --NotebookApp.token="<%= password %>" \
  --NotebookApp.password="" \
  --NotebookApp.allow_origin="*" \
  --NotebookApp.base_url="<%= base_url %>/jupyter" \
  --notebook-dir="${WORK_DIR}"
<%- fi -%>
EOF

    echo "✅ Jupyter app configured"
else
    echo "✅ Jupyter app already exists"
fi

# 8.2. Fix Per-User Nginx (PUN) setup and ensure proper startup
echo "🔧 Configuring Per-User Nginx (PUN) system..."
# Ensure the ooduser can use the PUN system
sudo mkdir -p /var/run/ondemand-nginx
sudo chown root:root /var/run/ondemand-nginx
sudo chmod 755 /var/run/ondemand-nginx

# Clean up any existing PUN processes for ooduser to avoid conflicts
sudo pkill -f 'nginx.*ooduser' 2>/dev/null || true
sudo rm -rf /var/run/ondemand-nginx/ooduser/ 2>/dev/null || true

# Start the PUN for ooduser to ensure it's ready
echo "🚀 Starting Per-User Nginx for ooduser..."
sudo /opt/ood/nginx_stage/sbin/nginx_stage pun -u ooduser -a start || echo "⚠️ PUN start may need to be done after first login"

# 9. Final check - skip in linear mode
if [ "$LINEAR_MODE" != "true" ]; then
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
fi

echo
echo "✅ Open OnDemand setup complete!"
echo "🌐 Access Open OnDemand at: http://$(hostname -I | awk '{print $1}')/"
echo "👤 Login with username: ooduser, password: ooduser"
echo
echo "🖥️ Interactive Desktop should now work properly with cluster: primedslurm"
echo "📋 Available desktop environments: XFCE (default), KDE Plasma, GNOME"
echo "📊 Jupyter Notebook/Lab app is now available for data science workflows"
echo
echo "Next steps:"
echo "  • For production, set up proper authentication (LDAP, CAS, etc.)"
echo "  • Configure SSL certificates"
echo "  • Customize the portal appearance in /etc/ood/config/ood_portal.yml"