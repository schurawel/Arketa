#!/bin/bash
# Create HPC Cluster Metal ISO using Cubic
# This script extracts the Vagrant provisioning logic into a custom Ubuntu ISO

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CUBIC_WORKSPACE="${PROJECT_DIR}/cubic-workspace"
ISO_OUTPUT="${PROJECT_DIR}/ubuntu-22.04-hpc-cluster.iso"
BASE_ISO_URL="https://releases.ubuntu.com/22.04/ubuntu-22.04.5-live-server-amd64.iso"
BASE_ISO="${PROJECT_DIR}/ubuntu-22.04.5-live-server-amd64.iso"

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

check_dependencies() {
    log "Checking dependencies..."
    
    if ! command -v cubic >/dev/null 2>&1; then
        warn "Cubic not found. Installing from PPA..."
        
        # Add the Cubic PPA
        if ! grep -q "cubic-wizard" /etc/apt/sources.list.d/* 2>/dev/null; then
            log "Adding Cubic PPA repository..."
            sudo apt update
            sudo apt install -y software-properties-common
            sudo add-apt-repository -y ppa:cubic-wizard/release
            sudo apt update
        fi
        
        # Install Cubic
        log "Installing Cubic..."
        sudo apt install -y cubic
        
        if ! command -v cubic >/dev/null 2>&1; then
            error "Failed to install Cubic. Please install manually:\n  sudo add-apt-repository ppa:cubic-wizard/release\n  sudo apt update\n  sudo apt install cubic"
        fi
        
        success "Cubic installed successfully"
    else
        log "Cubic already installed"
    fi
    
    if ! command -v wget >/dev/null 2>&1; then
        error "wget is required but not installed"
    fi
    
    success "Dependencies check passed"
}

download_base_iso() {
    if [ ! -f "$BASE_ISO" ]; then
        log "Downloading Ubuntu 22.04 LTS ISO..."
        wget -O "$BASE_ISO" "$BASE_ISO_URL"
        success "ISO downloaded"
    else
        log "Base ISO already exists: $BASE_ISO"
    fi
}

create_hpc_installer() {
    log "Creating HPC installer script..."
    
    # Copy the shared setup script to the cubic workspace
    cp "${PROJECT_DIR}/scripts/setup-base.sh" "${CUBIC_WORKSPACE}/setup-base.sh"
    chmod +x "${CUBIC_WORKSPACE}/setup-base.sh"
    
    # Create a wrapper script that calls the shared setup script
    cat > "${CUBIC_WORKSPACE}/hpc-cluster-installer.sh" << 'EOF'
#!/bin/bash
# HPC Cluster Base Installation Script
# Uses shared setup-base.sh script for consistency with Vagrant deployment

set -e

echo "🏗️ Building HPC-ready Ubuntu 22.04..."

# Run the shared HPC base setup script with imaging cleanup
/setup-base.sh --clean-for-imaging

echo "✅ HPC base system ready!"
EOF

    chmod +x "${CUBIC_WORKSPACE}/hpc-cluster-installer.sh"
    success "HPC installer script created using shared setup-base.sh"
}

create_preseed_configs() {
    log "Creating preseed configurations..."
    
    mkdir -p "${CUBIC_WORKSPACE}/preseed"
    
    # Controller preseed
    cat > "${CUBIC_WORKSPACE}/preseed/hpc-controller.seed" << 'EOF'
# HPC Controller Node Preseed Configuration
d-i debian-installer/locale string en_US
d-i keyboard-configuration/xkb-keymap select us

# Network configuration
d-i netcfg/choose_interface select auto
d-i netcfg/disable_autoconfig boolean true
d-i netcfg/get_ipaddress string 192.168.1.10
d-i netcfg/get_netmask string 255.255.255.0
d-i netcfg/get_gateway string 192.168.1.1
d-i netcfg/get_nameservers string 8.8.8.8
d-i netcfg/confirm_static boolean true
d-i netcfg/get_hostname string hpc-controller
d-i netcfg/get_domain string hpc.local

# Partitioning
d-i partman-auto/disk string /dev/sda
d-i partman-auto/method string regular
d-i partman-auto/choose_recipe select atomic
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true

# User setup
d-i passwd/user-fullname string HPC Administrator
d-i passwd/username string hpcadmin
d-i passwd/user-password password cluster123
d-i passwd/user-password-again password cluster123
d-i passwd/user-default-groups string adm dialout cdrom floppy sudo audio dip video plugdev netdev

# Package selection
tasksel tasksel/first multiselect server
d-i pkgsel/include string openssh-server

# Boot loader
d-i grub-installer/only_debian boolean true
d-i grub-installer/with_other_os boolean true

# Post-installation commands
d-i preseed/late_command string \
    in-target systemctl enable ssh; \
    echo "hpc-controller setup complete" > /target/var/log/hpc-install.log
EOF

    # Compute node preseed template
    cat > "${CUBIC_WORKSPACE}/preseed/hpc-compute.seed" << 'EOF'
# HPC Compute Node Preseed Configuration
d-i debian-installer/locale string en_US
d-i keyboard-configuration/xkb-keymap select us

# Network configuration (will be customized per node)
d-i netcfg/choose_interface select auto
d-i netcfg/disable_autoconfig boolean true
d-i netcfg/get_ipaddress string 192.168.1.11
d-i netcfg/get_netmask string 255.255.255.0
d-i netcfg/get_gateway string 192.168.1.1
d-i netcfg/get_nameservers string 8.8.8.8
d-i netcfg/confirm_static boolean true
d-i netcfg/get_hostname string hpc-compute01
d-i netcfg/get_domain string hpc.local

# Partitioning
d-i partman-auto/disk string /dev/sda
d-i partman-auto/method string regular
d-i partman-auto/choose_recipe select atomic
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true

# User setup
d-i passwd/user-fullname string HPC User
d-i passwd/username string hpcadmin
d-i passwd/user-password password cluster123
d-i passwd/user-password-again password cluster123
d-i passwd/user-default-groups string adm dialout cdrom floppy sudo audio dip video plugdev netdev

# Package selection
tasksel tasksel/first multiselect server
d-i pkgsel/include string openssh-server

# Boot loader
d-i grub-installer/only_debian boolean true
d-i grub-installer/with_other_os boolean true

# Post-installation commands
d-i preseed/late_command string \
    in-target systemctl enable ssh; \
    echo "hpc-compute setup complete" > /target/var/log/hpc-install.log
EOF

    success "Preseed configurations created"
}

create_post_install_scripts() {
    log "Creating post-installation scripts..."
    
    mkdir -p "${CUBIC_WORKSPACE}/scripts"
    
    # Copy existing scripts (this now includes setup-base.sh)
    cp -r "${PROJECT_DIR}/scripts/"* "${CUBIC_WORKSPACE}/scripts/"
    cp -r "${PROJECT_DIR}/sample-jobs" "${CUBIC_WORKSPACE}/"
    
    # Create enhanced node configuration script that leverages existing setup scripts
    cat > "${CUBIC_WORKSPACE}/scripts/configure-node.sh" << 'EOF'
#!/bin/bash
# Configure HPC node after installation
# This script leverages the existing setup-controller.sh and setup-compute.sh scripts

set -e

NODE_TYPE="$1"  # controller or compute
NODE_ID="$2"    # node number (for compute nodes)

if [ -z "$NODE_TYPE" ]; then
    echo "Usage: $0 <controller|compute> [node_id]"
    exit 1
fi

echo "🚀 Configuring HPC ${NODE_TYPE} node ${NODE_ID:-}"

# Set up hosts file for cluster networking (bare metal uses different IP range)
cat > /etc/hosts << 'HOSTS_EOF'
127.0.0.1 localhost
192.168.1.10 hpc-controller controller
192.168.1.11 hpc-compute01 node1
192.168.1.12 hpc-compute02 node2
192.168.1.13 hpc-compute03 node3

# IPv6 entries
::1 ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
HOSTS_EOF

# Configure hostname
if [ "$NODE_TYPE" = "controller" ]; then
    hostnamectl set-hostname hpc-controller
    
    # Create shared directory
    mkdir -p /shared
    chown slurm:slurm /shared 2>/dev/null || true
    chmod 755 /shared
    
    # Configure NFS export for shared directory
    echo "/shared 192.168.1.0/24(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports
    systemctl enable nfs-kernel-server
    systemctl start nfs-kernel-server
    exportfs -a
    
    # Run controller setup using existing script
    echo "🔧 Running controller-specific setup..."
    if [ -f "/tmp/scripts/setup-controller.sh" ]; then
        bash /tmp/scripts/setup-controller.sh
    else
        echo "⚠️ Controller setup script not found, manual configuration needed"
    fi
    
elif [ "$NODE_TYPE" = "compute" ]; then
    if [ -z "$NODE_ID" ]; then
        echo "❌ Node ID required for compute nodes"
        exit 1
    fi
    
    hostnamectl set-hostname "hpc-compute$(printf "%02d" "$NODE_ID")"
    
    # Create shared directory mount point
    mkdir -p /shared
    echo "hpc-controller:/shared /shared nfs defaults 0 0" >> /etc/fstab
    
    # Run compute setup using existing script
    echo "🔧 Running compute node setup..."
    if [ -f "/tmp/scripts/setup-compute.sh" ]; then
        bash /tmp/scripts/setup-compute.sh "$NODE_ID"
    else
        echo "⚠️ Compute setup script not found, manual configuration needed"
    fi
else
    echo "❌ Invalid node type: $NODE_TYPE"
    echo "Valid types: controller, compute"
    exit 1
fi

echo "✅ Node configuration complete for ${NODE_TYPE} ${NODE_ID:-}"
echo "📋 Next steps:"
if [ "$NODE_TYPE" = "controller" ]; then
    echo "  • Check cluster status: sinfo"
    echo "  • Submit test job: sbatch /tmp/sample-jobs/hello_world.sh"
else
    echo "  • Check node registration on controller: sinfo"
    echo "  • Verify shared storage: ls -la /shared"
fi
EOF

    chmod +x "${CUBIC_WORKSPACE}/scripts/configure-node.sh"
    success "Enhanced post-installation scripts created"
}

create_validation_script() {
    log "Creating HPC stack validation script..."
    
    cat > "${CUBIC_WORKSPACE}/scripts/validate-hpc-stack.sh" << 'EOF'
#!/bin/bash
# HPC Stack Validation Script
# Validates that all components are properly installed and configured

set -e

echo "🔍 HPC Stack Validation"
echo "======================="
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

validate_component() {
    local component="$1"
    local command="$2"
    local expected="$3"
    
    echo -n "Checking $component... "
    if eval "$command" >/dev/null 2>&1; then
        echo -e "${GREEN}✅ OK${NC}"
        if [ -n "$expected" ]; then
            echo "   $(eval "$command" 2>/dev/null | head -1)"
        fi
        return 0
    else
        echo -e "${RED}❌ FAILED${NC}"
        return 1
    fi
}

validate_file() {
    local description="$1"
    local filepath="$2"
    
    echo -n "Checking $description... "
    if [ -f "$filepath" ]; then
        echo -e "${GREEN}✅ Found${NC}"
        return 0
    else
        echo -e "${RED}❌ Missing${NC}"
        return 1
    fi
}

echo "🔧 System Components:"
validate_component "Build tools" "gcc --version"
validate_component "Git" "git --version"
validate_component "Python 3" "python3 --version"
validate_component "Make" "make --version"

echo ""
echo "🚀 HPC Software:"
validate_component "Go" "go version"
validate_component "Apptainer" "apptainer --version"

echo ""
echo "🐍 Python Packages:"
validate_component "NumPy" "python3 -c 'import numpy; print(numpy.__version__)'"
validate_component "SciPy" "python3 -c 'import scipy; print(scipy.__version__)'"
validate_component "Matplotlib" "python3 -c 'import matplotlib; print(matplotlib.__version__)'"
validate_component "Pandas" "python3 -c 'import pandas; print(pandas.__version__)'"

echo ""
echo "⚙️ Slurm Components:"
if validate_component "Slurm" "/opt/slurm/bin/sinfo --version" 2>/dev/null; then
    validate_file "Slurm config" "/etc/slurm/slurm.conf"
    validate_file "Slurm controller" "/opt/slurm/sbin/slurmctld"
    validate_file "Slurm daemon" "/opt/slurm/sbin/slurmd"
else
    echo -e "   ${YELLOW}⚠️ Slurm not installed (source may not have been available)${NC}"
fi

echo ""
echo "👤 System Users:"
validate_component "Slurm user" "id slurm"

echo ""
echo "📁 Important Directories:"
validate_file "Scripts directory" "/opt/hpc-scripts"
validate_file "Sample jobs" "/opt/hpc-sample-jobs"

echo ""
echo "🌍 Environment:"
validate_file "Go environment" "/etc/profile.d/go.sh"
if [ -f "/etc/profile.d/slurm.sh" ]; then
    validate_file "Slurm environment" "/etc/profile.d/slurm.sh"
fi
validate_file "HPC base marker" "/etc/hpc-base-version"

echo ""
echo "📋 Summary:"
if [ -f "/etc/hpc-base-version" ]; then
    echo "   HPC Base Version: $(cat /etc/hpc-base-version)"
fi
if [ -f "/etc/slurm-base-version" ]; then
    echo "   Slurm Base Version: $(cat /etc/slurm-base-version)"
fi

echo ""
echo -e "${GREEN}✅ HPC Stack validation complete!${NC}"
EOF

    chmod +x "${CUBIC_WORKSPACE}/scripts/validate-hpc-stack.sh"
    success "HPC stack validation script created"
}

create_cubic_instructions() {
    log "Creating comprehensive Cubic usage instructions..."
    
    cat > "${CUBIC_WORKSPACE}/CUBIC_INSTRUCTIONS.md" << 'EOF'
# HPC Cluster ISO Creation with Cubic

## Overview
This guide walks through creating a custom Ubuntu 22.04 ISO with the HPC stack pre-installed, ensuring consistency with the Vagrant-based deployment.

## Prerequisites
- Ubuntu host system with Cubic installed
- At least 8GB free disk space
- Internet connection for downloading packages during customization

## Step-by-Step Instructions

### 1. Launch Cubic
```bash
sudo cubic
```

### 2. Project Setup
- **Select Project Directory**: Choose this directory as the Cubic project directory
- **Import Original ISO**: Select the downloaded Ubuntu 22.04 ISO
- **Project Name**: Use "HPC-Cluster-Ubuntu-22.04"

### 3. Extract and Enter Chroot Environment
Cubic will extract the ISO filesystem. Once ready, you'll be in a chroot environment.

### 4. Install HPC Base System
In the chroot terminal, run the shared setup script:

```bash
# Copy the setup script to a temporary location
cp /cubic-workspace/setup-base.sh /tmp/
chmod +x /tmp/setup-base.sh

# Install the complete HPC stack (this may take 15-20 minutes)
echo "🏗️ Installing HPC base system..."
/tmp/setup-base.sh --clean-for-imaging

# Verify installation
echo "✅ Verifying installations..."
go version
apptainer --version
python3 -c "import numpy, scipy, matplotlib; print('Python packages OK')"

# Check if Slurm was installed
if [ -f "/opt/slurm/bin/sinfo" ]; then
    echo "✅ Slurm installed: $(/opt/slurm/bin/sinfo --version)"
else
    echo "⚠️ Slurm not installed (source not available)"
fi
```

### 5. Copy Additional Resources
```bash
# Copy all scripts and sample jobs
cp -r /cubic-workspace/scripts /tmp/
cp -r /cubic-workspace/sample-jobs /tmp/
cp -r /cubic-workspace/preseed /tmp/

# If Slurm source is available, you can also copy it
if [ -d "/cubic-workspace/slurm-src" ]; then
    echo "📦 Slurm source found, copying for potential later use..."
    cp -r /cubic-workspace/slurm-src /tmp/
fi

# Make scripts executable
chmod +x /tmp/scripts/*.sh
```

### 6. Create Installation Automation
```bash
# Create an auto-setup script for first boot
cat > /etc/rc.local << 'RCLOCAL_EOF'
#!/bin/bash
# Auto-configuration script for HPC cluster nodes

# Check if this is first boot
if [ ! -f /var/log/hpc-first-boot-complete ]; then
    echo "$(date): HPC first boot configuration starting..." >> /var/log/hpc-setup.log
    
    # Copy resources from installation media
    if [ -d /tmp/scripts ]; then
        cp -r /tmp/scripts /opt/hpc-scripts
        cp -r /tmp/sample-jobs /opt/hpc-sample-jobs
        chmod +x /opt/hpc-scripts/*.sh
    fi
    
    echo "$(date): HPC first boot configuration complete" >> /var/log/hpc-setup.log
    touch /var/log/hpc-first-boot-complete
fi

exit 0
RCLOCAL_EOF

chmod +x /etc/rc.local
systemctl enable rc-local
```

### 7. Final Cleanup
```bash
# Clean package cache and temporary files
apt-get clean
apt-get autoremove -y
rm -rf /var/lib/apt/lists/*
rm -rf /tmp/setup-base.sh
rm -rf /root/.cache

# Clear command history
history -c
history -w

# Exit chroot
exit
```

### 8. Customize Boot Menu (Optional)
In Cubic's boot menu customization:
- **Timeout**: Set to 10 seconds
- **Default Option**: "Install Ubuntu Server"
- **Custom Entries**: Add entries for automated installation

### 9. Generate the ISO
- Review the customization summary
- Generate the new ISO
- Save as "ubuntu-22.04-hpc-cluster.iso"

## Deployment Instructions

### Controller Node Installation
1. Boot from the custom ISO
2. Follow standard Ubuntu installation
3. After first boot, run:
```bash
sudo /opt/hpc-scripts/configure-node.sh controller
```

### Compute Node Installation
1. Boot from the custom ISO
2. Follow standard Ubuntu installation
3. After first boot, run:
```bash
sudo /opt/hpc-scripts/configure-node.sh compute 1  # For first compute node
sudo /opt/hpc-scripts/configure-node.sh compute 2  # For second compute node
# etc.
```

## Network Configuration
The scripts assume the following network layout:
- **Controller**: 192.168.1.10 (hpc-controller)
- **Compute Node 1**: 192.168.1.11 (hpc-compute01)
- **Compute Node 2**: 192.168.1.12 (hpc-compute02)
- **Compute Node 3**: 192.168.1.13 (hpc-compute03)

Adjust `/opt/hpc-scripts/configure-node.sh` if your network uses different IP ranges.

## Verification
After deployment, verify the cluster:

### On Controller:
```bash
source /etc/profile.d/slurm.sh
sinfo                    # Check cluster status
sbatch /opt/hpc-sample-jobs/hello_world.sh  # Submit test job
squeue                   # Monitor jobs
```

### On Compute Nodes:
```bash
systemctl status slurmd  # Check Slurm daemon
df -h /shared           # Verify shared storage
```

## Troubleshooting
- **Logs**: Check `/var/log/hpc-setup.log` for setup issues
- **Services**: Use `systemctl status` to check service status
- **Network**: Verify all nodes can ping each other
- **Munge**: Test with `munge -n | unmunge` on each node

## What's Included
- ✅ Complete HPC development stack (build tools, libraries)
- ✅ Go 1.21.5 programming environment
- ✅ Apptainer 1.3.4 for container workloads
- ✅ Python scientific stack (NumPy, SciPy, Matplotlib, etc.)
- ✅ Slurm workload manager (if source was available)
- ✅ Sample job scripts and configuration templates
- ✅ Automated node configuration scripts
EOF

    success "Comprehensive Cubic instructions created"
}

prepare_slurm_source() {
    if [ -d "${PROJECT_DIR}/tmp/slurm" ]; then
        log "Copying Slurm source for inclusion in ISO..."
        
        # Validate Slurm source before copying
        if [ -f "${PROJECT_DIR}/tmp/slurm/configure" ]; then
            cp -r "${PROJECT_DIR}/tmp/slurm" "${CUBIC_WORKSPACE}/slurm-src"
            success "Slurm source copied successfully"
            log "Source size: $(du -sh "${CUBIC_WORKSPACE}/slurm-src" | cut -f1)"
        else
            warn "Slurm source directory exists but configure script not found"
            warn "Skipping Slurm source copy"
        fi
    else
        warn "Slurm source not found at ${PROJECT_DIR}/tmp/slurm"
        warn "ISO will not include pre-compiled Slurm"
        warn "Run 'make setup-repos' to download Slurm source, then retry"
        
        # Create a note file for users
        cat > "${CUBIC_WORKSPACE}/SLURM_SOURCE_MISSING.txt" << 'EOF'
SLURM SOURCE NOT INCLUDED
=========================

The Slurm source code was not found during ISO creation.

To include Slurm in future ISO builds:
1. Run: make setup-repos
2. Re-run: make metal

Without Slurm source, the generated ISO will include all HPC dependencies
but Slurm will need to be installed manually after deployment.
EOF
    fi
}

main() {
    echo -e "${BOLD}🏗️ HPC Cluster Metal ISO Creator${NC}"
    echo "===================================="
    echo ""
    
    # Validate environment
    if [ "$EUID" -eq 0 ]; then
        error "This script should not be run as root. Cubic will request sudo when needed."
    fi
    
    if [ ! -f "${PROJECT_DIR}/scripts/setup-base.sh" ]; then
        error "setup-base.sh not found. Please ensure you're running from the PrimedSLURM directory."
    fi
    
    check_dependencies
    
    # Create workspace with proper error handling
    log "Creating Cubic workspace: $CUBIC_WORKSPACE"
    if ! mkdir -p "$CUBIC_WORKSPACE"; then
        error "Failed to create workspace directory: $CUBIC_WORKSPACE"
    fi
    
    if ! cd "$CUBIC_WORKSPACE"; then
        error "Failed to change to workspace directory: $CUBIC_WORKSPACE"
    fi
    
    # Execute all setup steps
    download_base_iso
    create_hpc_installer
    create_preseed_configs
    create_post_install_scripts
    create_validation_script
    create_cubic_instructions
    prepare_slurm_source
    
    # Final validation
    local required_files=(
        "setup-base.sh"
        "hpc-cluster-installer.sh"
        "scripts/configure-node.sh"
        "scripts/validate-hpc-stack.sh"
        "CUBIC_INSTRUCTIONS.md"
    )
    
    log "Validating workspace contents..."
    for file in "${required_files[@]}"; do
        if [ ! -f "$file" ]; then
            error "Required file missing: $file"
        fi
    done
    
    echo ""
    success "Metal ISO preparation complete!"
    echo ""
    echo -e "${YELLOW}📁 Workspace Contents:${NC}"
    find . -type f -name "*.sh" -o -name "*.md" | head -10
    echo ""
    echo -e "${YELLOW}🚀 Next steps:${NC}"
    echo "1. Launch Cubic: ${BOLD}sudo cubic${NC}"
    echo "2. Select base ISO: ${BOLD}$BASE_ISO${NC}"
    echo "3. Use workspace: ${BOLD}$CUBIC_WORKSPACE${NC}"
    echo "4. Follow instructions in: ${BOLD}$CUBIC_WORKSPACE/CUBIC_INSTRUCTIONS.md${NC}"
    echo ""
    echo -e "${BLUE}📀 Final ISO location: $ISO_OUTPUT${NC}"
    echo ""
    echo -e "${GREEN}💡 Tip:${NC} The generated ISO will include the same HPC stack as your Vagrant deployment!"
}

# Run main function
main "$@"
