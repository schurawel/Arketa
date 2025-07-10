#!/bin/bash
# setup-ondemand.sh - Automated Open OnDemand setup (official system package method)

# Exit on any error
set -e

# Function for error handling
handle_error() {
  echo "❌ ERROR: $1" >&2
  exit 1
}

echo "🌐 Setting up Open OnDemand using the official package repository"

# 1. Enable dependencies
echo "📦 Installing required packages..."
apt update
apt install -y curl gnupg2 ca-certificates lsb-release || handle_error "Failed to install required packages"

# 2. Add Open OnDemand repository and install
echo "📦 Adding Open OnDemand repository..."

sudo apt install -y apt-transport-https ca-certificates
wget -O /tmp/ondemand-release-web_4.0.0-jammy_all.deb https://apt.osc.edu/ondemand/4.0/ondemand-release-web_4.0.0-jammy_all.deb
sudo apt install -y /tmp/ondemand-release-web_4.0.0-jammy_all.deb
sudo apt update

sudo apt install -y ondemand

# 3. Start and enable Apache (httpd)
echo "🛠️ Configuring and starting Apache web server..."
systemctl start apache2
systemctl enable apache2

# 4. Print access info
echo "✅ Open OnDemand setup complete!"
echo "🌐 Access Open OnDemand at: http://$(hostname -f)/"

# 5. Check if Open OnDemand is accessible
sleep 5
echo -n "Checking Open OnDemand accessibility... "
if curl --silent --fail --max-time 10 http://localhost/ >/dev/null 2>&1; then
  echo "✅ Accessible at http://localhost/"
else
  echo "❌ Not accessible at http://localhost/ (check Apache and OOD logs)"
fi

# 6. Create Slurm cluster config for Open OnDemand
sudo mkdir -p /etc/ood/config/clusters.d
cat <<EOF | sudo tee /etc/ood/config/clusters.d/primedslurm.yml
---
v2:
  metadata:
    title: "PrimedSLURM Cluster"
  login:
    host: "controller"
  job:
    adapter: "slurm"
    # Remove 'cluster' line unless you have a multi-cluster setup
    bin: "/usr/bin"
    conf: "/etc/slurm/slurm.conf"
    # Uncomment to copy environment (see OOD docs for caveats)
    # copy_environment: true
EOF

echo
echo "Next steps:"
echo "  • Set up authentication and SSL as per official documentation"
echo "  • Configure firewall to allow access to Open OnDemand (port 80 and 443)"
echo "  • Optionally, install and configure additional packages as needed"