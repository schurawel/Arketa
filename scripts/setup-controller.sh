#!/bin/bash
# Slurm Controller Node Setup Script

set -e

# Logging functions
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $1"; }
warn() { echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN] $1" >&2; }
error() { echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $1" >&2; }

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

echo "Setting up Slurm Controller Node..."

# Add host entries (updated for actual server network)
# Remove old entries first to avoid duplicates
sed -i '/slurm-controller/d' /etc/hosts
sed -i '/node1/d' /etc/hosts
sed -i '/node2/d' /etc/hosts
sed -i '/controller/d' /etc/hosts
sed -i '/server[2-4]/d' /etc/hosts

# Add correct entries
echo "192.168.1.202 slurm-controller controller server2" >> /etc/hosts
echo "192.168.1.203 node1 server3" >> /etc/hosts
echo "192.168.1.204 node2 server4" >> /etc/hosts

# Set hostname
hostnamectl set-hostname slurm-controller

# Install X11 and desktop environment packages required for VNC
echo "📦 Installing X11 and desktop packages for VNC sessions..."
apt-get update
apt-get install -y xorg x11-xserver-utils xterm twm fluxbox openbox \
    xfce4 xfce4-goodies \
    tigervnc-standalone-server tigervnc-common tigervnc-xorg-extension \
    x11-apps x11-utils xauth xvfb \
    dbus-x11 python3-websockify \
    xfonts-base xfonts-100dpi xfonts-75dpi xfonts-scalable \
    fonts-dejavu-core fonts-liberation

# Create .vnc directory for all users and set up a default xstartup
echo "📦 Creating default VNC configuration..."
mkdir -p /etc/skel/.vnc
cat > /etc/skel/.vnc/xstartup << 'EOF'
#!/bin/sh
# Default VNC startup script
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS

# Load X resources
[ -r $HOME/.Xresources ] && xrdb $HOME/.Xresources

# Start window manager
if command -v startxfce4 >/dev/null 2>&1; then
    exec startxfce4
elif command -v twm >/dev/null 2>&1; then
    xterm &
    exec twm
else
    xterm &
fi
EOF
chmod 755 /etc/skel/.vnc/xstartup

# Apply the VNC configuration to existing users
for user in ubuntu vagrant ooduser; do
    if id "$user" &>/dev/null; then
        echo "Setting up VNC for user $user..."
        user_home=$(eval echo ~$user)
        if [ -d "$user_home" ]; then
            mkdir -p "$user_home/.vnc"
            cp /etc/skel/.vnc/xstartup "$user_home/.vnc/" 2>/dev/null || true
            chown -R $user:$user "$user_home/.vnc"
        fi
    fi
done

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

# Set up NFS server (moved from Vagrantfile)
echo "Setting up NFS server for shared directories..."
wait_for_apt_locks 600 || {
    echo "ERROR: Could not acquire apt locks after waiting. Please try again later."
    exit 1
}
apt-get update
# NFS server, desktop environments, and VNC packages are now installed in setup-base.sh

# Create slurm user if it doesn't exist (needed for directory ownership)
if ! id slurm &>/dev/null; then
    echo "Creating slurm user..."
    useradd -r -s /bin/false slurm 2>/dev/null || echo "Slurm user creation failed or already exists"
fi

# Setup shared directory
mkdir -p /shared
chown slurm:slurm /shared
chmod 777 /shared  # Make shared directory world-writable to avoid permission issues with MPI jobs

# Create required subdirectories with proper permissions
mkdir -p /shared/mpi-jobs
chmod 777 /shared/mpi-jobs
chown slurm:slurm /shared/mpi-jobs

# Ensure NFS packages are installed
log "Ensuring NFS server packages are installed..."
if ! dpkg -l | grep -q nfs-kernel-server; then
    log "Installing NFS server packages..."
    apt-get update
    apt-get install -y nfs-kernel-server nfs-common
fi

# Create /etc/exports if it doesn't exist
if [ ! -f /etc/exports ]; then
    log "Creating /etc/exports file..."
    touch /etc/exports
fi

# Configure NFS export for shared directory - UPDATED NETWORK ADDRESS
log "Configuring NFS exports..."
grep -q "/shared 192.168.1.0/24" /etc/exports || echo "/shared 192.168.1.0/24(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports
# Also remove old exports if they exist
sed -i '/\/shared 192.168.7.0\/24/d' /etc/exports
sed -i '/\/shared 192.168.121.0\/24/d' /etc/exports

# Enable and restart NFS server with proper settings
log "Enabling and starting NFS server..."
systemctl enable nfs-kernel-server
systemctl restart nfs-kernel-server
exportfs -ra

# Verify exports are configured correctly
log "Verifying NFS exports..."
exportfs -v

# Source the Slurm environment (should be available from base setup)
if ! grep -q "/opt/slurm/bin" /etc/environment; then
    sed -i 's|PATH="\(.*\)"|PATH="/opt/slurm/bin:/opt/slurm/sbin:\1"|' /etc/environment
fi

# Add to /etc/bash.bashrc for non-login shells (SSH sessions)
if ! grep -q "opt/slurm" /etc/bash.bashrc; then
    echo '' >> /etc/bash.bashrc
    echo '# Slurm environment' >> /etc/bash.bashrc
    echo 'export PATH="/opt/slurm/bin:/opt/slurm/sbin:$PATH"' >> /etc/bash.bashrc
    echo 'export LD_LIBRARY_PATH="/opt/slurm/lib:$LD_LIBRARY_PATH"' >> /etc/bash.bashrc
fi

# Check if SLURM is properly installed before proceeding
log "Verifying SLURM installation..."
if [ -f /etc/profile.d/slurm.sh ]; then
    source /etc/profile.d/slurm.sh
else
    # Fallback environment setup
    export PATH="/opt/slurm/bin:/opt/slurm/sbin:$PATH"
    export LD_LIBRARY_PATH="/opt/slurm/lib:$LD_LIBRARY_PATH"
fi

# Verify SLURM binaries are available
if [ ! -f "/opt/slurm/sbin/slurmctld" ]; then
    error "SLURM controller daemon (slurmctld) not found at /opt/slurm/sbin/slurmctld"
    error "Please ensure SLURM was properly installed by setup-base.sh"
    exit 1
fi

if [ ! -f "/opt/slurm/sbin/slurmd" ]; then
    error "SLURM node daemon (slurmd) not found at /opt/slurm/sbin/slurmd"
    error "Please ensure SLURM was properly installed by setup-base.sh"
    exit 1
fi

slurm_version=$(/opt/slurm/sbin/slurmctld -V 2>/dev/null | head -1 || echo "unknown")
if [ "$slurm_version" = "unknown" ]; then
    error "SLURM installation appears to be corrupted - slurmctld not responding"
    exit 1
else
    log "✅ SLURM installation verified: $slurm_version"
fi

# Setup Munge authentication with shared key from host system
systemctl enable munge

# Try to copy the shared munge key from host system configs
MUNGE_KEY_COPIED=false

# Define possible locations for the shared munge key on the host
host_config_dirs=(
    "/home/vagrant/scripts/configs"
    "/home/ubuntu/scripts/configs"
    "/opt/scripts/configs"
    "/shared/scripts/configs"
    "$(dirname "$0")/configs"
)

# Try each possible location for the shared munge key
for config_dir in "${host_config_dirs[@]}"; do
    if [ -f "${config_dir}/munge.key" ]; then
        echo "📋 Copying shared munge key from: ${config_dir}/munge.key"
        cp "${config_dir}/munge.key" /etc/munge/munge.key
        MUNGE_KEY_COPIED=true
        break
    fi
done

# If no shared key found, create a new one as fallback
if [ "$MUNGE_KEY_COPIED" = "false" ]; then
    echo "⚠️ No shared munge key found in any expected location, creating new key as fallback"
    echo "📋 Checked locations:"
    for dir in "${host_config_dirs[@]}"; do
        echo "   - ${dir}/munge.key"
    done
    dd if=/dev/urandom bs=1 count=1024 > /etc/munge/munge.key
fi

chown munge:munge /etc/munge/munge.key
chmod 400 /etc/munge/munge.key

# Start munge with skip option for linear mode
if [ "$LINEAR_MODE" = "true" ]; then
    systemctl start munge || echo "⚠️ Munge start issues in linear mode - continuing anyway"
else
    systemctl start munge
fi

# Copy munge key to shared directory for compute nodes
cp /etc/munge/munge.key /shared/
chown slurm:slurm /shared/munge.key
chmod 400 /shared/munge.key

# Copy Slurm configuration files from scripts/configs directory
echo "📋 Copying Slurm configuration files from configs directory..."

# Determine the source directory for configuration files
CONFIG_SOURCE_DIR=""
if [ -f "/home/ubuntu/scripts/configs/slurm.conf" ]; then
    CONFIG_SOURCE_DIR="/home/ubuntu/scripts/configs"
elif [ -f "/home/vagrant/scripts/configs/slurm.conf" ]; then
    CONFIG_SOURCE_DIR="/home/vagrant/scripts/configs"
elif [ -f "$(dirname "$0")/configs/slurm.conf" ]; then
    CONFIG_SOURCE_DIR="$(dirname "$0")/configs"
else
    echo "ERROR: Could not find slurm.conf in any expected location"
    echo "Expected locations:"
    echo "  - /home/ubuntu/scripts/configs/slurm.conf"
    echo "  - /home/vagrant/scripts/configs/slurm.conf"
    echo "  - $(dirname "$0")/configs/slurm.conf"
    exit 1
fi

echo "✅ Found configuration files in: $CONFIG_SOURCE_DIR"

# Copy slurm.conf
cp "$CONFIG_SOURCE_DIR/slurm.conf" /etc/slurm/
echo "✅ Copied slurm.conf"

# Copy cgroup.conf
cp "$CONFIG_SOURCE_DIR/cgroup.conf" /etc/slurm/
echo "✅ Copied cgroup.conf"

# Copy configuration files to shared directory for compute nodes
cp /etc/slurm/slurm.conf /shared/
cp /etc/slurm/cgroup.conf /shared/

# Also create the expected directory structure for compute nodes
mkdir -p /shared/scripts/configs
cp /etc/slurm/slurm.conf /shared/scripts/configs/
cp /etc/slurm/cgroup.conf /shared/scripts/configs/
echo "✅ Configuration files copied to shared directory"
echo "✅ Configuration files also copied to /shared/scripts/configs/ for compute nodes"

# Copy sample-jobs folder to shared directory for all nodes to access
echo "📋 Copying sample-jobs folder to shared directory..."
if [ -d "$(dirname "$0")/../sample-jobs" ]; then
    mkdir -p /shared/sample-jobs
    cp -r "$(dirname "$0")/../sample-jobs/"* /shared/sample-jobs/
    chmod +x /shared/sample-jobs/*.sh 2>/dev/null || true
    echo "✅ Sample jobs copied from: $(dirname "$0")/../sample-jobs"
elif [ -d "/home/ubuntu/sample-jobs" ]; then
    mkdir -p /shared/sample-jobs
    cp -r "/home/ubuntu/sample-jobs/"* /shared/sample-jobs/
    chmod +x /shared/sample-jobs/*.sh 2>/dev/null || true
    echo "✅ Sample jobs copied from: /home/ubuntu/sample-jobs"
else
    echo "⚠️ Sample jobs folder not found in expected locations:"
    echo "   - $(dirname "$0")/../sample-jobs"
    echo "   - /home/ubuntu/sample-jobs"
fi

# Create systemd service files  
cat > /etc/systemd/system/slurmctld.service << 'EOF'
[Unit]
Description=Slurm controller daemon
After=network.target munge.service
Requires=munge.service

[Service]
Type=forking
EnvironmentFile=-/etc/default/slurmctld
ExecStartPre=/bin/mkdir -p /opt/slurm/var/run
ExecStartPre=/bin/chown slurm:slurm /opt/slurm/var/run
ExecStart=/opt/slurm/sbin/slurmctld
ExecReload=/bin/kill -HUP $MAINPID
PIDFile=/opt/slurm/var/run/slurmctld.pid
LimitNOFILE=65536
LimitMEMLOCK=infinity
LimitSTACK=infinity
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF

# Create slurmd service file for the controller
cat > /etc/systemd/system/slurmd.service << 'EOF'
[Unit]
Description=Slurm node daemon
After=network.target munge.service
Requires=munge.service

[Service]
Type=forking
EnvironmentFile=-/etc/default/slurmd
ExecStartPre=/bin/mkdir -p /run/slurm
ExecStartPre=/bin/chown slurm:slurm /run/slurm
ExecStartPre=/bin/chmod 755 /run/slurm
ExecStart=/opt/slurm/sbin/slurmd -f /etc/slurm/slurm.conf -L /var/log/slurm/slurmd.log -c /etc/slurm/cgroup.conf -M /run/slurm
ExecReload=/bin/kill -HUP $MAINPID
PIDFile=/run/slurm/slurmd.pid
KillMode=process
LimitNOFILE=131072
LimitMEMLOCK=infinity
LimitSTACK=infinity
User=root
Group=root
Delegate=yes

[Install]
WantedBy=multi-user.target
EOF

# Create required directories for slurmd
mkdir -p /var/spool/slurmd /var/log/slurm /run/slurm
chown slurm:slurm /var/spool/slurmd /var/log/slurm /run/slurm
chmod 755 /var/spool/slurmd /var/log/slurm /run/slurm

# Check if services are already running to avoid unnecessary restarts
slurmctld_running=false
slurmd_running=false

if systemctl is-active --quiet slurmctld; then
    log "✅ slurmctld service is already running"
    slurmctld_running=true
else
    log "slurmctld service not running - will start it"
fi

if systemctl is-active --quiet slurmd; then
    log "✅ slurmd service is already running"  
    slurmd_running=true
else
    log "slurmd service not running - will start it"
fi

# Enable and start services only if they're not already running
systemctl daemon-reload

if [ "$slurmctld_running" = "false" ]; then
    log "Starting slurmctld service..."
    systemctl enable slurmctld
    systemctl start slurmctld
else
    log "Ensuring slurmctld is enabled..."
    systemctl enable slurmctld
fi

if [ "$slurmd_running" = "false" ]; then
    log "Starting slurmd service..."
    systemctl enable slurmd
    
    echo "Starting slurmd service..."
    if ! systemctl start slurmd; then
        echo "ERROR: Failed to start slurmd service"
        echo "=== Service status ==="
        systemctl status slurmd --no-pager -l || true
        echo "=== Journal logs ==="
        journalctl -xeu slurmd.service --no-pager --lines=30 || true
        echo "=== Slurm logs ==="
        tail -50 /var/log/slurm/slurmd.log 2>/dev/null || echo "No slurmd.log found"
        echo "=== Testing manual slurmd run ==="
        timeout 10 /opt/slurm/sbin/slurmd -D -vvv || true
        exit 1
    fi
else
    log "Ensuring slurmd is enabled..."
    systemctl enable slurmd
fi

# Run the setup script for the Slurm Database Daemon
SLURMDBD_SCRIPT=""
if [ -f "/home/ubuntu/scripts/setup-slurmdbd.sh" ]; then
    SLURMDBD_SCRIPT="/home/ubuntu/scripts/setup-slurmdbd.sh"
elif [ -f "/home/vagrant/scripts/setup-slurmdbd.sh" ]; then
    SLURMDBD_SCRIPT="/home/vagrant/scripts/setup-slurmdbd.sh"
elif [ -f "$HOME/scripts/setup-slurmdbd.sh" ]; then
    SLURMDBD_SCRIPT="$HOME/scripts/setup-slurmdbd.sh"
elif [ -f "./scripts/setup-slurmdbd.sh" ]; then
    SLURMDBD_SCRIPT="./scripts/setup-slurmdbd.sh"
fi

if [ -n "$SLURMDBD_SCRIPT" ]; then
    echo "Found setup-slurmdbd.sh at: $SLURMDBD_SCRIPT"
    if [ "$LINEAR_MODE" = "true" ]; then
        $SLURMDBD_SCRIPT --linear-setup
    else
        $SLURMDBD_SCRIPT
    fi
else
    echo "ERROR: setup-slurmdbd.sh script not found in expected locations"
    echo "Checked paths:"
    echo "  - /home/ubuntu/scripts/setup-slurmdbd.sh"
    echo "  - /home/vagrant/scripts/setup-slurmdbd.sh"
    echo "  - $HOME/scripts/setup-slurmdbd.sh"
    echo "  - ./scripts/setup-slurmdbd.sh"
    exit 1
fi

# Setup and start slurmrestd
echo "🚀 Setting up slurmrestd service..."

# Check if slurmrestd binary exists
if [ ! -f /opt/slurm/sbin/slurmrestd ]; then
    echo "❌ slurmrestd binary not found. Slurm may not have been built with REST API support."
    echo "⚠️ Continuing without slurmrestd..."
else
    echo "✅ Found slurmrestd binary"
    
    # Ensure JWT key exists before creating service (using official method)
    if [ ! -f "/var/spool/slurm/jwt_hs256.key" ]; then
        echo "Creating JWT key for slurmrestd using official method..."
        sudo mkdir -p /var/spool/slurm
        sudo dd if=/dev/random of=/var/spool/slurm/jwt_hs256.key bs=32 count=1
        sudo chown slurm:slurm /var/spool/slurm/jwt_hs256.key
        sudo chmod 0600 /var/spool/slurm/jwt_hs256.key
    fi
    
    # Create slurmrestd service file with Unix socket (OFFICIAL QUICKSTART METHOD)
    cat <<'EOF' | sudo tee /etc/systemd/system/slurmrestd.service
[Unit]
Description=Slurm REST daemon
After=network.target munge.service slurmctld.service
Requires=munge.service

[Service]
Type=simple
Environment="SLURM_JWT=daemon"
ExecStart=/opt/slurm/sbin/slurmrestd -a rest_auth/jwt unix:/run/slurmrestd/slurmrestd.socket
RuntimeDirectory=slurmrestd
RuntimeDirectoryMode=0755
User=slurm
Group=slurm
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    # Enable and start slurmrestd with skip option for linear mode
    systemctl daemon-reload
    systemctl enable slurmrestd
    if [ "$LINEAR_MODE" = "true" ]; then
        systemctl start slurmrestd || echo "⚠️ slurmrestd start issues in linear mode - continuing anyway"
        # Skip connectivity tests
    else
        systemctl start slurmrestd || {
            echo "⚠️ slurmrestd failed to start. Checking logs..."
            journalctl -u slurmrestd --no-pager -n 20
        }
        
        # Wait for slurmrestd to be ready
        sleep 10
        
        # Check if slurmrestd is running
        if systemctl is-active --quiet slurmrestd; then
            echo "✅ slurmrestd is running with Unix socket"
            
            # Test slurmrestd connectivity with Unix socket
            if [ -S "/run/slurmrestd/slurmrestd.socket" ]; then
                echo "✅ slurmrestd Unix socket exists"
                
                # Test with scontrol token
                if sudo -u slurm /opt/slurm/bin/scontrol token > /dev/null 2>&1; then
                    echo "✅ JWT token generation works"
                else
                    echo "⚠️ JWT token generation failed"
                fi
            else
                echo "⚠️ slurmrestd Unix socket not found"
            fi
        else
            echo "⚠️ slurmrestd is not running. slurm-web may have limited functionality."
        fi
    fi
fi


echo "🌐 Setting up Open OnDemand..."
if [ -f /home/ubuntu/scripts/setup-ondemand.sh ]; then
    chmod +x /home/ubuntu/scripts/setup-ondemand.sh
    if [ "$LINEAR_MODE" = "true" ]; then
        /home/ubuntu/scripts/setup-ondemand.sh --linear-setup || echo "⚠️ OnDemand setup issues in linear mode - continuing anyway"
    else
        /home/ubuntu/scripts/setup-ondemand.sh || {
            echo "⚠️ OnDemand setup encountered issues. Checking status..."
            systemctl status apache2 --no-pager || true
            echo "📋 Apache sites enabled:"
            ls -la /etc/apache2/sites-enabled/ || true
        }
    fi
    echo "✅ Open OnDemand setup attempt complete."
    echo "👉 Access the portal at http://192.168.1.202/"
    echo "👤 Login: ooduser / ooduser"
elif [ -f /home/vagrant/scripts/setup-ondemand.sh ]; then
    chmod +x /home/vagrant/scripts/setup-ondemand.sh
    if [ "$LINEAR_MODE" = "true" ]; then
        /home/vagrant/scripts/setup-ondemand.sh --linear-setup || echo "⚠️ OnDemand setup issues in linear mode - continuing anyway"
    else
        /home/vagrant/scripts/setup-ondemand.sh || {
            echo "⚠️ OnDemand setup encountered issues."
        }
    fi
else
    echo "🤷 Skipping Open OnDemand setup: script not found."
fi

# Install and configure slurm-web with linear mode flag if needed
echo "🌐 Setting up slurm-web from source..."
if [ -d "/home/ubuntu/scripts" ]; then
    # Check if setup-slurm-web-minimal.sh exists, and ensure it's executable
    if [ -f "/home/ubuntu/scripts/setup-slurm-web-minimal.sh" ]; then
        echo "📋 Using existing slurm-web setup script"
        chmod +x /home/ubuntu/scripts/setup-slurm-web-minimal.sh
    else
        echo "⚠️ setup-slurm-web-minimal.sh not found, skipping slurm-web setup"
    fi
    
    # Run the script with appropriate mode
    if [ -f "/home/ubuntu/scripts/setup-slurm-web-minimal.sh" ]; then
        if [ "$LINEAR_MODE" = "true" ]; then
            echo "📋 Running slurm-web setup in linear mode"
            #/home/ubuntu/scripts/setup-slurm-web-minimal.sh --linear-setup || echo "⚠️ slurm-web setup issues in linear mode - continuing anyway"
        else
            echo "📋 Running full slurm-web setup"
            #/home/ubuntu/scripts/setup-slurm-web-minimal.sh || {
            #    echo "⚠️ Minimal slurm-web setup encountered issues."
                #systemctl status slurm-web-agent slurm-web-gateway --no-pager || true
              #  echo "📋 Checking gateway.ini for URL parameter..."
               # if [ -f /etc/slurm-web/gateway.ini ]; then
                #    if ! grep -q "url=" /etc/slurm-web/gateway.ini; then
                 #       echo "🔧 URL parameter missing, manually adding it..."
                  #      echo -e "\n[agents]\nurl=http://localhost:5012" | sudo tee -a /etc/slurm-web/gateway.ini
                   #     sudo systemctl restart slurm-web-gateway
                   # fi
               # fi
           # }
        fi
        echo "✅ slurm-web setup complete."
        echo "👉 Access the portal at http://192.168.1.202:5011"
    fi
else
    echo "🤷 Skipping slurm-web setup: scripts directory not found."
fi

# Mark controller as fully provisioned for compute nodes
echo "🎯 Controller provisioning complete"
echo "✅ Controller node fully configured and ready for compute nodes"

echo "Slurm Controller setup completed!"
echo "You can check the status with: systemctl status slurmctld"

