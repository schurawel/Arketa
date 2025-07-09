#!/bin/bash
# Pre-flight check script for Vagrant source build

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() {
    echo -e "${BLUE}[CHECK]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[PASS]${NC} $1"
}

print_error() {
    echo -e "${RED}[FAIL]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

ERRORS=0

echo "Slurm Vagrant Cluster - Source Build Pre-flight Check"
echo "===================================================="
echo

# Check if running in correct directory
print_status "Checking project directory..."
if [[ -f "Vagrantfile" ]] && [[ -d "tmp/vagrant-src" ]]; then
    print_success "Found Vagrantfile and tmp/vagrant-src directory"
else
    print_error "Missing Vagrantfile or tmp/vagrant-src directory"
    ERRORS=$((ERRORS + 1))
fi

# Check Vagrant wrapper
print_status "Checking Vagrant wrapper..."
if [[ -f "vagrant-wrapper.sh" ]] && [[ -x "vagrant-wrapper.sh" ]]; then
    print_success "Vagrant wrapper exists and is executable"
    
    # Test Vagrant functionality
    if ./vagrant-wrapper.sh --version >/dev/null 2>&1; then
        vagrant_version=$(./vagrant-wrapper.sh --version)
        print_success "Vagrant working: $vagrant_version"
    else
        print_error "Vagrant wrapper not functioning"
        ERRORS=$((ERRORS + 1))
    fi
else
    print_error "Vagrant wrapper missing or not executable"
    ERRORS=$((ERRORS + 1))
fi

# Check Ruby installation
print_status "Checking Ruby installation..."
if command -v ruby >/dev/null 2>&1; then
    ruby_version=$(ruby --version)
    print_success "Ruby found: $ruby_version"
else
    print_error "Ruby not found"
    ERRORS=$((ERRORS + 1))
fi

# Check bundler
print_status "Checking Ruby bundler..."
if command -v bundle >/dev/null 2>&1; then
    bundle_version=$(bundle --version)
    print_success "Bundler found: $bundle_version"
else
    print_error "Bundler not found"
    ERRORS=$((ERRORS + 1))
fi

# Check libvirt installation
print_status "Checking libvirt installation..."
if command -v virsh >/dev/null 2>&1; then
    libvirt_version=$(virsh --version)
    print_success "libvirt found: $libvirt_version"
else
    print_error "libvirt not found. Please install it using setup-libvirt."
    ERRORS=$((ERRORS + 1))
fi

# Check vagrant-libvirt plugin
print_status "Checking vagrant-libvirt plugin..."
if ./vagrant-wrapper.sh plugin list | grep -q vagrant-libvirt; then
    print_success "vagrant-libvirt plugin is installed"
else
    print_warning "vagrant-libvirt plugin is not installed. Attempting to install..."
    if ./vagrant-wrapper.sh plugin install vagrant-libvirt; then
        print_success "vagrant-libvirt plugin installed successfully."
    else
        print_error "Failed to install vagrant-libvirt plugin. Please install it manually."
        ERRORS=$((ERRORS + 1))
    fi
fi

# Check disk space
print_status "Checking disk space..."
available_space=$(df . | awk 'NR==2 {print $4}')
required_space=20971520  # 20GB in KB

if [[ $available_space -gt $required_space ]]; then
    space_gb=$((available_space / 1024 / 1024))
    print_success "Sufficient disk space: ${space_gb}GB"
else
    space_gb=$((available_space / 1024 / 1024))
    print_error "Insufficient disk space. Available: ${space_gb}GB, Required: 20GB"
    ERRORS=$((ERRORS + 1))
fi

# Check memory
print_status "Checking available memory..."
total_mem=$(free -m | awk '/^Mem:/ {print $2}')
if [[ $total_mem -gt 6144 ]]; then
    print_success "Sufficient memory: ${total_mem}MB"
else
    print_warning "Low memory: ${total_mem}MB. Recommended: 8GB+"
fi

# Check existing VMs
print_status "Checking for existing VMs..."
if ./vagrant-wrapper.sh status 2>/dev/null | grep -q "running"; then
    print_warning "Some VMs are already running"
    ./vagrant-wrapper.sh status
else
    print_success "No VMs currently running"
fi

# Network connectivity
print_status "Checking internet connectivity..."
if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
    print_success "Internet connectivity OK"
else
    print_error "No internet connectivity"
    ERRORS=$((ERRORS + 1))
fi

# Summary
echo
echo "Pre-flight Check Summary"
echo "======================="

if [[ $ERRORS -eq 0 ]]; then
    print_success "All checks passed! Ready to start cluster."
    echo
    echo "Next steps:"
    echo "  1. Start cluster: ./cluster-manager.sh start"
    echo "  2. Wait 15-20 minutes for setup"
    echo "  3. Check health: ./cluster-manager.sh health"
    echo "  4. Connect: ./cluster-manager.sh connect"
else
    print_error "$ERRORS error(s) found. Please fix before proceeding."
    exit 1
fi
