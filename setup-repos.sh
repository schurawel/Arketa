#!/bin/bash
# Repository setup script to automatically clone vagrant-src and slurm repos

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Configuration
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_DIR="${PROJECT_DIR}/tmp"
VAGRANT_REPO_URL="https://github.com/hashicorp/vagrant.git"
SLURM_REPO_URL="https://github.com/SchedMD/slurm.git"
ONDEMAND_REPO_URL="https://github.com/OSC/ondemand.git"
SLURMWEB_REPO_URL="https://github.com/rackslab/slurm-web.git"

echo "Repository Setup for PrimedSLURM"
echo "================================"
echo

print_status "Setting up repositories in tmp folder..."

# Create tmp directory
mkdir -p "$TMP_DIR"

# Clone Vagrant repository
print_status "Cloning Vagrant repository..."
if [ -d "$TMP_DIR/vagrant-src" ]; then
    print_warning "vagrant-src already exists, updating..."
    cd "$TMP_DIR/vagrant-src"
    git pull
else
    print_status "Cloning Vagrant from $VAGRANT_REPO_URL..."
    git clone "$VAGRANT_REPO_URL" "$TMP_DIR/vagrant-src"
    print_success "Vagrant cloned successfully"
fi

# Clone Slurm repository
print_status "Cloning Slurm repository..."
if [ -d "$TMP_DIR/slurm" ]; then
    print_warning "slurm already exists, updating..."
    cd "$TMP_DIR/slurm"
    git pull
else
    print_status "Cloning Slurm from $SLURM_REPO_URL..."
    git clone "$SLURM_REPO_URL" "$TMP_DIR/slurm"
    print_success "Slurm cloned successfully"
fi

# Clone Open OnDemand repository
print_status "Cloning Open OnDemand repository..."
if [ -d "$TMP_DIR/ondemand" ]; then
    print_warning "ondemand already exists, updating..."
    cd "$TMP_DIR/ondemand"
    git pull
else
    print_status "Cloning Open OnDemand from $ONDEMAND_REPO_URL..."
    git clone "$ONDEMAND_REPO_URL" "$TMP_DIR/ondemand"
    print_success "Open OnDemand cloned successfully"
fi

# Clone Slurm Web repository
print_status "Cloning Slurm Web repository..."
if [ -d "$TMP_DIR/slurm-web" ]; then
    print_warning "slurm-web already exists, updating..."
    cd "$TMP_DIR/slurm-web"
    git pull
else
    print_status "Cloning Slurm Web from $SLURMWEB_REPO_URL..."
    git clone "$SLURMWEB_REPO_URL" "$TMP_DIR/slurm-web"
    print_success "Slurm Web cloned successfully"
fi

# Create or update symbolic links - NOT NEEDED, everything works from tmp/
# cd "$PROJECT_DIR"

# print_status "Creating symbolic links..."

# Remove old directories/links if they exist
# if [ -L "vagrant-src" ] || [ -d "vagrant-src" ]; then
#     rm -rf vagrant-src
# fi
# if [ -L "slurm" ] || [ -d "slurm" ]; then
#     rm -rf slurm
# fi

# Create symbolic links
# ln -sf "tmp/vagrant-src" vagrant-src
# ln -sf "tmp/slurm" slurm

print_success "Repositories are available in tmp/ directory:"
print_success "  tmp/vagrant-src (Vagrant source)"
print_success "  tmp/slurm (Slurm source)"
print_success "  tmp/ondemand (Open OnDemand source)"
print_success "  tmp/slurm-web (Slurm Web source)"

# Setup Vagrant dependencies
print_status "Setting up Vagrant dependencies..."
cd "$PROJECT_DIR/tmp/vagrant-src"

if [ -f "Gemfile" ]; then
    print_status "Installing Vagrant Ruby dependencies..."
    if command -v bundle >/dev/null 2>&1; then
        bundle install --path vendor/bundle
        print_success "Vagrant dependencies installed"
    else
        print_error "Bundler not found. Please install with: gem install bundler"
    fi
else
    print_error "Gemfile not found in vagrant-src"
fi

cd "$PROJECT_DIR"

# Verify the setup
print_status "Verifying setup..."

if [ -f "tmp/vagrant-src/bin/vagrant" ]; then
    print_success "Vagrant binary found"
else
    print_error "Vagrant binary not found in tmp/vagrant-src/bin/vagrant"
fi

if [ -f "tmp/slurm/configure" ]; then
    print_success "Slurm configure script found"
else
    print_error "Slurm configure script not found in tmp/slurm/configure"
fi

if [ -f "tmp/slurm-web/pyproject.toml" ]; then
    print_success "Slurm Web pyproject.toml found"
else
    print_error "Slurm Web pyproject.toml not found in tmp/slurm-web/pyproject.toml"
fi

# Test Vagrant functionality
print_status "Testing Vagrant functionality..."
if [ -x "vagrant-wrapper.sh" ]; then
    if ./vagrant-wrapper.sh --version >/dev/null 2>&1; then
        vagrant_version=$(./vagrant-wrapper.sh --version)
        print_success "Vagrant working: $vagrant_version"
    else
        print_warning "Vagrant wrapper not functioning yet. You may need to run 'bundle install' in tmp/vagrant-src/"
    fi
else
    print_warning "Vagrant wrapper not found or not executable"
fi

echo
print_success "Repository setup completed!"
echo
print_status "Next steps:"
echo "  1. Run: make preflight      # Check prerequisites"
echo "  2. Run: make build-base     # Build base box with Slurm"
echo "  3. Run: make cluster        # Deploy cluster"
echo
print_warning "Note: The repositories are now stored in the 'tmp/' directory"
print_warning "      and linked via symbolic links. This keeps them organized"
print_warning "      and prevents accidental commits to git."
