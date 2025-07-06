#!/bin/bash
# HPC Cluster Base Installation Script
# Uses shared setup-base.sh script for consistency with Vagrant deployment

set -e

echo "🏗️ Building HPC-ready Ubuntu 22.04..."

# Run the shared HPC base setup script with imaging cleanup
/setup-base.sh --clean-for-imaging

echo "✅ HPC base system ready!"
