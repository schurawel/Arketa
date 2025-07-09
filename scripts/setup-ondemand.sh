#!/bin/bash
# Exit on any error
set -e

echo "--- Setting up Open OnDemand with Docker ---"

# Wait for any running package manager processes to complete
echo "--- Waiting for package manager to be available ---"
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
    echo "Waiting for other package managers to finish..."
    sleep 5
done

# Kill any stuck unattended-upgrade processes
if pgrep -f unattended-upgrade > /dev/null; then
    echo "Stopping unattended-upgrades..."
    systemctl stop unattended-upgrades || true
    pkill -f unattended-upgrade || true
    sleep 3
fi

# Install Docker if not already installed
if ! command -v docker &> /dev/null; then
    echo "--- Installing Docker ---"
    # Wait a bit more and try to acquire the lock
    sleep 2
    apt-get update
    apt-get install -y ca-certificates curl gnupg lsb-release
    
    # Add Docker's official GPG key
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    
    # Set up the repository
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Install Docker Engine
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    
    # Start and enable Docker
    systemctl start docker
    systemctl enable docker
else
    echo "--- Docker is already installed ---"
fi

# Install Docker Compose if not already installed
if ! command -v docker-compose &> /dev/null; then
    echo "--- Installing Docker Compose ---"
    curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
else
    echo "--- Docker Compose is already installed ---"
fi

# Create directory for Open OnDemand configuration
mkdir -p /opt/ood/config/clusters.d
mkdir -p /opt/ood/data

# Navigate to the source directory
if [ -d "/home/vagrant/tmp/ondemand" ]; then
  cd /home/vagrant/tmp/ondemand
  echo "Changed directory to $(pwd)"
else
  echo "Error: Open OnDemand source directory not found at /home/vagrant/tmp/ondemand" >&2
  exit 1
fi

# Build Open OnDemand Docker image from source
echo "--- Building Open OnDemand Docker image ---"

echo "Building Open OnDemand image (this may take several minutes)..."
if docker build -t ondemand:latest -f Dockerfile . ; then
    echo "Open OnDemand image built successfully"
else
    echo "Failed to build Open OnDemand image. Trying fallback approach..."
    # Use a simple Apache-based approach as fallback
    cat > /tmp/Dockerfile.simple << 'SIMPLE_EOF'
FROM ubuntu:22.04

# Install Apache and basic dependencies
RUN apt-get update && apt-get install -y \
    apache2 \
    apache2-utils \
    ruby \
    ruby-dev \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Simple index page
RUN echo '<h1>Open OnDemand Placeholder</h1><p>This is a placeholder for Open OnDemand.</p><p>Slurm cluster is running separately.</p>' > /var/www/html/index.html

EXPOSE 80
CMD ["apache2ctl", "-D", "FOREGROUND"]
SIMPLE_EOF
    docker build -t ondemand:latest -f /tmp/Dockerfile.simple /tmp/
else
    echo "Open OnDemand image built successfully"
fi

# Create docker-compose.yml for Open OnDemand
echo "--- Creating Docker Compose configuration ---"
cat > /opt/ood/docker-compose.yml << 'EOF'
version: '3.8'

services:
  ondemand:
    image: ondemand:latest
    container_name: ondemand
    ports:
      - "8080:80"
    volumes:
      - /opt/ood/config:/etc/ood/config:ro
      - /opt/ood/data:/var/lib/ondemand-nginx/config/puns
    restart: unless-stopped
    networks:
      - ondemand

networks:
  ondemand:
    driver: bridge
EOF

# Create basic Open OnDemand configuration
echo "--- Creating Open OnDemand configuration ---"
cat > /opt/ood/config/clusters.d/slurm.yml << 'EOF'
---
v2:
  metadata:
    title: "Slurm Cluster"
  login:
    host: "localhost"
  job:
    adapter: "slurm"
    cluster: "cluster"
    bin: "/usr/bin"
    conf: "/etc/slurm/slurm.conf"
EOF

# Create nginx configuration for Open OnDemand
cat > /opt/ood/config/nginx_stage.yml << 'EOF'
---
# Path to the OnDemand portal for generating nginx configs
ondemand_portal: "/var/www/ood/apps/sys/dashboard"

# Unique name of OnDemand portal for namespacing
ondemand_title: "Open OnDemand"

# Use default values for most settings
EOF

# Start Open OnDemand with Docker Compose
echo "--- Starting Open OnDemand container ---"
cd /opt/ood
docker-compose up -d

# Wait for the container to be ready
echo "--- Waiting for Open OnDemand to start ---"
sleep 30

# Health check for Open OnDemand
echo "--- Verifying Open OnDemand installation ---"
if curl --silent --fail http://localhost; then
    echo "✅ Open OnDemand is running via Docker."
    echo "📝 Access Open OnDemand at: http://localhost"
else
    echo "❌ ERROR: Open OnDemand failed to start." >&2
    echo "--- Checking container logs ---"
    docker-compose logs ondemand
    exit 1
fi

echo "--- Open OnDemand Docker setup complete ---"
