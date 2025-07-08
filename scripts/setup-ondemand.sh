#!/bin/bash
# Exit on any error
set -e

echo "--- Setting up Open OnDemand ---"

# Install prerequisites
apt-get update
apt-get install -y apt-transport-https ca-certificates curl gnupg-agent software-properties-common

# Add Open OnDemand repository
curl -fsSL https://yum.osc.edu/ondemand/DEB-GPG-KEY-ondemand | gpg --dearmor -o /usr/share/keyrings/ondemand-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/ondemand-archive-keyring.gpg] https://yum.osc.edu/ondemand/3.1/apt ubuntu-22.04 main" | tee /etc/apt/sources.list.d/ondemand.list > /dev/null

# Install Open OnDemand
apt-get update
apt-get install -y ondemand

# Configure Apache
/opt/ood/ood-portal-generator/sbin/ood_portal_generator
systemctl restart apache2

# Configure Open OnDemand to use Slurm
# The default configuration should work with our setup, but we can customize if needed.
# For now, we will rely on the default Slurm adapter.

# Set permissions for user directories
mkdir -p /home/vagrant/ondemand/data
chown -R vagrant:vagrant /home/vagrant/ondemand

echo "--- Open OnDemand setup complete ---"
