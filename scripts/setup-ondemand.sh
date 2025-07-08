#!/bin/bash
# Exit on any error
set -e

echo "--- Setting up Open OnDemand with Docker ---"

# Install Docker if not already installed
if ! command -v docker &> /dev/null; then
    echo "--- Installing Docker ---"
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
mkdir -p /opt/ood/config
mkdir -p /opt/ood/data

# Create docker-compose.yml for Open OnDemand
echo "--- Creating Docker Compose configuration ---"
cat > /opt/ood/docker-compose.yml << 'EOF'
version: '3.8'

services:
  ondemand:
    image: ohiosupercomputer/ondemand:latest
    container_name: ondemand
    ports:
      - "80:8080"
      - "443:8443"
    volumes:
      - /opt/ood/config:/etc/ood/config
      - /opt/ood/data:/var/lib/ondemand-nginx/config/puns
      - /etc/passwd:/etc/passwd:ro
      - /etc/group:/etc/group:ro
      - /home:/home:ro
    environment:
      - OOD_PORTAL_GENERATOR=true
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
