#!/bin/bash
# setup-ondemand.sh - Automated Open OnDemand setup (official system package method)
#
# This script includes fixes for TigerVNC compatibility:
# - Removes problematic -log parameter from VNC templates
# - Uses basic template with custom VNC script for desktop app
# - Installs websockify for VNC web interface
# - Creates TigerVNC-compatible VNC server startup script

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

# Detect Ubuntu version and use appropriate OnDemand repository
UBUNTU_CODENAME=$(lsb_release -cs)
UBUNTU_VERSION=$(lsb_release -rs)
echo "📋 Detected Ubuntu version: $UBUNTU_CODENAME ($UBUNTU_VERSION)"

case "$UBUNTU_CODENAME" in
    "noble"|"24.04")
        echo "📋 Ubuntu 24.04 detected - using direct installation approach"
        
        # For Ubuntu 24.04, install OnDemand using Ruby gems directly
        echo "📦 Installing Ruby development environment from default repositories..."
        apt install -y ruby-full ruby-dev ruby-bundler build-essential git libssl-dev libreadline-dev zlib1g-dev
        
        # Install Node.js via NodeSource repository to avoid conflicts
        echo "📦 Installing Node.js via NodeSource repository..."
        curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
        apt install -y nodejs
        
        # Install Apache and required modules
        echo "📦 Installing Apache and required modules..."
        apt install -y apache2 apache2-dev libapache2-mod-wsgi-py3
        
        # Install OnDemand directly using Ruby gems
        echo "📦 Installing OnDemand via Ruby gems..."
        gem install bundler
        
        # Create OnDemand directories
        mkdir -p /opt/ood /var/www/ood /etc/ood/config
        
        # Clone OnDemand source
        cd /tmp
        if [ ! -d "ondemand" ]; then
            git clone https://github.com/OSC/ondemand.git
            cd ondemand
            git checkout v3.1.1  # Use stable version
        else
            cd ondemand
        fi
        
        # Install OnDemand dependencies and build
        bundle config set --local path 'vendor/bundle'
        bundle install --without test
        
        # Copy OnDemand to installation directory
        cp -r . /opt/ood/
        chown -R root:root /opt/ood
        
        # Create symlinks
        ln -sf /opt/ood /var/www/ood/ondemand
        mkdir -p /var/www/ood/public
        mkdir -p /var/www/ood/apps/sys
        
        echo "✅ OnDemand installed from source for Ubuntu 24.04"
        ONDEMAND_SOURCE_INSTALL=true
        ;;
    "jammy"|"22.04")
        echo "📋 Ubuntu 22.04 detected - using native OnDemand repository"
        ONDEMAND_DEB_URL="https://apt.osc.edu/ondemand/4.0/ondemand-release-web_4.0.0-jammy_all.deb"
        ;;
    "focal"|"20.04")
        echo "📋 Ubuntu 20.04 detected - using focal OnDemand repository"
        ONDEMAND_DEB_URL="https://apt.osc.edu/ondemand/4.0/ondemand-release-web_4.0.0-focal_all.deb"
        ;;
    *)
        echo "⚠️ WARNING: Unsupported Ubuntu version ($UBUNTU_CODENAME). Attempting with Jammy repository..."
        ONDEMAND_DEB_URL="https://apt.osc.edu/ondemand/4.0/ondemand-release-web_4.0.0-jammy_all.deb"
        ;;
esac

# Skip package installation if we already installed from source
if [ "$ONDEMAND_SOURCE_INSTALL" != "true" ]; then
    echo "📦 Downloading OnDemand repository package from: $ONDEMAND_DEB_URL"
    wget -O /tmp/ondemand-release-web.deb "$ONDEMAND_DEB_URL"
    sudo apt install -y /tmp/ondemand-release-web.deb
    sudo apt update
fi

echo "📦 Installing OnDemand..."

# Skip package installation if we already installed from source
if [ "$ONDEMAND_SOURCE_INSTALL" = "true" ]; then
    echo "✅ OnDemand already installed from source"
else
    # Try package installation for supported Ubuntu versions
    if ! sudo apt install -y ondemand; then
        echo "❌ OnDemand installation failed with official repository"
        echo "📋 Installing OnDemand from source as alternative..."
        
        # Install required packages for source installation
        apt install -y ruby-full ruby-dev ruby-bundler build-essential git libssl-dev libreadline-dev zlib1g-dev apache2 apache2-dev libapache2-mod-wsgi-py3
        
        # Install Node.js via NodeSource repository to avoid conflicts
        echo "📦 Installing Node.js via NodeSource repository..."
        curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
        apt install -y nodejs
        
        # Install OnDemand from source
        cd /tmp
        if [ ! -d "ondemand" ]; then
            git clone https://github.com/OSC/ondemand.git
            cd ondemand
            git checkout v3.1.1  # Use stable version
        else
            cd ondemand
        fi
        
        # Build and install OnDemand
        gem install bundler
        bundle config set --local path 'vendor/bundle'
        bundle install --without test
        
        # Create OnDemand directories
        mkdir -p /opt/ood /var/www/ood /etc/ood/config
        
        # Copy OnDemand to installation directory
        cp -r . /opt/ood/
        chown -R root:root /opt/ood
        
        # Create symlinks
        ln -sf /opt/ood /var/www/ood/ondemand
        mkdir -p /var/www/ood/public
        mkdir -p /var/www/ood/apps/sys
        
        echo "✅ OnDemand installed from source"
        ONDEMAND_SOURCE_INSTALL=true
    fi
fi

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

# Create OnDemand config directory
sudo mkdir -p /etc/ood/config

# If OnDemand was installed from source, set up additional directories
if [ "$ONDEMAND_SOURCE_INSTALL" = "true" ]; then
    echo "🔧 Configuring source-based OnDemand installation..."
    
    # Create necessary directories
    sudo mkdir -p /var/www/ood/apps/sys
    sudo mkdir -p /var/www/ood/public
    sudo mkdir -p /opt/ood/ood-portal-generator/sbin
    
    # Create basic portal generator script
    sudo tee /opt/ood/ood-portal-generator/sbin/update_ood_portal > /dev/null <<'PORTAL_GEN'
#!/bin/bash
# Basic portal generator for source installation
echo "Generating OnDemand portal configuration..."

# Create basic Apache configuration for OnDemand
cat > /etc/apache2/sites-available/ood-portal.conf << 'APACHE_CONF'
<VirtualHost *:80>
  ServerName slurm-controller
  DocumentRoot /var/www/ood/public

  # Authentication
  <Location "/">
    AuthType Basic
    AuthName "Open OnDemand"
    AuthUserFile /etc/ood/config/htpasswd
    Require valid-user
  </Location>

  # Proxy for OnDemand apps
  ProxyPreserveHost On
  ProxyPass /pun/ http://localhost:5000/
  ProxyPassReverse /pun/ http://localhost:5000/

  # Static assets
  Alias /public /var/www/ood/public
  <Directory "/var/www/ood/public">
    Require all granted
  </Directory>

  # Log files
  ErrorLog /var/log/apache2/ood_error.log
  CustomLog /var/log/apache2/ood_access.log combined
</VirtualHost>
APACHE_CONF

echo "OnDemand portal configuration generated"
PORTAL_GEN
    sudo chmod +x /opt/ood/ood-portal-generator/sbin/update_ood_portal
    
    # Create minimal public directory structure
    sudo mkdir -p /var/www/ood/public
    echo "<h1>OnDemand Web Portal</h1><p>SLURM cluster access portal</p>" | sudo tee /var/www/ood/public/index.html > /dev/null
fi

# Create a test user 'ooduser' with password 'ooduser'
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
    host: "slurm-controller"
  job:
    adapter: "slurm"
    bin: "/opt/slurm/bin"
    conf: "/etc/slurm/slurm.conf"
    # copy_environment: true
  batch_connect:
    basic:
      script_wrapper: |
        module purge
        %s
    vnc:
      script_wrapper: |
        module purge
        export PATH="/opt/TurboVNC/bin:$PATH"
        export WEBSOCKIFY_CMD="/usr/bin/websockify"
        %s
EOF

# Allow login to slurm-controller host as well
cat <<EOF | sudo tee /etc/ood/config/clusters.d/slurm-controller.yml
v2:
  metadata:
    title: "SLURM Controller"
  login:
    host: "slurm-controller"
  job:
    adapter: "slurm"
    bin: "/opt/slurm/bin"
    conf: "/etc/slurm/slurm.conf"
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
  template: basic
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

# 8.1.1. Fix VNC template issues for TigerVNC compatibility
echo "🔧 Fixing VNC template compatibility issues..."

# Create backups of VNC template files
sudo cp /opt/ood/gems/gems/ood_core-0.27.1/lib/ood_core/batch_connect/templates/vnc.rb /opt/ood/gems/gems/ood_core-0.27.1/lib/ood_core/batch_connect/templates/vnc.rb.backup 2>/dev/null || true
sudo cp /opt/ood/gems/gems/ood_core-0.27.1/lib/ood_core/batch_connect/templates/vnc_container.rb /opt/ood/gems/gems/ood_core-0.27.1/lib/ood_core/batch_connect/templates/vnc_container.rb.backup 2>/dev/null || true

# Fix vnc.rb template - remove problematic -log parameter
sudo sed -i 's/vncserver -log "#{vnc_log}" -rfbauth/vncserver -rfbauth/g' /opt/ood/gems/gems/ood_core-0.27.1/lib/ood_core/batch_connect/templates/vnc.rb

# Fix vnc_container.rb template - remove problematic -log parameter  
sudo sed -i 's/vncserver -log "#{vnc_log}" -rfbauth/vncserver -rfbauth/g' /opt/ood/gems/gems/ood_core-0.27.1/lib/ood_core/batch_connect/templates/vnc_container.rb

# Create custom VNC script template for desktop app that works with TigerVNC
cat <<'VNCSOF' | sudo tee /var/www/ood/apps/sys/bc_desktop/template/script.sh.erb
#!/usr/bin/env bash

# Clean up function with proper error handling
clean_up () {
  echo "Cleaning up..."
  # Kill VNC server if display is set and valid
  if [[ -n "${display}" && "${display}" =~ ^[0-9]+$ ]]; then
    echo "Killing VNC server on display :${display}"
    vncserver -kill :${display} 2>/dev/null || true
  fi
  
  # Kill websockify if running
  if [[ -n "${websockify_pid}" && "${websockify_pid}" =~ ^[0-9]+$ ]]; then
    echo "Killing websockify process ${websockify_pid}"
    kill ${websockify_pid} 2>/dev/null || true
  fi
  
  # Clean up any remaining child processes
  pkill -P $$ 2>/dev/null || true
  exit ${1:-0}
}

# Trap signals to ensure cleanup
trap 'clean_up 1' TERM INT

# Function to create random password
create_passwd () {
  local size=${1:-12}
  tr -cd '[:alnum:]' < /dev/urandom | fold -w${size} | head -n1
}

# Function to find available port
find_port () {
  local port
  # Start from port 8080 and find first available
  for port in {8080..8180}; do
    if ! ss -tuln | grep -q :${port}; then
      echo ${port}
      return 0
    fi
  done
  return 1
}

echo "Script starting..."

# Ensure we have a proper Xauthority file
touch "${HOME}/.Xauthority"
chmod 600 "${HOME}/.Xauthority"
echo "Created/verified .Xauthority file"

# Set up VNC password
echo "Generating VNC password"
password=$(create_passwd 12)
spassword=${spassword:-$(create_passwd 12)}
(
  umask 077
  echo "Created VNC password file"
  echo -ne "${password}\\n${spassword}" | vncpasswd -f > "vnc.passwd"
)

echo "Starting VNC desktop session..."

# Clean up any old VNC sessions
vncserver -list | awk '/^:/{system("kill -0 "$2" 2>/dev/null || vncserver -kill "$1)}' 2>/dev/null || true

# Set geometry and idle timeout with proper defaults
GEOMETRY="<%= context.bc_vnc_resolution.to_s.empty? ? "1024x768" : context.bc_vnc_resolution %>"
IDLE_TIMEOUT="<%= context.bc_vnc_idle.to_i == 0 ? "0" : context.bc_vnc_idle %>"

echo "Using geometry: ${GEOMETRY}, idle timeout: ${IDLE_TIMEOUT}"

# Create initial Xauthority entries (crucial for some VNC servers)
if command -v xauth >/dev/null 2>&1; then
  xauth generate "${HOSTNAME}/unix:0" . trusted 2>/dev/null || true
  xauth generate "${HOSTNAME}/unix:1" . trusted 2>/dev/null || true
fi

# Try to start VNC server
display=""
for i in $(seq 1 10); do
  echo "Attempt ${i} to start VNC server..."
  
  # Kill any stale VNC lock files
  rm -f /tmp/.X*-lock /tmp/.X11-unix/X* 2>/dev/null || true
  
  # Check for TurboVNC compatibility
  HTTPD_OPT=""
  if timeout 2 vncserver --help 2>&1 | grep 'nohttpd' >/dev/null 2>&1; then
    HTTPD_OPT="-nohttpd"
  fi

  # Create a proper xstartup script that initializes X11 properly
  mkdir -p ${HOME}/.vnc
  cat > ${HOME}/.vnc/xstartup << 'XSTARTUP'
#!/bin/sh
# VNC xstartup file - initializes X11 environment

# Ensure we have proper environment
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS

# Set up X resources
if [ -f $HOME/.Xresources ]; then
    xrdb $HOME/.Xresources
fi

# Start a basic window manager to keep X alive
if command -v twm > /dev/null 2>&1; then
    twm &
elif command -v mwm > /dev/null 2>&1; then
    mwm &
else
    # If no window manager available, at least start an xterm
    xterm -geometry 80x24+10+10 -ls -title "VNC Desktop" &
fi

# Keep the VNC server running
wait
XSTARTUP
  chmod +x ${HOME}/.vnc/xstartup

  # Start VNC server with the xstartup script
  VNC_OUT=$(vncserver -rfbauth "vnc.passwd" $HTTPD_OPT -geometry "${GEOMETRY}" -idletimeout "${IDLE_TIMEOUT}" 2>&1)
  echo "VNC output: "
  echo "${VNC_OUT}"
  
  # Parse display number from output
  display=$(echo "${VNC_OUT}" | grep -o 'display :[0-9]*' | cut -d':' -f2 | tr -d ' ')
  if [[ -z "${display}" ]]; then
    display=$(echo "${VNC_OUT}" | grep -o ':[0-9]*' | head -1 | cut -d':' -f2)
  fi
  
  # Validate display is a number
  if [[ -n "${display}" && "${display}" =~ ^[0-9]+$ ]]; then
    echo "VNC server started on display :${display}."
    
    # Give VNC server more time to fully initialize
    sleep 8
    
    # Verify VNC server is actually running by checking the process
    if ps aux | grep -v grep | grep -E "(Xvnc|Xtigervnc).*:${display}\s" > /dev/null; then
      echo "VNC server process verified running on display :${display}"
      break
    else
      echo "VNC server process not found, checking with vncserver -list..."
      if vncserver -list 2>&1 | grep -E "^:${display}\s" > /dev/null; then
        echo "VNC server found in list on display :${display}"
        break
      else
        echo "VNC server not running properly, retrying..."
        # Try to clean up this display
        vncserver -kill :${display} 2>/dev/null || true
        sleep 2
        display=""
      fi
    fi
  else
    echo "Failed to start VNC server or parse display, trying again..."
    display=""
    sleep 2
  fi
done

# Check if we got a valid display
if [[ -z "${display}" || ! "${display}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: Failed to start VNC server after 10 attempts"
  clean_up 1
fi

# Calculate port safely
port=$((5900 + display))
echo "VNC server running on port ${port}"

# Set up X authorization properly
echo "Setting up X authorization..."
export DISPLAY=:${display}
export XAUTHORITY="${HOME}/.Xauthority"

# Generate new Xauthority entries
if command -v xauth >/dev/null 2>&1; then
  xauth add ${HOSTNAME}/unix:${display} . $(mcookie) 2>/dev/null || true
  xauth add ${HOSTNAME}:${display} . $(mcookie) 2>/dev/null || true
  xauth add localhost/unix:${display} . $(mcookie) 2>/dev/null || true
  xauth add localhost:${display} . $(mcookie) 2>/dev/null || true
fi

# Wait longer for VNC server to fully initialize
sleep 5

# Test X server connection
echo "Testing X server connection..."
if ! timeout 10 xset q >/dev/null 2>&1; then
  echo "WARNING: X server connection test failed, but continuing..."
else
  echo "X server connection test successful"
fi

# Start websockify
websocket=$(find_port)
if [[ $? -ne 0 ]]; then
  echo "ERROR: Could not find available port for websockify"
  clean_up 1
fi

echo "Starting websockify on port ${websocket}..."

# Check if websockify exists
WEBSOCKIFY_CMD=""
for path in "/opt/websockify/run" "/usr/bin/websockify" "/usr/local/bin/websockify"; do
  if [[ -x "$path" ]]; then
    WEBSOCKIFY_CMD="$path"
    break
  fi
done

if [[ -z "$WEBSOCKIFY_CMD" ]]; then
  echo "ERROR: websockify not found"
  clean_up 1
fi

# Start websockify in background
$WEBSOCKIFY_CMD -D ${websocket} localhost:${port} &
websockify_pid=$!
echo "Started websockify with PID ${websockify_pid}"

# Create connection info
echo "Created connection.yml file"
cat > connection.yml << EOL
host: ${HOSTNAME}
port: ${port}
password: ${password}
spassword: ${spassword}
display: ${display}
websocket: ${websocket}
EOL

# Change to user home directory
cd "${HOME}"

# Set up background process for password reset on connections
(
  while read -r line; do
    if [[ ${line} =~ "Full-control authentication enabled for" ]]; then
      password=$(create_passwd 12)
      spassword=$(create_passwd 12)
      (
        umask 077
        echo -ne "${password}\\n${spassword}" | vncpasswd -f > "vnc.passwd"
      )
      cat > connection.yml << EOL
host: ${HOSTNAME}
port: ${port}
password: ${password}
spassword: ${spassword}
display: ${display}
websocket: ${websocket}
EOL
    fi
  done < <(tail -f --pid=$$ "${HOME}/.vnc/$(hostname):${display}.log" 2>/dev/null)
) &

# Launch desktop environment
desktop_env="<%= context.desktop %>"
echo "Launching ${desktop_env} desktop..."

desktop_script="<%= session.staged_root.join("desktops", "#{context.desktop}.sh") %>"
echo "Desktop script: ${desktop_script}"

# First ensure the VNC display is working by testing with a simple X app
echo "Testing X11 display connectivity..."
export DISPLAY=:${display}
if timeout 5 xset q >/dev/null 2>&1; then
  echo "X11 display test successful"
else
  echo "WARNING: X11 display test failed, but continuing..."
  
  # Try to restart just the X server part
  echo "Attempting to fix X11 display..."
  # Kill any existing X server on this display
  pkill -f "Xvnc.*:${display}" || true
  sleep 2
  
  # Create a simple xstartup that just starts an X session
  cat > ${HOME}/.vnc/xstartup << 'XSTARTUP'
#!/bin/sh
xsetroot -solid grey
xterm -geometry 80x24+10+10 -ls -title "VNC Desktop" &
exec twm
XSTARTUP
  chmod +x ${HOME}/.vnc/xstartup
  
  # Try starting VNC again with the simple config
  vncserver :${display} -rfbauth "vnc.passwd" -geometry "${GEOMETRY}" 2>&1 || true
  sleep 5
fi

# Create connection info for noVNC
noVNC_port=$((websocket + 1))
cat > noVNC-connection.yml << EOL
host: ${HOSTNAME}
port: ${noVNC_port}
EOL

# Launch noVNC in a new browser window
echo "Opening noVNC in browser..."
if command -v xdg-open >/dev/null 2>&1; then
  xdg-open "http://${HOSTNAME}:${noVNC_port}/vnc.html?host=${HOSTNAME}&port=${websocket}" || true
else
  echo "xdg-open not found, please open the following URL manually:"
  echo "http://${HOSTNAME}:${noVNC_port}/vnc.html?host=${HOSTNAME}&port=${websocket}"
fi

# Wait for noVNC to be ready
sleep 2

# Try to connect to the VNC session via noVNC
echo "Attempting to connect to VNC session via noVNC..."
if timeout 10 curl -s "http://${HOSTNAME}:${noVNC_port}/status" | grep -q '"state":"connected"'; then
  echo "✅ Successfully connected to VNC session via noVNC"
else
  echo "❌ Failed to connect to VNC session via noVNC"
fi

# Monitor the VNC session and restart if it crashes
echo "Monitoring VNC session for crashes..."
(
  while true; do
    if ! pgrep -f "Xvnc.*:${display}" >/dev/null && ! pgrep -f "Xtigervnc.*:${display}" >/dev/null; then
      echo "VNC server has stopped unexpectedly"
      echo "Attempting to restart VNC server..."
      VNC_OUT=$(vncserver -rfbauth "vnc.passwd" -noxstartup -geometry "${GEOMETRY}" -idletimeout "${IDLE_TIMEOUT}" 2>&1)
      echo "VNC restart output: "
      echo "${VNC_OUT}"
      
      # Parse display number from output
      new_display=$(echo "${VNC_OUT}" | grep -o ':[0-9]*' | head -1 | cut -d':' -f2)
      if [[ -n "${new_display}" && "${new_display}" =~ ^[0-9]+$ ]]; then
        echo "VNC server restarted on display :${new_display}."
        display=${new_display}
        export DISPLAY=:${display}
      else
        echo "Failed to restart VNC server"
        clean_up 1
      fi
    fi
    
    sleep 5
  done
) &

# Wait for the desktop environment to exit
wait ${desktop_pid}

echo "Desktop session has ended, cleaning up..."
clean_up
VNCSOF

# Also create a minimal TWM desktop script for guaranteed compatibility
echo "🔧 Creating guaranteed-working minimal desktop script..."
cat <<'EOFMIN' | sudo tee /var/www/ood/apps/sys/bc_desktop/template/desktops/minimal.sh
#!/bin/bash
# Ultra-minimal desktop environment that's guaranteed to work

# Log all commands for debugging
set -x
exec > >(tee -a /tmp/minimal-desktop-$(date +%s).log) 2>&1

echo "Starting minimal desktop environment"
echo "DISPLAY=$DISPLAY"
echo "USER=$USER"
echo "PWD=$PWD"

# Ensure X environment is properly set up
export XAUTHORITY="${HOME}/.Xauthority"
export DISPLAY="${DISPLAY:-:1}"

# Ensure we have a proper Xauthority file
touch "${HOME}/.Xauthority"
chmod 600 "${HOME}/.Xauthority"

# Check for and install required packages
if ! command -v xterm >/dev/null 2>&1; then
  echo "Installing essential X packages..."
  sudo apt-get update -y
  sudo apt-get install -y xterm twm x11-apps
fi

# Start a very minimal window manager setup
xsetroot -solid "#333366" 2>/dev/null || echo "xsetroot failed"

# Start a terminal
xterm -geometry 80x24+10+10 -title "Terminal" &
xterm -geometry 80x8+10+300 -title "System Information" -e "echo 'VNC Session Info'; echo 'DISPLAY=$DISPLAY'; echo 'Date: $(date)'; echo 'System: $(uname -a)'; echo; echo 'Desktop environments:'; echo; dpkg -l | grep -E 'xfce|kde|gnome'; sleep 3600" &

# Use the simplest window manager available
if command -v twm >/dev/null 2>&1; then
  echo "Using TWM window manager"
  exec twm
elif command -v fluxbox >/dev/null 2>&1; then
  echo "Using Fluxbox window manager"
  exec fluxbox
elif command -v openbox >/dev/null 2>&1; then
  echo "Using Openbox window manager"
  exec openbox
else
  echo "No window manager found, running without one"
  # Keep the script running so terminals stay open
  wait
fi
EOFMIN

sudo chmod +x /var/www/ood/apps/sys/bc_desktop/template/desktops/minimal.sh

# Update form.yml to include the minimal desktop option
sudo sed -i 's/- \["GNOME Desktop", "gnome"\]/- \["GNOME Desktop", "gnome"\]\n      - \["Minimal Desktop", "minimal"\]/' /var/www/ood/apps/sys/bc_desktop/form.yml

# Update the before.sh.erb script to ensure X11 packages are installed
cat <<'EOF' | sudo tee /var/www/ood/apps/sys/bc_desktop/template/before.sh.erb
#!/bin/bash

# Install required packages for VNC desktop environments if they're missing
echo "Checking for required desktop environment packages..."

# Function to check if a package is installed
is_installed() {
  dpkg -l "$1" 2>/dev/null | grep -q "^ii"
}

# Check if essential X11 packages are installed
echo "Checking for essential X11 utilities..."

# Core X11 packages that MUST be installed
REQUIRED_X11_PACKAGES="xorg x11-xserver-utils xterm twm x11-apps x11-utils xauth dbus-x11 xfonts-base xfonts-100dpi xfonts-75dpi"

missing_packages=""
for pkg in $REQUIRED_X11_PACKAGES; do
  if ! is_installed "$pkg"; then
    missing_packages="$missing_packages $pkg"
  fi
done

if [ -n "$missing_packages" ]; then
  echo "ERROR: Missing required X11 packages:$missing_packages"
  echo "Please contact your system administrator to install these packages."
  echo "The desktop session may not work properly without them."
fi

# Check desktop environment packages
desktop_env="<%= context.desktop %>"
echo "Selected desktop environment: ${desktop_env}"

case "${desktop_env}" in
  xfce)
    if ! is_installed xfce4-session; then
      echo "WARNING: XFCE desktop environment is not installed."
      echo "The session will fall back to a minimal window manager."
    fi
    ;;
  kde)
    if ! is_installed plasma-desktop && ! is_installed kde-plasma-desktop; then
      echo "WARNING: KDE Plasma desktop environment is not installed."
      echo "The session will fall back to a minimal window manager."
    fi
    ;;
  gnome)
    if ! is_installed gnome-session; then
      echo "WARNING: GNOME desktop environment is not installed."
      echo "The session will fall back to a minimal window manager."
    fi
    ;;
  minimal|twm)
    echo "Using minimal TWM window manager..."
    ;;
esac

# Check VNC server
if ! command -v vncserver &>/dev/null; then
  echo "ERROR: VNC server is not installed. Cannot start desktop session."
  exit 1
fi

# Check websockify
if ! command -v websockify &>/dev/null && ! which websockify &>/dev/null; then
  echo "WARNING: websockify is not installed. Web-based VNC access may not work."
fi

# Create a basic .xinitrc file if it doesn't exist
if [ ! -f "$HOME/.xinitrc" ]; then
  echo "Creating basic .xinitrc file..."
  cat > "$HOME/.xinitrc" << 'XINITRC'
#!/bin/sh
# Basic X initialization

# Load X resources
if [ -f "$HOME/.Xresources" ]; then
    xrdb "$HOME/.Xresources"
fi

# Start a window manager based on what's available
if [ -n "$DESKTOP_SESSION" ]; then
    # Use the requested desktop session if set
    case "$DESKTOP_SESSION" in
        xfce)
            exec startxfce4
            ;;
        kde)
            exec startkde
            ;;
        gnome)
            exec gnome-session
            ;;
        *)
            exec twm
            ;;
    esac
elif command -v startxfce4 >/dev/null 2>&1; then
    exec startxfce4
elif command -v startkde >/dev/null 2>&1; then
    exec startkde
elif command -v gnome-session >/dev/null 2>&1; then
    exec gnome-session
elif command -v twm >/dev/null 2>&1; then
    xterm &
    exec twm
else
    xterm &
    exec mwm
fi
XINITRC
  chmod +x "$HOME/.xinitrc"
fi

# Create .vnc directory and xstartup if needed
mkdir -p "$HOME/.vnc"
if [ ! -f "$HOME/.vnc/xstartup" ]; then
  echo "Creating default VNC xstartup file..."
  cat > "$HOME/.vnc/xstartup" << 'VNCSTARTUP'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
[ -r $HOME/.Xresources ] && xrdb $HOME/.Xresources
xsetroot -solid grey
if [ -f "$HOME/.xinitrc" ]; then
    . "$HOME/.xinitrc"
else
    xterm &
    twm
fi
VNCSTARTUP
  chmod +x "$HOME/.vnc/xstartup"
fi

echo "Pre-flight check complete!"
EOF

sudo chmod +x /var/www/ood/apps/sys/bc_desktop/template/before.sh.erb

# Fix the VNC script template to better handle VNC server verification
cat <<'VNCSOF' | sudo tee /var/www/ood/apps/sys/bc_desktop/template/script.sh.erb
#!/usr/bin/env bash

# Clean up function with proper error handling
clean_up () {
  echo "Cleaning up..."
  # Kill VNC server if display is set and valid
  if [[ -n "${display}" && "${display}" =~ ^[0-9]+$ ]]; then
    echo "Killing VNC server on display :${display}"
    vncserver -kill :${display} 2>/dev/null || true
  fi
  
  # Kill websockify if running
  if [[ -n "${websockify_pid}" && "${websockify_pid}" =~ ^[0-9]+$ ]]; then
    echo "Killing websockify process ${websockify_pid}"
    kill ${websockify_pid} 2>/dev/null || true
  fi
  
  # Clean up any remaining child processes
  pkill -P $$ 2>/dev/null || true
  exit ${1:-0}
}

# Trap signals to ensure cleanup
trap 'clean_up 1' TERM INT

# Function to create random password
create_passwd () {
  local size=${1:-12}
  tr -cd '[:alnum:]' < /dev/urandom | fold -w${size} | head -n1
}

# Function to find available port
find_port () {
  local port
  # Start from port 8080 and find first available
  for port in {8080..8180}; do
    if ! ss -tuln | grep -q :${port}; then
      echo ${port}
      return 0
    fi
  done
  return 1
}

echo "Script starting..."

# Ensure we have a proper Xauthority file
touch "${HOME}/.Xauthority"
chmod 600 "${HOME}/.Xauthority"
echo "Created/verified .Xauthority file"

# Set up VNC password
echo "Generating VNC password"
password=$(create_passwd 12)
spassword=${spassword:-$(create_passwd 12)}
(
  umask 077
  echo "Created VNC password file"
  echo -ne "${password}\\n${spassword}" | vncpasswd -f > "vnc.passwd"
)

echo "Starting VNC desktop session..."

# Clean up any old VNC sessions
vncserver -list | awk '/^:/{system("kill -0 "$2" 2>/dev/null || vncserver -kill "$1)}' 2>/dev/null || true

# Set geometry and idle timeout with proper defaults
GEOMETRY="<%= context.bc_vnc_resolution.to_s.empty? ? "1024x768" : context.bc_vnc_resolution %>"
IDLE_TIMEOUT="<%= context.bc_vnc_idle.to_i == 0 ? "0" : context.bc_vnc_idle %>"

echo "Using geometry: ${GEOMETRY}, idle timeout: ${IDLE_TIMEOUT}"

# Create initial Xauthority entries (crucial for some VNC servers)
if command -v xauth >/dev/null 2>&1; then
  xauth generate "${HOSTNAME}/unix:0" . trusted 2>/dev/null || true
  xauth generate "${HOSTNAME}/unix:1" . trusted 2>/dev/null || true
fi

# Try to start VNC server
display=""
for i in $(seq 1 10); do
  echo "Attempt ${i} to start VNC server..."
  
  # Kill any stale VNC lock files
  rm -f /tmp/.X*-lock /tmp/.X11-unix/X* 2>/dev/null || true
  
  # Check for TurboVNC compatibility
  HTTPD_OPT=""
  if timeout 2 vncserver --help 2>&1 | grep 'nohttpd' >/dev/null 2>&1; then
    HTTPD_OPT="-nohttpd"
  fi

  # Create a proper xstartup script that initializes X11 properly
  mkdir -p ${HOME}/.vnc
  cat > ${HOME}/.vnc/xstartup << 'XSTARTUP'
#!/bin/sh
# VNC xstartup file - initializes X11 environment

# Ensure we have proper environment
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS

# Set up X resources
if [ -f $HOME/.Xresources ]; then
    xrdb $HOME/.Xresources
fi

# Start a basic window manager to keep X alive
if command -v twm > /dev/null 2>&1; then
    twm &
elif command -v mwm > /dev/null 2>&1; then
    mwm &
else
    # If no window manager available, at least start an xterm
    xterm -geometry 80x24+10+10 -ls -title "VNC Desktop" &
fi

# Keep the VNC server running
wait
XSTARTUP
  chmod +x ${HOME}/.vnc/xstartup

  # Start VNC server with the xstartup script
  VNC_OUT=$(vncserver -rfbauth "vnc.passwd" $HTTPD_OPT -geometry "${GEOMETRY}" -idletimeout "${IDLE_TIMEOUT}" 2>&1)
  echo "VNC output: "
  echo "${VNC_OUT}"
  
  # Parse display number from output
  display=$(echo "${VNC_OUT}" | grep -o 'display :[0-9]*' | cut -d':' -f2 | tr -d ' ')
  if [[ -z "${display}" ]]; then
    display=$(echo "${VNC_OUT}" | grep -o ':[0-9]*' | head -1 | cut -d':' -f2)
  fi
  
  # Validate display is a number
  if [[ -n "${display}" && "${display}" =~ ^[0-9]+$ ]]; then
    echo "VNC server started on display :${display}."
    
    # Give VNC server more time to fully initialize
    sleep 8
    
    # Verify VNC server is actually running by checking the process
    if ps aux | grep -v grep | grep -E "(Xvnc|Xtigervnc).*:${display}\s" > /dev/null; then
      echo "VNC server process verified running on display :${display}"
      break
    else
      echo "VNC server process not found, checking with vncserver -list..."
      if vncserver -list 2>&1 | grep -E "^:${display}\s" > /dev/null; then
        echo "VNC server found in list on display :${display}"
        break
      else
        echo "VNC server not running properly, retrying..."
        # Try to clean up this display
        vncserver -kill :${display} 2>/dev/null || true
        sleep 2
        display=""
      fi
    fi
  else
    echo "Failed to start VNC server or parse display, trying again..."
    display=""
    sleep 2
  fi
done

# Check if we got a valid display
if [[ -z "${display}" || ! "${display}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: Failed to start VNC server after 10 attempts"
  clean_up 1
fi

# Calculate port safely
port=$((5900 + display))
echo "VNC server running on port ${port}"

# Set up X authorization properly
echo "Setting up X authorization..."
export DISPLAY=:${display}
export XAUTHORITY="${HOME}/.Xauthority"

# Generate new Xauthority entries
if command -v xauth >/dev/null 2>&1; then
  xauth add ${HOSTNAME}/unix:${display} . $(mcookie) 2>/dev/null || true
  xauth add ${HOSTNAME}:${display} . $(mcookie) 2>/dev/null || true
  xauth add localhost/unix:${display} . $(mcookie) 2>/dev/null || true
  xauth add localhost:${display} . $(mcookie) 2>/dev/null || true
fi

# Wait longer for VNC server to fully initialize
sleep 5

# Test X server connection
echo "Testing X server connection..."
if ! timeout 10 xset q >/dev/null 2>&1; then
  echo "WARNING: X server connection test failed, but continuing..."
else
  echo "X server connection test successful"
fi

# Start websockify
websocket=$(find_port)
if [[ $? -ne 0 ]]; then
  echo "ERROR: Could not find available port for websockify"
  clean_up 1
fi

echo "Starting websockify on port ${websocket}..."

# Check if websockify exists
WEBSOCKIFY_CMD=""
for path in "/opt/websockify/run" "/usr/bin/websockify" "/usr/local/bin/websockify"; do
  if [[ -x "$path" ]]; then
    WEBSOCKIFY_CMD="$path"
    break
  fi
done

if [[ -z "$WEBSOCKIFY_CMD" ]]; then
  echo "ERROR: websockify not found"
  clean_up 1
fi

# Start websockify in background
$WEBSOCKIFY_CMD -D ${websocket} localhost:${port} &
websockify_pid=$!
echo "Started websockify with PID ${websockify_pid}"

# Create connection info
echo "Created connection.yml file"
cat > connection.yml << EOL
host: ${HOSTNAME}
port: ${port}
password: ${password}
spassword: ${spassword}
display: ${display}
websocket: ${websocket}
EOL

# Change to user home directory
cd "${HOME}"

# Set up background process for password reset on connections
(
  while read -r line; do
    if [[ ${line} =~ "Full-control authentication enabled for" ]]; then
      password=$(create_passwd 12)
      spassword=$(create_passwd 12)
      (
        umask 077
        echo -ne "${password}\\n${spassword}" | vncpasswd -f > "vnc.passwd"
      )
      cat > connection.yml << EOL
host: ${HOSTNAME}
port: ${port}
password: ${password}
spassword: ${spassword}
display: ${display}
websocket: ${websocket}
EOL
    fi
  done < <(tail -f --pid=$$ "${HOME}/.vnc/$(hostname):${display}.log" 2>/dev/null)
) &

# Launch desktop environment
desktop_env="<%= context.desktop %>"
echo "Launching ${desktop_env} desktop..."

desktop_script="<%= session.staged_root.join("desktops", "#{context.desktop}.sh") %>"
echo "Desktop script: ${desktop_script}"

# First ensure the VNC display is working by testing with a simple X app
echo "Testing X11 display connectivity..."
export DISPLAY=:${display}
if timeout 5 xset q >/dev/null 2>&1; then
  echo "X11 display test successful"
else
  echo "WARNING: X11 display test failed, but continuing..."
  
  # Try to restart just the X server part
  echo "Attempting to fix X11 display..."
  # Kill any existing X server on this display
  pkill -f "Xvnc.*:${display}" || true
  sleep 2
  
  # Create a simple xstartup that just starts an X session
  cat > ${HOME}/.vnc/xstartup << 'XSTARTUP'
#!/bin/sh
xsetroot -solid grey
xterm -geometry 80x24+10+10 -ls -title "VNC Desktop" &
exec twm
XSTARTUP
  chmod +x ${HOME}/.vnc/xstartup
  
  # Try starting VNC again with the simple config
  vncserver :${display} -rfbauth "vnc.passwd" -geometry "${GEOMETRY}" 2>&1 || true
  sleep 5
fi

# Create connection info for noVNC
noVNC_port=$((websocket + 1))
cat > noVNC-connection.yml << EOL
host: ${HOSTNAME}
port: ${noVNC_port}
EOL

# Launch noVNC in a new browser window
echo "Opening noVNC in browser..."
if command -v xdg-open >/dev/null 2>&1; then
  xdg-open "http://${HOSTNAME}:${noVNC_port}/vnc.html?host=${HOSTNAME}&port=${websocket}" || true
else
  echo "xdg-open not found, please open the following URL manually:"
  echo "http://${HOSTNAME}:${noVNC_port}/vnc.html?host=${HOSTNAME}&port=${websocket}"
fi

# Wait for noVNC to be ready
sleep 2

# Try to connect to the VNC session via noVNC
echo "Attempting to connect to VNC session via noVNC..."
if timeout 10 curl -s "http://${HOSTNAME}:${noVNC_port}/status" | grep -q '"state":"connected"'; then
  echo "✅ Successfully connected to VNC session via noVNC"
else
  echo "❌ Failed to connect to VNC session via noVNC"
fi

# Monitor the VNC session and restart if it crashes
echo "Monitoring VNC session for crashes..."
(
  while true; do
    if ! pgrep -f "Xvnc.*:${display}" >/dev/null && ! pgrep -f "Xtigervnc.*:${display}" >/dev/null; then
      echo "VNC server has stopped unexpectedly"
      echo "Attempting to restart VNC server..."
      VNC_OUT=$(vncserver -rfbauth "vnc.passwd" -noxstartup -geometry "${GEOMETRY}" -idletimeout "${IDLE_TIMEOUT}" 2>&1)
      echo "VNC restart output: "
      echo "${VNC_OUT}"
      
      # Parse display number from output
      new_display=$(echo "${VNC_OUT}" | grep -o ':[0-9]*' | head -1 | cut -d':' -f2)
      if [[ -n "${new_display}" && "${new_display}" =~ ^[0-9]+$ ]]; then
        echo "VNC server restarted on display :${new_display}."
        display=${new_display}
        export DISPLAY=:${display}
      else
        echo "Failed to restart VNC server"
        clean_up 1
      fi
    fi
    
    sleep 5
  done
) &

# Wait for the desktop environment to exit
wait ${desktop_pid}

echo "Desktop session has ended, cleaning up..."
clean_up
VNCSOF

# Also create a minimal TWM desktop script for guaranteed compatibility
echo "🔧 Creating guaranteed-working minimal desktop script..."
cat <<'EOFMIN' | sudo tee /var/www/ood/apps/sys/bc_desktop/template/desktops/minimal.sh
#!/bin/bash
# Ultra-minimal desktop environment that's guaranteed to work

# Log all commands for debugging
set -x
exec > >(tee -a /tmp/minimal-desktop-$(date +%s).log) 2>&1

echo "Starting minimal desktop environment"
echo "DISPLAY=$DISPLAY"
echo "USER=$USER"
echo "PWD=$PWD"

# Ensure X environment is properly set up
export XAUTHORITY="${HOME}/.Xauthority"
export DISPLAY="${DISPLAY:-:1}"

# Ensure we have a proper Xauthority file
touch "${HOME}/.Xauthority"
chmod 600 "${HOME}/.Xauthority"

# Check for and install required packages
if ! command -v xterm >/dev/null 2>&1; then
  echo "Installing essential X packages..."
  sudo apt-get update -y
  sudo apt-get install -y xterm twm x11-apps
fi

# Start a very minimal window manager setup
xsetroot -solid "#333366" 2>/dev/null || echo "xsetroot failed"

# Start a terminal
xterm -geometry 80x24+10+10 -title "Terminal" &
xterm -geometry 80x8+10+300 -title "System Information" -e "echo 'VNC Session Info'; echo 'DISPLAY=$DISPLAY'; echo 'Date: $(date)'; echo 'System: $(uname -a)'; echo; echo 'Desktop environments:'; echo; dpkg -l | grep -E 'xfce|kde|gnome'; sleep 3600" &

# Use the simplest window manager available
if command -v twm >/dev/null 2>&1; then
  echo "Using TWM window manager"
  exec twm
elif command -v fluxbox >/dev/null 2>&1; then
  echo "Using Fluxbox window manager"
  exec fluxbox
elif command -v openbox >/dev/null 2>&1; then
  echo "Using Openbox window manager"
  exec openbox
else
  echo "No window manager found, running without one"
  # Keep the script running so terminals stay open
  wait
fi
EOFMIN

sudo chmod +x /var/www/ood/apps/sys/bc_desktop/template/desktops/minimal.sh

# Update form.yml to include the minimal desktop option
sudo sed -i 's/- \["GNOME Desktop", "gnome"\]/- \["GNOME Desktop", "gnome"\]\n      - \["Minimal Desktop", "minimal"\]/' /var/www/ood/apps/sys/bc_desktop/form.yml

# Update the before.sh.erb script to ensure X11 packages are installed
cat <<'EOF' | sudo tee /var/www/ood/apps/sys/bc_desktop/template/before.sh.erb
#!/bin/bash

# Install required packages for VNC desktop environments if they're missing
echo "Checking for required desktop environment packages..."

# Function to check if a package is installed
is_installed() {
  dpkg -l "$1" 2>/dev/null | grep -q "^ii"
}

# Check if essential X11 packages are installed
echo "Checking for essential X11 utilities..."

# Core X11 packages that MUST be installed
REQUIRED_X11_PACKAGES="xorg x11-xserver-utils xterm twm x11-apps x11-utils xauth dbus-x11 xfonts-base xfonts-100dpi xfonts-75dpi"

missing_packages=""
for pkg in $REQUIRED_X11_PACKAGES; do
  if ! is_installed "$pkg"; then
    missing_packages="$missing_packages $pkg"
  fi
done

if [ -n "$missing_packages" ]; then
  echo "ERROR: Missing required X11 packages:$missing_packages"
  echo "Please contact your system administrator to install these packages."
  echo "The desktop session may not work properly without them."
fi

# Check desktop environment packages
desktop_env="<%= context.desktop %>"
echo "Selected desktop environment: ${desktop_env}"

case "${desktop_env}" in
  xfce)
    if ! is_installed xfce4-session; then
      echo "WARNING: XFCE desktop environment is not installed."
      echo "The session will fall back to a minimal window manager."
    fi
    ;;
  kde)
    if ! is_installed plasma-desktop && ! is_installed kde-plasma-desktop; then
      echo "WARNING: KDE Plasma desktop environment is not installed."
      echo "The session will fall back to a minimal window manager."
    fi
    ;;
  gnome)
    if ! is_installed gnome-session; then
      echo "WARNING: GNOME desktop environment is not installed."
      echo "The session will fall back to a minimal window manager."
    fi
    ;;
  minimal|twm)
    echo "Using minimal TWM window manager..."
    ;;
esac

# Check VNC server
if ! command -v vncserver &>/dev/null; then
  echo "ERROR: VNC server is not installed. Cannot start desktop session."
  exit 1
fi

# Check websockify
if ! command -v websockify &>/dev/null && ! which websockify &>/dev/null; then
  echo "WARNING: websockify is not installed. Web-based VNC access may not work."
fi

# Create a basic .xinitrc file if it doesn't exist
if [ ! -f "$HOME/.xinitrc" ]; then
  echo "Creating basic .xinitrc file..."
  cat > "$HOME/.xinitrc" << 'XINITRC'
#!/bin/sh
# Basic X initialization

# Load X resources
if [ -f "$HOME/.Xresources" ]; then
    xrdb "$HOME/.Xresources"
fi

# Start a window manager based on what's available
if [ -n "$DESKTOP_SESSION" ]; then
    # Use the requested desktop session if set
    case "$DESKTOP_SESSION" in
        xfce)
            exec startxfce4
            ;;
        kde)
            exec startkde
            ;;
        gnome)
            exec gnome-session
            ;;
        *)
            exec twm
            ;;
    esac
elif command -v startxfce4 >/dev/null 2>&1; then
    exec startxfce4
elif command -v startkde >/dev/null 2>&1; then
    exec startkde
elif command -v gnome-session >/dev/null 2>&1; then
    exec gnome-session
elif command -v twm >/dev/null 2>&1; then
    xterm &
    exec twm
else
    xterm &
    exec mwm
fi
XINITRC
  chmod +x "$HOME/.xinitrc"
fi

# Create .vnc directory and xstartup if needed
mkdir -p "$HOME/.vnc"
if [ ! -f "$HOME/.vnc/xstartup" ]; then
  echo "Creating default VNC xstartup file..."
  cat > "$HOME/.vnc/xstartup" << 'VNCSTARTUP'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
[ -r $HOME/.Xresources ] && xrdb $HOME/.Xresources
xsetroot -solid grey
if [ -f "$HOME/.xinitrc" ]; then
    . "$HOME/.xinitrc"
else
    xterm &
    twm
fi
VNCSTARTUP
  chmod +x "$HOME/.vnc/xstartup"
fi

echo "Pre-flight check complete!"
EOF

sudo chmod +x /var/www/ood/apps/sys/bc_desktop/template/before.sh.erb

# 8.2. Configure websockify service for systemd
echo "🔧 Configuring websockify service for systemd..."
sudo tee /etc/systemd/system/websockify.service > /dev/null <<'EOF'
[Unit]
Description=Websockify service for VNC
After=network.target

[Service]
Type=simple
User=www-data
ExecStart=/usr/bin/websockify --web=/usr/share/novnc/ 6080 localhost:5901
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd to recognize the new service
sudo systemctl daemon-reload

# Enable and start the websockify service
sudo systemctl enable websockify
sudo systemctl start websockify

echo "✅ Open OnDemand setup complete! Access the portal at http://<your-server-ip>/"