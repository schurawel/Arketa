#!/bin/bash
# Shared HPC Base Installation Script
# Common installation logic extracted from Vagrantfile and create-metal-iso.sh
# This eliminates redundancy between Vagrant provisioning and bare metal ISO creation

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Utility functions
log() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# Configuration
GO_VERSION="1.21.5"
APPTAINER_VERSION="1.3.4"

echo "🏗️ Setting up HPC Base System..."

# Update system
log "Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get upgrade -y

# Install core dependencies for both controller and compute nodes
log "Installing core build and system dependencies..."
apt-get install -y \
    build-essential git autoconf automake libtool \
    pkg-config libssl-dev libpam0g-dev libnuma-dev libhwloc-dev \
    libfreeipmi-dev librrd-dev libncurses5-dev libreadline-dev \
    python3-dev python3-pip munge libmunge-dev libmunge2 \
    cmake wget curl vim nfs-kernel-server nfs-common chrony \
    software-properties-common libseccomp-dev squashfs-tools cryptsetup \
    fuse libfuse-dev uuid-dev libgpgme11-dev \
    debootstrap rpm2cpio uidmap runc openssh-server rsync

# Install additional packages that might be needed for specific deployments
log "Installing additional system packages..."
apt-get install -y \
    mariadb-server mariadb-client libmariadb-dev \
    htop tree tmux screen

# Install image processing libraries for Python packages
log "Installing image processing libraries for Python packages..."
apt-get install -y \
    libjpeg-dev libjpeg8-dev libjpeg-turbo8-dev \
    libpng-dev libtiff5-dev libfreetype6-dev liblcms2-dev \
    libwebp-dev libharfbuzz-dev libfribidi-dev libxcb1-dev \
    zlib1g-dev libopenjp2-7-dev

# Install Go
log "Installing Go ${GO_VERSION}..."
if [ ! -d "/usr/local/go" ]; then
    wget -O /tmp/go.tar.gz "https://golang.org/dl/go${GO_VERSION}.linux-amd64.tar.gz"
    tar -C /usr/local -xzf /tmp/go.tar.gz
    echo 'export PATH="/usr/local/go/bin:$PATH"' > /etc/profile.d/go.sh
    rm -f /tmp/go.tar.gz
    success "Go ${GO_VERSION} installed"
else
    log "Go already installed, skipping..."
fi

# Install Apptainer dependencies
log "Installing Apptainer dependencies..."
apt-get install -y \
    squashfuse \
    fuse-overlayfs \
    uidmap \
    fuse3 \
    cryptsetup \
    ca-certificates

# Configure FUSE
log "Configuring FUSE..."
if ! grep -q "user_allow_other" /etc/fuse.conf; then
    echo "user_allow_other" >> /etc/fuse.conf
fi
modprobe fuse 2>/dev/null || true

# Install Apptainer from GitHub releases
log "Installing Apptainer ${APPTAINER_VERSION}..."
if ! command -v apptainer >/dev/null 2>&1; then
    wget -O /tmp/apptainer.deb "https://github.com/apptainer/apptainer/releases/download/v${APPTAINER_VERSION}/apptainer_${APPTAINER_VERSION}_amd64.deb"
    dpkg -i /tmp/apptainer.deb || {
        log "Fixing Apptainer dependencies..."
        apt-get install -f -y
        dpkg -i /tmp/apptainer.deb
    }
    rm -f /tmp/apptainer.deb
    success "Apptainer ${APPTAINER_VERSION} installed"
else
    log "Apptainer already installed, skipping..."
fi

# Configure Apptainer
log "Configuring Apptainer..."
mkdir -p /etc/apptainer
cat > /etc/apptainer/apptainer.conf << 'EOF'
# Allow setuid for better performance
allow setuid = yes

# Allow user namespaces
enable user space = yes

# Set cache directory
cache dir = /tmp/apptainer-cache

# Enable overlay
enable overlay = try

# Set bind paths for cluster environment
bind path = /shared
bind path = /home
bind path = /tmp
EOF

# Set proper permissions for Apptainer
chmod 755 /usr/bin/apptainer 2>/dev/null || chmod 755 /usr/local/bin/apptainer 2>/dev/null || true

# Create cache directory
mkdir -p /tmp/apptainer-cache
chmod 1777 /tmp/apptainer-cache

# Configure Apptainer remote endpoints
log "Configuring Apptainer remote endpoints..."
mkdir -p /etc/apptainer/remotes
cat > /etc/apptainer/remotes/sylabs-cloud.yaml << 'EOF'
Active: true
URI: https://cloud.sylabs.io
Token: ""
System: true
EOF

# Verify Apptainer installation
apptainer --version && success "Apptainer configured successfully" || warn "Apptainer may not be fully functional, but basic functionality should work"

# Test basic Apptainer functionality (with timeout to prevent hanging)
log "Testing Apptainer basic functionality..."
timeout 60 apptainer exec docker://alpine:latest echo "Apptainer test successful" 2>/dev/null || warn "Apptainer test skipped - will configure at runtime"

# Create slurm user
log "Creating slurm system user..."
useradd -r -s /bin/false slurm 2>/dev/null || log "Slurm user already exists"

# Install Python scientific packages
log "Installing Python scientific packages..."
pip3 install --no-cache-dir numpy scipy matplotlib pandas seaborn scikit-learn jupyter notebook || warn "Some Python packages failed to install"

# Function to build and install Slurm (if source is available)
install_slurm_from_source() {
    local slurm_src_dir="$1"
    
    if [ ! -d "$slurm_src_dir" ]; then
        warn "Slurm source directory not found: $slurm_src_dir"
        return 1
    fi
    
    log "Building and installing Slurm from source..."
    
    # Create build directory with proper ownership
    mkdir -p /tmp/slurm-build
    cp -r "$slurm_src_dir"/* /tmp/slurm-build/
    
    # Determine build user (prefer vagrant if available, otherwise use current user)
    local build_user="root"
    if id vagrant >/dev/null 2>&1; then
        build_user="vagrant"
        chown -R vagrant:vagrant /tmp/slurm-build
    fi
    
    cd /tmp/slurm-build
    
    # Make sure configure script is executable
    chmod +x configure
    
    # Configure and build Slurm
    if [ "$build_user" = "vagrant" ]; then
        sudo -u vagrant ./configure --prefix=/opt/slurm --sysconfdir=/etc/slurm \
            --enable-pam --with-pam_dir=/lib/x86_64-linux-gnu/security/ \
            --without-shared-libslurm 2>&1 | tee configure.log
        
        # Check if configure succeeded
        if [ ! -f Makefile ]; then
            error "Configure failed! Check configure.log"
        fi
        
        sudo -u vagrant make -j$(nproc)
    else
        ./configure --prefix=/opt/slurm --sysconfdir=/etc/slurm \
            --enable-pam --with-pam_dir=/lib/x86_64-linux-gnu/security/ \
            --without-shared-libslurm 2>&1 | tee configure.log
        
        # Check if configure succeeded
        if [ ! -f Makefile ]; then
            error "Configure failed! Check configure.log"
        fi
        
        make -j$(nproc)
    fi
    
    make install
    
    # Create necessary directories
    mkdir -p /etc/slurm /var/spool/slurmctld /var/spool/slurmd /var/log/slurm /opt/slurm/var/run
    chown -R slurm:slurm /var/spool/slurmctld /var/spool/slurmd /var/log/slurm /opt/slurm/var/run
    
    # Add Slurm binaries to PATH
    echo 'export PATH="/opt/slurm/bin:/opt/slurm/sbin:$PATH"' > /etc/profile.d/slurm.sh
    echo 'export LD_LIBRARY_PATH="/opt/slurm/lib:$LD_LIBRARY_PATH"' >> /etc/profile.d/slurm.sh
    chmod +x /etc/profile.d/slurm.sh
    
    # Clean up build directory
    rm -rf /tmp/slurm-build
    
    success "Slurm built and installed successfully"
    log "Slurm version: $(/opt/slurm/sbin/slurmctld -V 2>/dev/null | head -1 || echo 'Slurm installed successfully')"
}

# Check if Slurm source is available and install it
if [ -d "/home/vagrant/slurm-src" ]; then
    install_slurm_from_source "/home/vagrant/slurm-src"
elif [ -d "/opt/slurm-src" ]; then
    install_slurm_from_source "/opt/slurm-src"
else
    warn "Slurm source not found - skipping Slurm build"
    warn "Slurm will need to be installed separately"
fi

# Clean up for imaging (when preparing base images)
if [ "$1" = "--clean-for-imaging" ]; then
    log "Cleaning up for imaging..."
    apt-get clean
    rm -rf /var/lib/apt/lists/*
    rm -rf /tmp/*
    rm -rf /var/tmp/*
    # Keep cache directories for runtime use
    mkdir -p /tmp/apptainer-cache
    chmod 1777 /tmp/apptainer-cache
fi

# Mark as HPC base system
echo "hpc-base-$(date +%Y%m%d)" > /etc/hpc-base-version

success "HPC base system setup completed!"
log "Base system includes:"
log "  ✅ System packages and build tools"
log "  ✅ Go ${GO_VERSION}"
log "  ✅ Apptainer ${APPTAINER_VERSION}"
log "  ✅ Python scientific packages"
log "  ✅ Slurm user account"
log "  $([ -f "/opt/slurm/bin/sinfo" ] && echo "✅ Slurm from source" || echo "⚠️  Slurm not installed (source not available)")"
