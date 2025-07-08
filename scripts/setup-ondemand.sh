#!/bin/bash
# Exit on any error
set -e

echo "--- Setting up Open OnDemand from source ---"

# Install build dependencies
apt-get update
# Remove nodejs and npm, as we'll install a specific version later
apt-get install -y apache2 apache2-dev build-essential git curl ruby ruby-dev \
    libsqlite3-dev sqlite3 libssl-dev zlib1g-dev rake bundler

# Install a modern version of Node.js using NodeSource
echo "--- Installing Node.js v18 --- "
curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
apt-get install -y nodejs

# Clone Open OnDemand source if not already present
if [ ! -d "/home/vagrant/tmp/ondemand" ]; then
    echo "--- Cloning Open OnDemand repository ---"
    cd /home/vagrant/tmp
    git clone https://github.com/OSC/ondemand.git
else
    echo "--- Open OnDemand repository already exists ---"
fi

# Build and install Open OnDemand
echo "--- Building Open OnDemand ---"
cd /home/vagrant/tmp/ondemand

# Set environment variables for production build
export PASSENGER_APP_ENV=production
export PREFIX=/opt/ood

# Unset BUNDLE_WITHOUT to ensure all gem groups are installed
unset BUNDLE_WITHOUT

# Build the application
echo "--- Installing Ruby dependencies ---"
# Use recommended Bundler config instead of deprecated --without flag
# and set a local path to avoid permission issues.
sudo -u vagrant bundle config set --local path 'vendor/bundle'
sudo -u vagrant bundle install

# Verify gem installation
echo "--- Verifying installed gems ---"
sudo -u vagrant bundle exec gem list

echo "--- Building OnDemand applications ---"
sudo -u vagrant env BUNDLE_WITHOUT="" bundle exec rake build

echo "--- Installing OnDemand ---"
sudo mkdir -p /opt/ood
sudo bundle exec rake install

# Configure Apache
sudo /opt/ood/ood-portal-generator/sbin/ood_portal_generator
systemctl restart apache2

# Health check for Open OnDemand
echo "--- Verifying Open OnDemand installation ---"
if curl --silent --fail http://localhost; then
    echo "✅ Open OnDemand is running."
else
    echo "❌ ERROR: Open OnDemand failed to start." >&2
    exit 1
fi

# Configure Open OnDemand to use Slurm
# The default configuration should work with our setup, but we can customize if needed.
# For now, we will rely on the default Slurm adapter.

# Set permissions for user directories
mkdir -p /home/vagrant/ondemand/data
chown -R vagrant:vagrant /home/vagrant/ondemand

echo "--- Open OnDemand setup complete ---"
