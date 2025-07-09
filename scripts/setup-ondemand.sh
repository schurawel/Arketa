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
# Check which Dockerfile to use (prefer demo, then dev, then example)
if [ -f "Dockerfile.demo" ]; then
    DOCKERFILE="Dockerfile.demo"
elif [ -f "Dockerfile.dev" ]; then
    DOCKERFILE="Dockerfile.dev"
elif [ -f "Dockerfile.example" ]; then
    DOCKERFILE="Dockerfile.example"
else
    echo "No suitable Dockerfile found in Open OnDemand repository"
    exit 1
fi

if [ -n "$DOCKERFILE" ] && docker build -t ondemand:latest -f "$DOCKERFILE" . ; then
    echo "Open OnDemand image built successfully using $DOCKERFILE"
else
    echo "Failed to build Open OnDemand image. Aborting."
    exit 1
fi

# Create docker-compose.yml for Open OnDemand
echo "--- Creating Docker Compose configuration ---"
cat > /opt/ood/docker-compose.yml << 'EOF'
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
echo "Container is starting up with systemd, this may take a few minutes..."

# Wait for systemd and services to initialize inside the container
max_wait=180  # 3 minutes
wait_time=0
echo "Waiting for Open OnDemand services to initialize..."

while [ $wait_time -lt $max_wait ]; do
    echo "Checking Open OnDemand status... ($wait_time/$max_wait seconds)"
    
    # Check if HTTP service is responding
    if curl --silent --fail --connect-timeout 5 http://localhost:8080 >/dev/null 2>&1; then
        echo "✅ Open OnDemand is responding!"
        break
    fi
    
    # Show container status every 30 seconds
    if [ $((wait_time % 30)) -eq 0 ]; then
        echo "--- Container status at $wait_time seconds ---"
        docker-compose ps
        echo "--- Recent container logs ---"
        docker-compose logs --tail=10 ondemand
    fi
    
    sleep 10
    wait_time=$((wait_time + 10))
done

# Final health check
echo "--- Final verification of Open OnDemand ---"
if curl --silent --fail http://localhost:8080; then
    echo "✅ Open OnDemand is running via Docker."
    echo "📝 Access Open OnDemand at: http://localhost:8080"
else
    echo "❌ ERROR: Open OnDemand failed to start after $max_wait seconds." >&2
    echo "--- Final container status ---"
    docker-compose ps
    echo "--- Full container logs ---"
    docker-compose logs ondemand
    echo "--- Attempting to check services inside container ---"
    docker-compose exec ondemand systemctl status httpd || true
    docker-compose exec ondemand systemctl status ondemand-dex || true
    exit 1
fi

echo "--- Open OnDemand Docker setup complete ---"
