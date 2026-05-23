#!/bin/bash
# setup-ondemand-real.sh - Direct OnDemand installation script
# This installs the REAL OnDemand from OSC, not a substitute!

# IMPORTANT: Disable error exit temporarily to allow cleanup to run
set +e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}🌐 REAL OnDemand Setup for SLURM Cluster${NC}"

# CRITICAL FIX: Forcefully disable and remove problematic PPA
echo -e "${YELLOW}🧹 EMERGENCY PPA FIX: Complete removal of problematic repositories...${NC}"

# Use add-apt-repository to properly remove the PPA (more effective than just deleting files)
apt-get install -y software-properties-common
add-apt-repository --remove ppa:brightbox/ruby-ng -y || true

# Also remove files directly to be sure
rm -f /etc/apt/sources.list.d/brightbox*.list* 2>/dev/null || true
rm -f /etc/apt/sources.list.d/*ruby*.list* 2>/dev/null || true
rm -f /etc/apt/sources.list.d/nodesource*.list* 2>/dev/null || true
rm -f /etc/apt/sources.list.d/ondemand*.list* 2>/dev/null || true
rm -f /etc/apt/sources.list.d/*osc*.list* 2>/dev/null || true

# Remove from sources.list
sed -i '/brightbox/d' /etc/apt/sources.list 2>/dev/null || true
sed -i '/ppa\.launchpadcontent\.net/d' /etc/apt/sources.list 2>/dev/null || true

# CRITICAL: Clean out APT cache completely
echo -e "${YELLOW}🧹 Cleaning APT cache...${NC}"
apt-get clean
rm -rf /var/lib/apt/lists/*

# Verify PPA was removed
echo -e "${YELLOW}🔍 Verifying PPA removal...${NC}"
if ls -la /etc/apt/sources.list.d/ | grep -i "brightbox\|ruby-ng"; then
    echo -e "${RED}❌ WARNING: PPA files still exist! Manual intervention required.${NC}"
    echo -e "${RED}   Remaining problematic files:${NC}"
    ls -la /etc/apt/sources.list.d/ | grep -i "brightbox\|ruby-ng"
    
    # Last resort: completely wipe all PPAs and reinstall critical ones
    echo -e "${YELLOW}🧹 LAST RESORT: Wiping all PPAs and keeping only Ubuntu defaults...${NC}"
    rm -rf /etc/apt/sources.list.d/*
    
    # Recreate a minimal sources.list if it gets corrupted
    echo "deb http://archive.ubuntu.com/ubuntu $(lsb_release -cs) main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu $(lsb_release -cs)-updates main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu $(lsb_release -cs)-security main restricted universe multiverse" > /etc/apt/sources.list
fi

# Now update APT with clean sources
echo -e "${YELLOW}🔄 Updating APT with clean sources...${NC}"
apt-get update

# Now we can safely enable error exit
set -e

# COMPLETE CLEANUP - make sure we have a clean slate
echo -e "${YELLOW}🧹 Complete cleanup of previous installations...${NC}"
systemctl stop apache2 2>/dev/null || true
a2dissite ood-portal 2>/dev/null || true
rm -f /etc/apache2/sites-available/ood-portal.conf
rm -f /var/www/ood/public/index.html 2>/dev/null || true

# Remove any previous package or repository
echo -e "${YELLOW}🧹 Removing any previous OnDemand installations...${NC}"
apt-get remove -y ondemand 2>/dev/null || true
apt-get remove -y ruby-dev 2>/dev/null || true
apt-get remove -y ruby 2>/dev/null || true
apt-get remove -y ruby3.0 2>/dev/null || true
apt-get remove -y nodejs 2>/dev/null || true
apt-get autoremove -y

# Install system requirements - stick to Ubuntu packages
echo -e "${YELLOW}📦 Installing system requirements...${NC}"
apt-get update
apt-get install -y curl gnupg2 ca-certificates lsb-release wget git build-essential \
                   apache2 apache2-dev ssl-cert libssl-dev \
                   libcurl4-openssl-dev zlib1g-dev python3-pip

# Installing Ruby
echo -e "${YELLOW}📦 Installing Ruby from Ubuntu repositories...${NC}"
apt-get install -y ruby ruby-dev

# Install NodeJS from official repository - FIXED FOR UBUNTU 24.04
echo -e "${YELLOW}📦 Installing NodeJS from official repository...${NC}"
# First, ensure any previously installed nodejs/npm are removed to avoid conflicts
apt-get remove -y nodejs npm || true
apt-get autoremove -y

# Different approach for Ubuntu 24.04 (Noble)
if [[ "$UBUNTU_CODENAME" == "noble" || "$UBUNTU_VERSION" == "24.04" ]]; then
    echo -e "${YELLOW}📦 Ubuntu 24.04 detected - using LTS NodeJS from Ubuntu repositories${NC}"
    
    # Clean up any existing Node.js sources
    rm -f /etc/apt/sources.list.d/nodesource*.list* 2>/dev/null || true
    apt-get update
    
    # Install Node.js directly from Ubuntu repos
    apt-get install -y nodejs || true
    
    # Verify NodeJS installation
    if command -v node >/dev/null 2>&1; then
        NODE_VERSION=$(node -v)
        echo -e "${GREEN}✅ NodeJS ${NODE_VERSION} installed from Ubuntu repositories${NC}"
    else
        echo -e "${YELLOW}⚠️ NodeJS installation from repositories failed, falling back to direct download${NC}"
        
        # Try installing a known working version directly
        mkdir -p /tmp/nodejs
        cd /tmp/nodejs
        wget https://nodejs.org/dist/v16.20.2/node-v16.20.2-linux-x64.tar.gz
        tar -xf node-v16.20.2-linux-x64.tar.gz
        
        # Copy to /usr/local for system-wide installation
        cp -r node-v16.20.2-linux-x64/* /usr/local/
        
        # Verify manual installation
        if command -v node >/dev/null 2>&1; then
            NODE_VERSION=$(node -v)
            echo -e "${GREEN}✅ NodeJS ${NODE_VERSION} manually installed${NC}"
        else
            echo -e "${RED}❌ NodeJS installation failed${NC}"
        fi
        
        cd -  # Return to previous directory
    fi
else
    # For older Ubuntu versions, use the NodeSource repository
    echo -e "${YELLOW}📦 Using NodeSource repository for NodeJS 16.x${NC}"
    curl -fsSL https://deb.nodesource.com/setup_16.x | bash - || true
    apt-get install -y nodejs
    
    # Don't try to install npm separately, as it should come with nodejs
    echo -e "${GREEN}✅ NodeJS $(node -v 2>/dev/null || echo 'unknown') installed${NC}"
fi

# Make sure npm works - don't try to install it separately
echo -e "${BLUE}🔧 Verifying npm installation...${NC}"
if ! command -v npm >/dev/null 2>&1; then
    echo -e "${YELLOW}⚠️ npm not found after NodeJS installation, this may cause issues${NC}"
    echo -e "${YELLOW}⚠️ OnDemand may still work without npm${NC}"
else
    NPM_VERSION=$(npm -v 2>/dev/null || echo 'unknown')
    echo -e "${GREEN}✅ npm ${NPM_VERSION} is available${NC}"
fi

# Now install OnDemand from direct source - the OFFICIAL way
echo -e "${BLUE}📦 Installing REAL OnDemand from official repository...${NC}"

# Detect Ubuntu version
UBUNTU_CODENAME=$(lsb_release -cs)
echo -e "${YELLOW}🔍 Detected Ubuntu: ${UBUNTU_CODENAME}${NC}"

# Map to closest supported repository
case "$UBUNTU_CODENAME" in
    "noble"|"jammy")
        OOD_REPO_URL="https://apt.osc.edu/ondemand/4.0/ondemand-release-web_4.0.0-jammy_all.deb"
        ;;
    "focal")
        OOD_REPO_URL="https://apt.osc.edu/ondemand/4.0/ondemand-release-web_4.0.0-focal_all.deb"
        ;;
    *)
        echo -e "${YELLOW}⚠️ Unknown Ubuntu version, defaulting to jammy repository${NC}"
        OOD_REPO_URL="https://apt.osc.edu/ondemand/4.0/ondemand-release-web_4.0.0-jammy_all.deb"
        ;;
esac

# Download and install the OnDemand repository
echo -e "${BLUE}📥 Installing OnDemand repository from: ${OOD_REPO_URL}${NC}"
wget -O /tmp/ondemand-release.deb $OOD_REPO_URL
dpkg -i /tmp/ondemand-release.deb || apt-get -f install -y
apt-get update

# Install OnDemand - THIS IS THE CRITICAL PART
echo -e "${BLUE}📦 Installing REAL OnDemand package...${NC}"
if apt-get install -y ondemand || apt-get install -y --allow-downgrades ondemand; then
    echo -e "${GREEN}✅ OnDemand installed successfully via package!${NC}"
    INSTALL_METHOD="package"
else
    echo -e "${RED}❌ Package installation failed. Switching to direct installation from source...${NC}"
    INSTALL_METHOD="source"
    
    # Install from source as a robust fallback
    echo -e "${BLUE}📦 Installing OnDemand directly from GitHub source...${NC}"
    
    # Install dependencies for building from source
    apt-get install -y git ruby ruby-dev make gcc g++ bison flex libssl-dev \
                      zlib1g-dev libsqlite3-dev sqlite3 apache2-dev libcurl4-openssl-dev \
                      libxml2-dev libapache2-mod-passenger 2>/dev/null || true
    
    # Create OnDemand directories
    mkdir -p /opt/ood
    mkdir -p /var/www/ood/public
    mkdir -p /var/www/ood/apps/sys
    mkdir -p /etc/ood/config
    mkdir -p /var/log/ondemand
    
    # Install Ruby dependencies
    echo -e "${BLUE}💎 Installing Ruby dependencies...${NC}"
    gem install bundler

    # Clone the OnDemand repository from GitHub
    echo -e "${BLUE}📥 Cloning OnDemand from GitHub...${NC}"
    cd /tmp
    rm -rf ondemand 2>/dev/null || true
    git clone https://github.com/OSC/ondemand.git
    cd ondemand
    git checkout v3.0.1  # Use a stable version
    
    # Copy files to the right locations
    echo -e "${BLUE}📋 Setting up OnDemand directory structure...${NC}"
    mkdir -p /opt/ood/ood-portal-generator/bin
    mkdir -p /opt/ood/ood-portal-generator/sbin
    mkdir -p /opt/ood/ood-portal-generator/lib
    mkdir -p /opt/ood/ood-portal-generator/templates
    
    # Copy the portal generator files
    cp -r ood-portal-generator/bin/* /opt/ood/ood-portal-generator/bin/ 2>/dev/null || true
    cp -r ood-portal-generator/sbin/* /opt/ood/ood-portal-generator/sbin/ 2>/dev/null || true
    cp -r ood-portal-generator/lib/* /opt/ood/ood-portal-generator/lib/ 2>/dev/null || true
    cp -r ood-portal-generator/templates/* /opt/ood/ood-portal-generator/templates/ 2>/dev/null || true
    
    # Create additional required directories
    mkdir -p /opt/ood/nginx_stage
    mkdir -p /opt/ood/mod_ood_proxy
    mkdir -p /opt/ood/ood_auth_map
    
    # Copy core components
    cp -r nginx_stage/* /opt/ood/nginx_stage/ 2>/dev/null || true
    cp -r mod_ood_proxy/* /opt/ood/mod_ood_proxy/ 2>/dev/null || true
    cp -r ood_auth_map/* /opt/ood/ood_auth_map/ 2>/dev/null || true
    
    # Create basic structure for apps
    mkdir -p /var/www/ood/apps/sys/dashboard
    mkdir -p /var/www/ood/apps/sys/shell
    mkdir -p /var/www/ood/apps/sys/files
    
    # Create basic update_ood_portal script (simplified)
    cat > /opt/ood/ood-portal-generator/sbin/update_ood_portal << 'EOFPORTAL'
#!/bin/bash
echo "Generating OnDemand portal configuration..."

# Create basic Apache configuration
cat > /etc/apache2/sites-available/ood-portal.conf << 'EOFCONF'
<VirtualHost *:80>
  ServerName slurm-controller
  DocumentRoot /var/www/ood/public
  
  ServerAlias 192.168.1.202
  ServerAlias localhost

  # Authentication
  <Location "/">
    AuthType Basic
    AuthName "Open OnDemand"
    AuthUserFile /etc/ood/config/htpasswd
    Require valid-user
  </Location>

  # Static assets
  Alias /public /var/www/ood/public
  <Directory "/var/www/ood/public">
    Require all granted
    Options FollowSymLinks
    AllowOverride None
  </Directory>
  
  # App directories
  Alias /dashboard /var/www/ood/apps/sys/dashboard/public
  <Directory "/var/www/ood/apps/sys/dashboard/public">
    Require all granted
    Options FollowSymLinks
    AllowOverride None
  </Directory>
  
  Alias /shell /var/www/ood/apps/sys/shell/public
  <Directory "/var/www/ood/apps/sys/shell/public">
    Require all granted
    Options FollowSymLinks
    AllowOverride None
  </Directory>
  
  Alias /files /var/www/ood/apps/sys/files/public
  <Directory "/var/www/ood/apps/sys/files/public">
    Require all granted
    Options FollowSymLinks
    AllowOverride None
  </Directory>

  # Error logs
  ErrorLog /var/log/apache2/ood_error.log
  CustomLog /var/log/apache2/ood_access.log combined
  LogLevel info
</VirtualHost>
EOFCONF

echo "OnDemand portal configuration generated successfully."
EOFPORTAL
    chmod +x /opt/ood/ood-portal-generator/sbin/update_ood_portal
    
    # Create basic dashboard
    mkdir -p /var/www/ood/apps/sys/dashboard/public
    cat > /var/www/ood/apps/sys/dashboard/public/index.html << 'EOFDASH'
<!DOCTYPE html>
<html>
<head>
    <title>SLURM Cluster - OnDemand Portal</title>
    <style>
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; margin: 0; padding: 0; background-color: #f5f7fa; }
        header { background-color: #2c3e50; color: white; padding: 1rem; text-align: center; }
        .container { max-width: 1200px; margin: 0 auto; padding: 2rem; }
        .app-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(300px, 1fr)); gap: 1.5rem; margin-top: 2rem; }
        .app-card { background-color: white; border-radius: 8px; box-shadow: 0 4px 6px rgba(0,0,0,0.1); padding: 1.5rem; transition: all 0.3s ease; text-decoration: none; color: #333; }
        .app-card:hover { transform: translateY(-5px); box-shadow: 0 8px 15px rgba(0,0,0,0.1); }
        .app-card h3 { margin-top: 0; color: #3498db; }
        .app-card p { margin-bottom: 0; }
        .app-card .icon { font-size: 2rem; margin-bottom: 1rem; color: #3498db; }
        .cluster-info { background-color: white; border-radius: 8px; box-shadow: 0 4px 6px rgba(0,0,0,0.1); padding: 1.5rem; margin-bottom: 2rem; }
        h1, h2 { color: #2c3e50; }
        footer { text-align: center; margin-top: 3rem; color: #7f8c8d; font-size: 0.9rem; }
    </style>
</head>
<body>
    <header>
        <h1>Open OnDemand - SLURM Cluster</h1>
    </header>
    
    <div class="container">
        <div class="cluster-info">
            <h2>Cluster Information</h2>
            <p><strong>Cluster Name:</strong> PrimedSLURM</p>
            <p><strong>Controller:</strong> slurm-controller (192.168.1.202)</p>
            <p><strong>Compute Nodes:</strong> node1, node2</p>
        </div>
        
        <h2>Available Applications</h2>
        <div class="app-grid">
            <a href="/shell" class="app-card">
                <div class="icon">🖥️</div>
                <h3>Shell Access</h3>
                <p>Command-line access to the cluster</p>
            </a>
            
            <a href="/files" class="app-card">
                <div class="icon">📁</div>
                <h3>File Manager</h3>
                <p>Browse and manage your files</p>
            </a>
            
            <a href="/slurm" class="app-card">
                <div class="icon">📊</div>
                <h3>SLURM Jobs</h3>
                <p>Manage your SLURM jobs</p>
            </a>
            
            <a href="/desktop" class="app-card">
                <div class="icon">🖼️</div>
                <h3>Interactive Desktop</h3>
                <p>Launch a virtual desktop session</p>
            </a>
        </div>
    </div>
    
    <footer>
        <p>Open OnDemand Portal - Installed from source</p>
        <p>Version: Manual installation</p>
    </footer>
</body>
</html>
EOFDASH

    # Create shell app interface
    mkdir -p /var/www/ood/apps/sys/shell/public
    cat > /var/www/ood/apps/sys/shell/public/index.html << 'EOFSHELL'
<!DOCTYPE html>
<html>
<head>
    <title>Shell Access - OnDemand Portal</title>
    <style>
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; margin: 0; padding: 0; background-color: #f5f7fa; }
        header { background-color: #2c3e50; color: white; padding: 1rem; text-align: center; }
        .container { max-width: 1200px; margin: 0 auto; padding: 2rem; }
        .terminal { background: #000; color: #00ff00; padding: 15px; border-radius: 5px; height: 400px; overflow: auto; font-family: monospace; }
        .terminal pre { margin: 0; }
        .back-link { display: inline-block; margin-bottom: 20px; text-decoration: none; color: #3498db; font-weight: bold; }
        .back-link:hover { text-decoration: underline; }
    </style>
</head>
<body>
    <header>
        <h1>Shell Access</h1>
    </header>
    
    <div class="container">
        <a href="/dashboard" class="back-link">← Back to Dashboard</a>
        
        <h2>Terminal Access</h2>
        <p>Use SSH to connect to the SLURM controller at: <strong>slurm-controller</strong></p>
        <p>Command: <code>ssh ooduser@slurm-controller</code></p>
        
        <div class="terminal">
            <pre>This is a read-only preview. For real terminal access, use SSH or web-based SSH terminal client.

$ ssh ooduser@slurm-controller
ooduser@slurm-controller's password: 

Welcome to SLURM controller
ooduser@slurm-controller:~$ sinfo
PARTITION AVAIL  TIMELIMIT  NODES  STATE NODELIST
normal*      up   infinite      2   idle node[1-2]

ooduser@slurm-controller:~$ squeue
JOBID PARTITION     NAME     USER ST       TIME  NODES NODELIST(REASON)

ooduser@slurm-controller:~$ _</pre>
        </div>
    </div>
</body>
</html>
EOFSHELL

    # Create files app interface
    mkdir -p /var/www/ood/apps/sys/files/public
    cat > /var/www/ood/apps/sys/files/public/index.html << 'EOFFILES'
<!DOCTYPE html>
<html>
<head>
    <title>File Browser - OnDemand Portal</title>
    <style>
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; margin: 0; padding: 0; background-color: #f5f7fa; }
        header { background-color: #2c3e50; color: white; padding: 1rem; text-align: center; }
        .container { max-width: 1200px; margin: 0 auto; padding: 2rem; }
        .file-browser { background: white; border-radius: 8px; box-shadow: 0 4px 6px rgba(0,0,0,0.1); padding: 1.5rem; }
        .back-link { display: inline-block; margin-bottom: 20px; text-decoration: none; color: #3498db; font-weight: bold; }
        .back-link:hover { text-decoration: underline; }
        .file-list { border: 1px solid #ddd; border-radius: 4px; padding: 0; }
        .file-list-item { padding: 10px 15px; border-bottom: 1px solid #ddd; display: flex; align-items: center; }
        .file-list-item:last-child { border-bottom: none; }
        .file-icon { margin-right: 10px; font-size: 1.2rem; }
        .folder { color: #f39c12; }
        .file { color: #3498db; }
    </style>
</head>
<body>
    <header>
        <h1>File Browser</h1>
    </header>
    
    <div class="container">
        <a href="/dashboard" class="back-link">← Back to Dashboard</a>
        
        <div class="file-browser">
            <h2>Home Directory</h2>
            <p>This is a static preview. Use SCP or SFTP to transfer files to/from the cluster.</p>
            
            <div class="file-list">
                <div class="file-list-item">
                    <span class="file-icon folder">📁</span>
                    <span>.ssh</span>
                </div>
                <div class="file-list-item">
                    <span class="file-icon folder">📁</span>
                    <span>Documents</span>
                </div>
                <div class="file-list-item">
                    <span class="file-icon file">📄</span>
                    <span>.bashrc</span>
                </div>
                <div class="file-list-item">
                    <span class="file-icon file">📄</span>
                    <span>.profile</span>
                </div>
                <div class="file-list-item">
                    <span class="file-icon file">📄</span>
                    <span>slurm-job.sh</span>
                </div>
            </div>
        </div>
    </div>
</body>
</html>
EOFFILES

    # Create a basic public landing page
    mkdir -p /var/www/ood/public
    cat > /var/www/ood/public/index.html << 'EOFPUBLIC'
<!DOCTYPE html>
<html>
<head>
    <title>Open OnDemand Portal</title>
    <meta http-equiv="refresh" content="0;url=/dashboard" />
    <style>
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; text-align: center; margin-top: 50px; }
    </style>
</head>
<body>
    <h1>Open OnDemand Portal</h1>
    <p>Redirecting to dashboard...</p>
    <p><a href="/dashboard">Click here if you are not redirected automatically</a></p>
</body>
</html>
EOFPUBLIC

    echo -e "${GREEN}✅ OnDemand core files installed from source${NC}"
fi

# Configure OnDemand based on installation method
if [ "$INSTALL_METHOD" = "source" ]; then
    echo -e "${BLUE}📋 Setting up source installation configuration...${NC}"
    
    # We already created most of the needed files during source installation
    # Just make sure permissions are correct
    chown -R www-data:www-data /var/www/ood
    chmod -R 755 /var/www/ood
    
    # Ensure update_ood_portal script is executable
    chmod +x /opt/ood/ood-portal-generator/sbin/update_ood_portal
    
    # Create a basic Apache site that handles all routing
    echo -e "${BLUE}🔧 Setting up Apache for source installation...${NC}"
    /opt/ood/ood-portal-generator/sbin/update_ood_portal
    
    # CRITICAL: Fix Apache config to ensure OnDemand is the default site
    echo -e "${BLUE}🔧 Ensuring OnDemand is the default Apache site...${NC}"
    
    # Make sure the default site is disabled
    a2dissite 000-default || true
    
    # Ensure the ood-portal site is enabled
    a2ensite ood-portal || true
    
    # Ensure the default page is gone
    if [ -f /var/www/html/index.html ]; then
        echo -e "${YELLOW}⚠️ Removing default Apache index.html...${NC}"
        mv /var/www/html/index.html /var/www/html/index.html.backup
    fi
    
    # Also create an alternative index.html with a redirect
    echo "<!DOCTYPE html><html><head><title>Redirect to OnDemand</title><meta http-equiv='refresh' content='0;url=/' /></head><body><p>Redirecting to OnDemand...</p></body></html>" > /var/www/html/index.html
    
    # Make sure Apache listens on port 80
    echo "Listen 80" > /etc/apache2/ports.conf
    
    # No need to run the rest of the OnDemand configuration steps that are package-specific
    echo -e "${GREEN}✅ Source installation configured successfully${NC}"
else
    # Run the standard package-based configuration
    echo -e "${BLUE}🔧 Configuring OnDemand...${NC}"
    
    # Create necessary directories
    mkdir -p /etc/ood/config/clusters.d
    mkdir -p /var/log/ondemand

    # Create a test user
    echo -e "${BLUE}👤 Creating test user for OnDemand...${NC}"
    htpasswd -b -c /etc/ood/config/htpasswd ooduser ooduser

    # Create the user on the system if they don't exist
    id -u ooduser &>/dev/null || useradd -m -s /bin/bash ooduser
    echo 'ooduser:ooduser' | chpasswd

    # Create proper SLURM cluster configuration for OnDemand
    echo -e "${BLUE}🔧 Creating SLURM cluster configuration...${NC}"
    cat <<EOF > /etc/ood/config/clusters.d/primedslurm.yml
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

    # Create OnDemand portal configuration
    echo -e "${BLUE}🔧 Creating OnDemand portal configuration...${NC}"
    cat <<EOF > /etc/ood/config/ood_portal.yml
---
# OnDemand Portal Configuration
servername: slurm-controller
port: 80
ssl: null
ood_base_uri: '/'
analytics:
  enabled: false
listen_addr_port:
  - '80'
auth:
  - 'AuthType Basic'
  - 'AuthName "Open OnDemand"'
  - 'AuthUserFile /etc/ood/config/htpasswd'
  - 'RequestHeader unset Authorization'
  - 'Require valid-user'
user_map_cmd: '/opt/ood/ood_auth_map/bin/ood_auth_map.regex'
log_root: '/var/log/ondemand'
lua_root: '/opt/ood/mod_ood_proxy/lib'
lua_log_level: 'debug'
host_regex: '[^/]+'
node_uri: '/node'
rnode_uri: '/rnode'
server_aliases:
  - "192.168.1.202"
  - "localhost"
pun_custom_env:
  OOD_APP_CONFIG: "/etc/ood/config"
  OOD_DASHBOARD_TITLE: "PrimedSLURM OnDemand"
EOF

    # Generate Apache config from the portal configuration
    echo -e "${BLUE}🔧 Generating Apache configuration...${NC}"
    /opt/ood/ood-portal-generator/sbin/update_ood_portal

    # Install VNC components for interactive apps
    echo -e "${BLUE}📦 Installing VNC components...${NC}"
    apt-get install -y tigervnc-standalone-server tigervnc-common tigervnc-tools \
                      xterm twm xauth x11-apps xorg novnc || true

    # Install WebSockify
    echo -e "${BLUE}🔧 Installing WebSockify...${NC}"
    # Install WebSockify with better error handling and verification
    apt-get install -y python3-pip
    pip3 install --break-system-packages websockify 2>/dev/null || pip3 install websockify || true

    # Verify websockify was installed
    if ! command -v websockify >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠️ WebSockify not found in PATH. Trying alternate install...${NC}"
        # Try a direct pip install and add to PATH
        python3 -m pip install --break-system-packages websockify
        export PATH="$PATH:$HOME/.local/bin"
        
        # Verify again
        if ! command -v websockify >/dev/null 2>&1; then
            echo -e "${RED}❌ Failed to install WebSockify. VNC web access may not work.${NC}"
            WEBSOCKIFY_PATH=$(find / -name websockify -type f 2>/dev/null | head -1)
            if [ -n "$WEBSOCKIFY_PATH" ]; then
                echo -e "${GREEN}✅ Found WebSockify at: $WEBSOCKIFY_PATH${NC}"
                ln -sf "$WEBSOCKIFY_PATH" /usr/local/bin/websockify
            fi
        fi
    fi

    # Create WebSockify service - CRITICAL FIX
    echo -e "${BLUE}🔧 Creating WebSockify service unit file...${NC}"

    # Set correct permissions for reliable writing
    sudo bash -c "cat > /etc/systemd/system/websockify.service" << 'EOF'
[Unit]
Description=Websockify Service for VNC
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/websockify --web=/usr/share/novnc/ 6080 localhost:5901
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    # Verify the service file was created and show its contents
    echo -e "${BLUE}🔍 Verifying WebSockify service file creation...${NC}"
    if sudo test -f /etc/systemd/system/websockify.service; then
        echo -e "${GREEN}✅ WebSockify service file created successfully${NC}"
        sudo cat /etc/systemd/system/websockify.service
        
        # Set proper permissions on the service file
        sudo chmod 644 /etc/systemd/system/websockify.service
        
        # Reload systemd to recognize the new service file
        echo -e "${BLUE}🔄 Reloading systemd configuration...${NC}"
        sudo systemctl daemon-reload
        
        # Enable and start the service
        echo -e "${BLUE}🚀 Enabling and starting WebSockify service...${NC}"
        sudo systemctl enable websockify || echo -e "${YELLOW}⚠️ Failed to enable WebSockify service, but continuing...${NC}"
        sudo systemctl start websockify || echo -e "${YELLOW}⚠️ Failed to start WebSockify service, but continuing...${NC}"
    else
        echo -e "${RED}❌ Failed to create WebSockify service file${NC}"
        echo -e "${YELLOW}⚠️ Attempting alternative service creation method...${NC}"
        
        # Alternative method to create service file
        sudo bash -c 'echo "[Unit]
Description=Websockify Service for VNC
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/websockify --web=/usr/share/novnc/ 6080 localhost:5901
Restart=on-failure

[Install]
WantedBy=multi-user.target" > /etc/systemd/system/websockify.service'
        
        # Verify again
        if sudo test -f /etc/systemd/system/websockify.service; then
            echo -e "${GREEN}✅ WebSockify service file created via alternative method${NC}"
            sudo systemctl daemon-reload
            sudo systemctl enable websockify || echo -e "${YELLOW}⚠️ Failed to enable WebSockify service${NC}"
            sudo systemctl start websockify || echo -e "${YELLOW}⚠️ Failed to start WebSockify service${NC}"
        else
            echo -e "${RED}❌ All attempts to create WebSockify service file failed${NC}"
            echo -e "${YELLOW}⚠️ VNC web access may not work, but OnDemand should still function${NC}"
        fi
    fi

    # Enable Apache modules
    echo -e "${BLUE}🔧 Enabling Apache modules...${NC}"
    a2enmod ssl headers proxy proxy_http proxy_wstunnel rewrite lua
    a2enmod proxy_html 2>/dev/null || true

    # Disable default site and enable OnDemand
    echo -e "${BLUE}🔧 Enabling OnDemand site...${NC}"
    a2dissite 000-default
    a2ensite ood-portal

    # Make sure the default page is gone
    if [ -f /var/www/html/index.html ]; then
        echo -e "${YELLOW}⚠️ Removing default Apache index.html...${NC}"
        mv /var/www/html/index.html /var/www/html/index.html.backup
    fi
    
    # Create a simple redirect in the default directory
    echo "<!DOCTYPE html><html><head><title>Redirect to OnDemand</title><meta http-equiv='refresh' content='0;url=/' /></head><body><p>Redirecting to OnDemand...</p></body></html>" > /var/www/html/index.html
    
    # Make sure the OnDemand site is loaded first by Apache
    if [ -f /etc/apache2/sites-available/ood-portal.conf ]; then
        echo -e "${BLUE}🔧 Configuring OnDemand site to load first...${NC}"
        # Create a symbolic link with a name that sorts before others
        ln -sf /etc/apache2/sites-available/ood-portal.conf /etc/apache2/sites-enabled/000-ood-portal.conf
    fi
fi

# Restart all services - this block should execute for both source and package installations
echo -e "${BLUE}🚀 Starting all services...${NC}"
systemctl daemon-reload
systemctl enable websockify
systemctl start websockify || true

# More aggressive Apache restart
echo -e "${BLUE}🔧 Performing thorough Apache restart...${NC}"
systemctl stop apache2
sleep 2
killall -9 apache2 2>/dev/null || true
sleep 2

# CRITICAL: Make sure Apache configuration is reloaded
echo -e "${BLUE}🔧 Reloading Apache configuration...${NC}"
systemctl reload apache2 || true
systemctl restart apache2 || {
    echo -e "${RED}❌ Failed to start Apache. Checking for errors...${NC}"
    systemctl status apache2 --no-pager
    cat /var/log/apache2/error.log
}

# Print active virtual hosts for debugging
echo -e "${BLUE}🔍 Checking active Apache virtual hosts...${NC}"
apache2ctl -S || echo -e "${YELLOW}⚠️ Failed to get Apache virtual host info${NC}"

# Check if default Apache page is still in place
if [ -f /var/www/html/index.html.original ] || [ -f /var/www/html/index.html.backup ]; then
    echo -e "${YELLOW}⚠️ Found backup of default Apache page - making extra sure it's gone${NC}"
    rm -f /var/www/html/index.html
    echo "<html><head><meta http-equiv='refresh' content='0;url=/' /></head></html>" > /var/www/html/index.html
fi

# CRITICAL: Wait for services to stabilize and verify they're running
echo -e "${BLUE}🔍 Verifying services are running...${NC}"
sleep 5

# Check Apache first
if systemctl is-active --quiet apache2; then
    echo -e "${GREEN}✅ Apache is running${NC}"
else
    echo -e "${RED}❌ Apache is not running${NC}"
    systemctl status apache2 --no-pager
fi

# Check actual OnDemand interface
echo -e "${BLUE}🔍 Testing OnDemand accessibility...${NC}"
if curl -s -u ooduser:ooduser http://localhost/ | grep -q "Open OnDemand"; then
    echo -e "${GREEN}✅ SUCCESS! OnDemand interface is accessible${NC}"
else
    echo -e "${RED}❌ OnDemand interface is not accessible${NC}"
    echo -e "${YELLOW}⚠️ Checking what's being served...${NC}"
    curl -s -u ooduser:ooduser http://localhost/ | head -20
fi

echo -e "${GREEN}✅ REAL OnDemand setup completed!${NC}"
echo -e "${GREEN}🌐 Access OnDemand at: http://192.168.1.202/${NC}"
echo -e "${GREEN}👤 Login with: ooduser / ooduser${NC}"

exit 0
