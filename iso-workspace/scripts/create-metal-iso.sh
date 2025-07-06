#!/bin/bash
# Create HPC Cluster Custom ISO
# This script automatically creates a custom Ubuntu ISO with HPC stack pre-installed
# Uses Ubuntu Desktop ISO for complete live system modification capabilities

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
ISO_WORKSPACE="${PROJECT_DIR}/iso-workspace"
ISO_OUTPUT="${PROJECT_DIR}/ubuntu-22.04-hpc-cluster.iso"
BASE_ISO_URL="https://releases.ubuntu.com/22.04/ubuntu-22.04.5-desktop-amd64.iso"
BASE_ISO="${PROJECT_DIR}/ubuntu-22.04.5-desktop-amd64.iso"

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
    log "Checking dependencies for automated ISO creation..."
    
    # Required tools for automated ISO creation
    local required_tools=("wget" "xorriso" "unsquashfs" "mksquashfs" "rsync")
    local missing_tools=()
    
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools+=("$tool")
        fi
    done
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        log "Installing missing dependencies: ${missing_tools[*]}"
        sudo apt update
        
        # Install packages based on missing tools
        local packages_to_install=()
        for tool in "${missing_tools[@]}"; do
            case "$tool" in
                "wget") packages_to_install+=("wget") ;;
                "xorriso") packages_to_install+=("xorriso") ;;
                "unsquashfs"|"mksquashfs") packages_to_install+=("squashfs-tools") ;;
                "rsync") packages_to_install+=("rsync") ;;
            esac
        done
        
        # Remove duplicates
        local unique_packages=($(printf '%s\n' "${packages_to_install[@]}" | sort -u))
        
        sudo apt install -y "${unique_packages[@]}"
        
        # Verify installation
        for tool in "${required_tools[@]}"; do
            if ! command -v "$tool" >/dev/null 2>&1; then
                error "Failed to install $tool. Please install manually."
            fi
        done
        
        success "Dependencies installed successfully"
    else
        log "All required dependencies are already installed"
    fi
    
    # Check for isolinux (needed for bootable ISO)
    if [ ! -f "/usr/lib/ISOLINUX/isohdpfx.bin" ]; then
        log "Installing isolinux for bootable ISO creation..."
        sudo apt install -y isolinux
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
    
    # Copy the shared setup script to the iso workspace
    cp "${PROJECT_DIR}/scripts/setup-base.sh" "${ISO_WORKSPACE}/setup-base.sh"
    chmod +x "${ISO_WORKSPACE}/setup-base.sh"
    
    # Create a wrapper script that calls the shared setup script
    cat > "${ISO_WORKSPACE}/hpc-cluster-installer.sh" << 'EOF'
#!/bin/bash
# HPC Cluster Base Installation Script
# Uses shared setup-base.sh script for consistency with Vagrant deployment

set -e

echo "🏗️ Building HPC-ready Ubuntu 22.04..."

# Run the shared HPC base setup script with imaging cleanup
/setup-base.sh --clean-for-imaging

echo "✅ HPC base system ready!"
EOF

    chmod +x "${ISO_WORKSPACE}/hpc-cluster-installer.sh"
    success "HPC installer script created using shared setup-base.sh"
}

create_preseed_configs() {
    log "Creating preseed configurations..."
    
    mkdir -p "${ISO_WORKSPACE}/preseed"
    
    # Controller preseed
    cat > "${ISO_WORKSPACE}/preseed/hpc-controller.seed" << 'EOF'
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
    cat > "${ISO_WORKSPACE}/preseed/hpc-compute.seed" << 'EOF'
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
    
    mkdir -p "${ISO_WORKSPACE}/scripts"
    
    # Copy existing scripts (this now includes setup-base.sh)
    cp -r "${PROJECT_DIR}/scripts/"* "${ISO_WORKSPACE}/scripts/"
    cp -r "${PROJECT_DIR}/sample-jobs" "${ISO_WORKSPACE}/"
    
    # Create enhanced node configuration script that leverages existing setup scripts
    cat > "${ISO_WORKSPACE}/scripts/configure-node.sh" << 'EOF'
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

    chmod +x "${ISO_WORKSPACE}/scripts/configure-node.sh"
    success "Enhanced post-installation scripts created"
}

create_validation_script() {
    log "Creating HPC stack validation script..."
    
    cat > "${ISO_WORKSPACE}/scripts/validate-hpc-stack.sh" << 'EOF'
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

    chmod +x "${ISO_WORKSPACE}/scripts/validate-hpc-stack.sh"
    success "HPC stack validation script created"
}

create_iso_documentation() {
    log "Creating ISO deployment documentation..."
    
    cat > "${ISO_WORKSPACE}/README.md" << 'EOF'
# HPC Cluster ISO Documentation

## Overview
This custom Ubuntu 22.04 ISO includes a complete HPC stack pre-installed for automated bare metal deployment.

## What's Included
- ✅ Complete HPC development stack (build tools, libraries)
- ✅ Go 1.21.5 programming environment  
- ✅ Apptainer 1.3.4 for container workloads
- ✅ Python scientific stack (NumPy, SciPy, Matplotlib, etc.)
- ✅ Slurm workload manager (if source was available)
- ✅ Sample job scripts and configuration templates
- ✅ Automated node configuration scripts

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
EOF

    success "ISO deployment documentation created"
}

prepare_slurm_source() {
    if [ -d "${PROJECT_DIR}/tmp/slurm" ]; then
        log "Copying Slurm source for inclusion in ISO..."
        
        # Validate Slurm source before copying
        if [ -f "${PROJECT_DIR}/tmp/slurm/configure" ]; then
            # Copy Slurm source excluding .git directories and other VCS files
            rsync -av --exclude='.git' --exclude='.svn' --exclude='.hg' \
                "${PROJECT_DIR}/tmp/slurm/" "${ISO_WORKSPACE}/slurm-src/"
            success "Slurm source copied successfully"
            log "Source size: $(du -sh "${ISO_WORKSPACE}/slurm-src" | cut -f1)"
        else
            warn "Slurm source directory exists but configure script not found"
            warn "Skipping Slurm source copy"
        fi
    else
        warn "Slurm source not found at ${PROJECT_DIR}/tmp/slurm"
        warn "ISO will not include pre-compiled Slurm"
        warn "Run 'make setup-repos' to download Slurm source, then retry"
        
        # Create a note file for users
        cat > "${ISO_WORKSPACE}/SLURM_SOURCE_MISSING.txt" << 'EOF'
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

create_custom_iso() {
    log "Extracting base ISO for modification..."
    
    # Create temporary directories
    local iso_extract_dir="${ISO_WORKSPACE}/iso-extract"
    local iso_rebuild_dir="${ISO_WORKSPACE}/iso-rebuild"
    local squashfs_dir="${ISO_WORKSPACE}/squashfs-root"
    
    # Clean up any previous attempts
    sudo rm -rf "$iso_extract_dir" "$iso_rebuild_dir" "$squashfs_dir"
    mkdir -p "$iso_extract_dir" "$iso_rebuild_dir"
    
    # Extract base ISO
    log "Mounting and extracting base ISO..."
    # Ensure /mnt is unmounted first
    sudo umount /mnt 2>/dev/null || true
    sudo mount -o loop "$BASE_ISO" /mnt
    sudo cp -rT /mnt "$iso_extract_dir"
    sudo umount /mnt
    
    # Make the extracted files writable
    sudo chmod -R u+w "$iso_extract_dir"
    
    # Detect and extract the correct squashfs filesystem
    log "Detecting Ubuntu ISO format and extracting filesystem..."
    cd "$ISO_WORKSPACE"
    
    # Try to find the main filesystem squashfs
    local squashfs_file=""
    if [ -f "$iso_extract_dir/casper/filesystem.squashfs" ]; then
        # Ubuntu Desktop ISO format - contains complete live system
        squashfs_file="filesystem.squashfs"
        log "Found Ubuntu Desktop filesystem.squashfs (complete live system)"
    elif [ -f "$iso_extract_dir/casper/ubuntu-server-minimal.ubuntu-server.installer.squashfs" ]; then
        # Ubuntu Server format - contains only installer (limited functionality)
        squashfs_file="ubuntu-server-minimal.ubuntu-server.installer.squashfs"
        warn "Found Ubuntu Server installer squashfs (limited - recommend Desktop ISO)"
    else
        # Try to find the largest squashfs file (likely the main filesystem)
        squashfs_file=$(ls -1S "$iso_extract_dir/casper/"*.squashfs 2>/dev/null | head -1 | xargs basename 2>/dev/null || echo "")
        if [ -n "$squashfs_file" ]; then
            log "Using largest squashfs file: $squashfs_file"
        else
            error "No suitable squashfs filesystem found in ISO"
        fi
    fi
    
    log "Extracting $squashfs_file for modification..."
    sudo unsquashfs -d "$squashfs_dir" "$iso_extract_dir/casper/$squashfs_file"
    
    # Store the squashfs filename for later use
    echo "$squashfs_file" > "$ISO_WORKSPACE/.squashfs_filename"
    
    # Prepare chroot environment
    log "Setting up chroot environment..."
    # Handle resolv.conf (may be a dangling symlink)
    sudo rm -f "$squashfs_dir/etc/resolv.conf"
    sudo cp /etc/resolv.conf "$squashfs_dir/etc/resolv.conf"
    sudo cp "$ISO_WORKSPACE/setup-base.sh" "$squashfs_dir/tmp/"
    sudo cp "$ISO_WORKSPACE/hpc-cluster-installer.sh" "$squashfs_dir/tmp/"
    sudo cp -r "$ISO_WORKSPACE/scripts" "$squashfs_dir/tmp/"
    sudo cp -r "$ISO_WORKSPACE/sample-jobs" "$squashfs_dir/tmp/"
    
    # Create installation script for the chroot environment
    cat > "$ISO_WORKSPACE/install-hpc-stack.sh" << 'EOF'
#!/bin/bash
# Install HPC stack in chroot environment
set -e

echo "🏗️ Installing HPC stack in ISO environment..."

# Update package database
apt update

# Install basic dependencies
apt install -y wget curl git build-essential

# Make installer scripts executable
chmod +x /tmp/setup-base.sh
chmod +x /tmp/hpc-cluster-installer.sh

# Run the HPC base setup
echo "📦 Installing HPC components..."
export DEBIAN_FRONTEND=noninteractive
cd /tmp
./setup-base.sh --clean-for-imaging

# Install additional tools useful for bare metal deployment
apt install -y \
    net-tools \
    htop \
    tree \
    vim \
    nano \
    screen \
    tmux \
    rsync \
    bc

# Create HPC admin user
useradd -m -s /bin/bash -G sudo hpcadmin || true
echo "hpcadmin:cluster123" | chpasswd

# Enable SSH service
systemctl enable ssh

# Clean up for smaller ISO
apt autoremove -y
apt autoclean
rm -rf /var/lib/apt/lists/*
rm -rf /tmp/setup-base.sh /tmp/hpc-cluster-installer.sh

# Create version marker
echo "$(date): HPC-enabled Ubuntu 22.04.5 created" > /etc/hpc-iso-version

echo "✅ HPC stack installation complete!"
EOF

    sudo cp "$ISO_WORKSPACE/install-hpc-stack.sh" "$squashfs_dir/tmp/"
    sudo chmod +x "$squashfs_dir/tmp/install-hpc-stack.sh"
    
    # Run the installation in chroot
    log "Installing HPC stack in chroot environment..."
    sudo chroot "$squashfs_dir" /bin/bash -c "
        mount -t proc proc /proc
        mount -t sysfs sysfs /sys
        mount -t devpts devpts /dev/pts
        /tmp/install-hpc-stack.sh
        umount /dev/pts /sys /proc
    "
    
    # Clean up chroot environment
    sudo rm -f "$squashfs_dir/etc/resolv.conf"
    sudo rm -rf "$squashfs_dir/tmp/install-hpc-stack.sh"
    
    # Get the original squashfs filename
    local original_squashfs_file=$(cat "$ISO_WORKSPACE/.squashfs_filename" 2>/dev/null || echo "filesystem.squashfs")
    
    # Create new squashfs
    log "Creating new squashfs filesystem ($original_squashfs_file)..."
    sudo rm -f "$iso_extract_dir/casper/$original_squashfs_file"
    sudo mksquashfs "$squashfs_dir" "$iso_extract_dir/casper/$original_squashfs_file" -comp xz -e boot
    
    # Update filesystem size for the specific squashfs file
    local size_file="${original_squashfs_file%.*}.size"
    printf $(sudo du -sx --block-size=1 "$squashfs_dir" | cut -f1) | sudo tee "$iso_extract_dir/casper/$size_file" > /dev/null
    
    # Create custom grub menu with HPC options
    log "Creating custom boot menu..."
    cat > "$ISO_WORKSPACE/grub.cfg" << 'EOF'
set default="0"
set timeout=10

menuentry "Try or Install HPC Cluster Controller" {
    set gfxpayload=keep
    linux /casper/vmlinuz boot=casper maybe-ubiquity quiet splash ---
    initrd /casper/initrd
}

menuentry "Try or Install HPC Cluster Compute Node" {
    set gfxpayload=keep
    linux /casper/vmlinuz boot=casper maybe-ubiquity quiet splash ---
    initrd /casper/initrd
}

menuentry "Try Ubuntu without installing (HPC-enabled)" {
    set gfxpayload=keep
    linux /casper/vmlinuz boot=casper quiet splash ---
    initrd /casper/initrd
}

menuentry "Check disc for defects" {
    set gfxpayload=keep
    linux /casper/vmlinuz boot=casper integrity-check quiet splash ---
    initrd /casper/initrd
}
EOF

    sudo cp "$ISO_WORKSPACE/grub.cfg" "$iso_extract_dir/boot/grub/"
    
    # Update MD5 checksums
    log "Updating checksums..."
    cd "$iso_extract_dir"
    find . -type f -print0 | sudo xargs -0 md5sum | grep -v "\./md5sum.txt" | sudo tee md5sum.txt > /dev/null
    
    # Create the final ISO
    log "Building final HPC cluster ISO..."
    cd "$ISO_WORKSPACE"
    sudo xorriso -as mkisofs \
        -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
        -c isolinux/boot.cat \
        -b isolinux/isolinux.bin \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -eltorito-alt-boot \
        -e boot/grub/efi.img \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
        -o "$ISO_OUTPUT" \
        "$iso_extract_dir"
    
    # Clean up temporary directories
    log "Cleaning up temporary files..."
    sudo rm -rf "$iso_extract_dir" "$squashfs_dir"
    
    # Make ISO readable by user
    sudo chown $(whoami):$(whoami) "$ISO_OUTPUT"
    
    success "Custom HPC ISO created: $ISO_OUTPUT"
    
    # Display ISO information
    local iso_size=$(du -h "$ISO_OUTPUT" | cut -f1)
    log "ISO size: $iso_size"
}

main() {
    echo -e "${BOLD}🏗️ HPC Cluster Custom ISO Creator${NC}"
    echo "===================================="
    echo ""
    
    # Validate environment
    if [ "$EUID" -eq 0 ]; then
        error "This script should not be run as root. It will request sudo when needed."
    fi
    
    if [ ! -f "${PROJECT_DIR}/scripts/setup-base.sh" ]; then
        error "setup-base.sh not found. Please ensure you're running from the PrimedSLURM directory."
    fi
    
    check_dependencies
    
    # Create workspace with proper error handling
    log "Creating ISO workspace: $ISO_WORKSPACE"
    if ! mkdir -p "$ISO_WORKSPACE"; then
        error "Failed to create workspace directory: $ISO_WORKSPACE"
    fi
    
    if ! cd "$ISO_WORKSPACE"; then
        error "Failed to change to workspace directory: $ISO_WORKSPACE"
    fi
    
    # Execute all setup steps
    download_base_iso
    create_hpc_installer
    create_preseed_configs
    create_post_install_scripts
    create_validation_script
    create_iso_documentation
    prepare_slurm_source
    
    # Final validation
    local required_files=(
        "setup-base.sh"
        "hpc-cluster-installer.sh"
        "scripts/configure-node.sh"
        "scripts/validate-hpc-stack.sh"
        "README.md"
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
    
    # Automatically create the custom ISO
    log "Creating custom HPC cluster ISO automatically..."
    create_custom_iso
    
    echo ""
    success "HPC Cluster ISO created successfully!"
    echo ""
    echo -e "${GREEN}📀 Custom ISO: ${BOLD}$ISO_OUTPUT${NC}"
    echo ""
    echo -e "${YELLOW}🚀 Next steps:${NC}"
    echo "1. Boot from: ${BOLD}$ISO_OUTPUT${NC}"
    echo "2. Select 'HPC Controller' or 'HPC Compute' during installation"
    echo "3. Follow the automated installation process"
    echo ""
    echo -e "${GREEN}💡 Features:${NC} The ISO includes the complete HPC stack (Slurm, Apptainer, Go) pre-installed!"
}

# Run main function
main "$@"
