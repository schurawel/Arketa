#!/bin/bash
# Simple Open OnDemand setup script

# Parse command line arguments
LINEAR_MODE=false
for arg in "$@"; do
    case $arg in
        --linear-setup)
            LINEAR_MODE=true
            echo "Running in linear setup mode - skipping non-essential tests"
            ;;
    esac
done

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}Setting up Open OnDemand (Simple Version)${NC}"

# Function for error handling
handle_error() {
  if [ "$LINEAR_MODE" = "true" ]; then
    echo -e "${YELLOW}WARNING (linear mode): $1${NC}" >&2
    return 0
  else
    echo -e "${RED}ERROR: $1${NC}" >&2
    exit 1
  fi
}

# 1. Install Apache and basic packages
echo -e "${YELLOW}Installing Apache and basic packages...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y apache2 apache2-dev ruby-full nodejs npm git curl wget locales || handle_error "Failed to install basic packages"

# Fix locale issues
echo -e "${YELLOW}Fixing locale settings...${NC}"
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8

# Fix Apache ServerName issue
echo -e "${YELLOW}Configuring Apache ServerName...${NC}"
echo "ServerName slurm-controller" | tee -a /etc/apache2/apache2.conf

# Ensure Apache is listening on port 80
echo -e "${YELLOW}Configuring Apache ports...${NC}"
grep -q "Listen 80" /etc/apache2/ports.conf || echo "Listen 80" >> /etc/apache2/ports.conf

# 2. Install OnDemand using official packages
echo -e "${YELLOW}📦 Installing OnDemand...${NC}"
# Add OnDemand repository for Ubuntu 24.04
if [ ! -f /etc/apt/sources.list.d/ondemand-web.list ]; then
    echo -e "${YELLOW}� Adding OnDemand repository...${NC}"
    wget -O /tmp/ondemand-release-web.gpg https://yum.osc.edu/ondemand/latest/ondemand-release-web.gpg || {
        echo -e "${RED}⚠️ WARNING (linear mode): Failed to download OnDemand GPG key${NC}"
        # Continue without official packages, we'll create basic setup
        ONDEMAND_INSTALL_FAILED=true
    }
    
    if [ "$ONDEMAND_INSTALL_FAILED" != "true" ]; then
        # Convert GPG key and add repository
        gpg --dearmor < /tmp/ondemand-release-web.gpg > /etc/apt/trusted.gpg.d/ondemand-web.gpg
        echo "deb https://apt.osc.edu/ondemand/latest/ubuntu24.04/ ubuntu24.04 main" > /etc/apt/sources.list.d/ondemand-web.list
        apt update
        
        # Try to install OnDemand packages
        if apt install -y ondemand ondemand-apache ondemand-nginx; then
            echo -e "${GREEN}✅ OnDemand packages installed successfully${NC}"
            ONDEMAND_PACKAGES_INSTALLED=true
        else
            echo -e "${RED}⚠️ WARNING (linear mode): Failed to install OnDemand packages${NC}"
            ONDEMAND_INSTALL_FAILED=true
        fi
    fi
else
    # Check if OnDemand is already installed
    if dpkg -l | grep -q ondemand; then
        echo -e "${GREEN}✅ OnDemand packages already installed${NC}"
        ONDEMAND_PACKAGES_INSTALLED=true
    else
        echo -e "${RED}⚠️ WARNING (linear mode): OnDemand repository exists but packages not installed${NC}"
        ONDEMAND_INSTALL_FAILED=true
    fi
fi

# If official packages failed, create minimal setup
if [ "$ONDEMAND_INSTALL_FAILED" = "true" ]; then
    echo -e "${YELLOW}� Creating minimal OnDemand-like portal...${NC}"
    
    # Create basic directory structure
    mkdir -p /var/www/ood/{public,apps/sys}
    mkdir -p /etc/ood/config
    
    # Create basic index page
    cat > /var/www/ood/public/index.html << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>SLURM Web Portal</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; }
        h1 { color: #0066cc; }
        .status { background: #f0f8ff; padding: 20px; margin: 20px 0; border-radius: 5px; }
        .link { margin: 10px 0; }
        a { color: #0066cc; text-decoration: none; }
        a:hover { text-decoration: underline; }
    </style>
</head>
<body>
    <h1>🖥️ SLURM Cluster Web Portal</h1>
    <div class="status">
        <h2>Cluster Status</h2>
        <p>Welcome to the SLURM cluster web interface.</p>
        <div class="link"><a href="/cluster-status.php">📊 View Cluster Status</a></div>
        <div class="link"><a href="/job-submission.php">🚀 Submit Jobs</a></div>
        <div class="link"><a href="/slurm-web/" target="_blank">📈 SLURM Web Interface</a></div>
    </div>
</body>
</html>
EOF

    # Create PHP scripts for basic functionality
    apt install -y php libapache2-mod-php
    
    # Enable PHP module
    a2enmod php8.3 2>/dev/null || a2enmod php8.2 2>/dev/null || a2enmod php8.1 2>/dev/null || a2enmod php
    
    # Create cluster status script
    cat > /var/www/ood/public/cluster-status.php << 'EOF'
<?php
echo "<h1>SLURM Cluster Status</h1>";
echo "<pre>";
echo "Node Information:
";
system("/opt/slurm/bin/sinfo 2>&1");
echo "

Job Queue:
";
system("/opt/slurm/bin/squeue 2>&1");
echo "</pre>";
echo '<p><a href="index.html">← Back to Portal</a></p>';
?>
EOF

    # Create job submission form
    cat > /var/www/ood/public/job-submission.php << 'EOF'
<?php
if ($_POST['submit_job']) {
    $job_name = escapeshellarg($_POST['job_name']);
    $script_content = $_POST['script_content'];
    
    $temp_file = "/tmp/web_job_" . uniqid() . ".sh";
    file_put_contents($temp_file, $script_content);
    chmod($temp_file, 0755);
    
    $output = shell_exec("/opt/slurm/bin/sbatch $temp_file 2>&1");
    echo "<h1>Job Submission Result</h1>";
    echo "<pre>$output</pre>";
    echo '<p><a href="job-submission.php">← Submit Another Job</a></p>';
    echo '<p><a href="index.html">← Back to Portal</a></p>';
} else {
?>
<h1>Submit SLURM Job</h1>
<form method="post">
    <p>Job Name: <input type="text" name="job_name" value="web_job" required></p>
    <p>Job Script:</p>
    <textarea name="script_content" rows="15" cols="80" required>#!/bin/bash
#SBATCH --job-name=web_job
#SBATCH --output=web_job.out
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --time=00:05:00

echo "Job started at: $(date)"
hostname
echo "Job completed at: $(date)"
</textarea>
    <br><br>
    <input type="submit" name="submit_job" value="Submit Job">
</form>
<p><a href="index.html">← Back to Portal</a></p>
<?php } ?>
EOF
    
    ONDEMAND_PACKAGES_INSTALLED=false
fi

# 3. Create simple configuration
echo -e "${YELLOW}🔧 Creating basic OnDemand configuration...${NC}"
mkdir -p /etc/ood/config/clusters.d

# Create cluster configuration
cat > /etc/ood/config/clusters.d/slurm.yml << 'EOF'
---
v2:
  metadata:
    title: "SLURM Cluster"
  login:
    host: "slurm-controller"
  job:
    adapter: "slurm"
    bin: "/opt/slurm/bin"
    conf: "/etc/slurm/slurm.conf"
EOF

# 4. Create basic portal configuration
echo -e "${YELLOW}🔧 Creating portal configuration...${NC}"
cat > /etc/ood/config/ood_portal.yml << 'EOF'
---
listen_addr_port: 80
servername: slurm-controller
logroot: '/var/log/ondemand-nginx'

# Use basic authentication
auth:
  - 'AuthType Basic'
  - 'AuthName "Open OnDemand"'
  - 'AuthBasicProvider file'
  - 'AuthUserFile /etc/ood/config/htpasswd'
  - 'Require valid-user'

# Basic SSL redirect (optional)
use_rewrites: true
EOF

# 5. Create user for testing
echo -e "${YELLOW}👤 Creating test user...${NC}"
mkdir -p /etc/ood/config
htpasswd -b -c /etc/ood/config/htpasswd ooduser ooduser

# 6. Generate Apache configuration
echo -e "${YELLOW}🔧 Generating Apache configuration...${NC}"
if command -v /opt/ood/ood-portal-generator/sbin/update_ood_portal >/dev/null 2>&1; then
    /opt/ood/ood-portal-generator/sbin/update_ood_portal || {
        echo -e "${YELLOW}⚠️ WARNING: OnDemand portal generator failed, using basic config${NC}"
        # Create a basic portal configuration
        cat > /etc/apache2/sites-available/ood-portal.conf << 'EOF'
<VirtualHost *:80>
    ServerName slurm-controller
    DocumentRoot /var/www/html
    
    <Directory "/var/www/html">
        AllowOverride None
        Require all granted
    </Directory>
    
    ErrorLog ${APACHE_LOG_DIR}/ood_error.log
    CustomLog ${APACHE_LOG_DIR}/ood_access.log combined
</VirtualHost>
EOF
    }
else
    echo -e "${YELLOW}⚠️ WARNING: OnDemand portal generator not found, creating basic config${NC}"
    # Create a basic portal configuration
    cat > /etc/apache2/sites-available/ood-portal.conf << 'EOF'
<VirtualHost *:80>
    ServerName slurm-controller
    DocumentRoot /var/www/html
    
    <Directory "/var/www/html">
        AllowOverride None
        Require all granted
    </Directory>
    
    ErrorLog ${APACHE_LOG_DIR}/ood_error.log
    CustomLog ${APACHE_LOG_DIR}/ood_access.log combined
</VirtualHost>
EOF
fi

# 7. Enable required Apache modules
echo -e "${YELLOW}🔧 Enabling Apache modules...${NC}"
a2enmod rewrite
a2enmod ssl
a2enmod headers

# 8. Enable OnDemand site and disable default
echo -e "${YELLOW}🔧 Configuring Apache sites...${NC}"
a2dissite 000-default || true
a2ensite ood-portal

# 9. Start Apache
echo -e "${YELLOW}🛠️ Starting Apache...${NC}"

# Create a basic virtual host if OnDemand portal generation failed
if [ ! -f /etc/apache2/sites-available/ood-portal.conf ]; then
    echo -e "${YELLOW}🔧 Creating fallback Apache configuration...${NC}"
    cat > /etc/apache2/sites-available/ood-portal.conf << 'EOF'
<VirtualHost *:80>
    ServerName slurm-controller
    DocumentRoot /var/www/html
    
    <Directory "/var/www/html">
        AllowOverride None
        Require all granted
    </Directory>
    
    # Basic portal page
    Alias /ondemand /var/www/ood
    <Directory "/var/www/ood">
        AllowOverride None
        Require all granted
    </Directory>
    
    ErrorLog ${APACHE_LOG_DIR}/ood_error.log
    CustomLog ${APACHE_LOG_DIR}/ood_access.log combined
</VirtualHost>
EOF
fi

# Ensure Apache is listening on port 80
if ! grep -q "Listen 80" /etc/apache2/ports.conf; then
    echo "Listen 80" >> /etc/apache2/ports.conf
fi

systemctl enable apache2
systemctl restart apache2 || {
  echo -e "${RED}❌ Apache failed to start. Checking configuration...${NC}"
  apache2ctl configtest
  systemctl status apache2 --no-pager
  handle_error "Apache failed to start"
}

# 10. Create basic desktop app (simplified)
echo -e "${YELLOW}🖥️ Setting up basic desktop app...${NC}"
mkdir -p /var/www/ood/apps/sys/bc_desktop/template

cat > /var/www/ood/apps/sys/bc_desktop/manifest.yml << 'EOF'
---
name: Desktop
category: Interactive Apps
subcategory: Desktops
role: batch_connect
description: |
  Launch a desktop session on the cluster
EOF

cat > /var/www/ood/apps/sys/bc_desktop/form.yml << 'EOF'
---
cluster: slurm
attributes:
  bc_num_hours:
    value: 1
  bc_num_slots:
    value: 1
  bc_desktop: xfce
EOF

cat > /var/www/ood/apps/sys/bc_desktop/submit.yml.erb << 'EOF'
---
batch_connect:
  template: "basic"
script:
  native:
    - "-t"
    - "01:00:00"
    - "-n"
    - "1"
EOF

cat > /var/www/ood/apps/sys/bc_desktop/template/script.sh.erb << 'EOF'
#!/bin/bash

# Start VNC server
export DISPLAY=:1
vncserver :1 -geometry 1024x768 -depth 24

# Wait for VNC to start
sleep 5

# Create connection info for OnDemand
echo "password" > password.txt
echo "display" > display.txt
echo ":1" >> display.txt
echo "1" > port.txt
echo "5901" >> port.txt
EOF

# Set proper permissions (Ubuntu uses www-data, not apache)
chown -R www-data:www-data /var/www/ood/apps 2>/dev/null || chown -R apache:apache /var/www/ood/apps 2>/dev/null || {
    echo -e "${YELLOW}⚠️ WARNING: Could not set ownership on OnDemand apps directory${NC}"
}

echo -e "${GREEN}✅ Open OnDemand setup complete!${NC}"
echo -e "${YELLOW}📋 Access the portal at: http://192.168.1.202/${NC}"
echo -e "${YELLOW}👤 Login credentials: ooduser / ooduser${NC}"

# Test the setup
if [ "$LINEAR_MODE" != "true" ]; then
    echo -e "${YELLOW}🧪 Testing Apache configuration...${NC}"
    if systemctl is-active --quiet apache2; then
        echo -e "${GREEN}✅ Apache is running${NC}"
    else
        echo -e "${RED}❌ Apache is not running${NC}"
    fi
    
    echo -e "${YELLOW}🧪 Testing OnDemand configuration...${NC}"
    if [ -f /etc/ood/config/clusters.d/slurm.yml ]; then
        echo -e "${GREEN}✅ Cluster configuration exists${NC}"
    else
        echo -e "${RED}❌ Cluster configuration missing${NC}"
    fi
fi

echo -e "${GREEN}🎉 Simple OnDemand setup complete!${NC}"
  bc_num_hours:
    value: 1
  bc_num_slots:
    value: 1
  bc_desktop: xfce
EOF

cat > /var/www/ood/apps/sys/bc_desktop/submit.yml.erb << 'EOF'
---
batch_connect:
  template: "basic"
script:
  native:
    - "-t"
    - "01:00:00"
    - "-n"
    - "1"
EOF

cat > /var/www/ood/apps/sys/bc_desktop/template/script.sh.erb << 'EOF'
#!/bin/bash

# Start VNC server
export DISPLAY=:1
vncserver :1 -geometry 1024x768 -depth 24

# Wait for VNC to start
sleep 5

# Create connection info for OnDemand
echo "password" > password.txt
echo "display" > display.txt
echo ":1" >> display.txt
echo "1" > port.txt
echo "5901" >> port.txt
EOF

# Set proper permissions (Ubuntu uses www-data, not apache)
chown -R www-data:www-data /var/www/ood/apps 2>/dev/null || chown -R apache:apache /var/www/ood/apps 2>/dev/null || {
    echo -e "${YELLOW}⚠️ WARNING: Could not set ownership on OnDemand apps directory${NC}"
}

echo -e "${GREEN}✅ Open OnDemand setup complete!${NC}"
echo -e "${YELLOW}📋 Access the portal at: http://192.168.1.202/${NC}"
echo -e "${YELLOW}👤 Login credentials: ooduser / ooduser${NC}"

# Test the setup
if [ "$LINEAR_MODE" != "true" ]; then
    echo -e "${YELLOW}🧪 Testing Apache configuration...${NC}"
    if systemctl is-active --quiet apache2; then
        echo -e "${GREEN}✅ Apache is running${NC}"
    else
        echo -e "${RED}❌ Apache is not running${NC}"
    fi
    
    echo -e "${YELLOW}🧪 Testing OnDemand configuration...${NC}"
    if [ -f /etc/ood/config/clusters.d/slurm.yml ]; then
        echo -e "${GREEN}✅ Cluster configuration exists${NC}"
    else
        echo -e "${RED}❌ Cluster configuration missing${NC}"
    fi
fi

echo -e "${GREEN}🎉 Simple OnDemand setup complete!${NC}"
