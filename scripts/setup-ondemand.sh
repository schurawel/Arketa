#!/bin/bash
# setup-ondemand.sh - Open OnDemand setup script
# Uses existing Dockerfile.demo to build and run Open OnDemand for PrimedSLURM

# Exit on any error
set -e

# Function for error handling
handle_error() {
  echo "❌ ERROR: $1" >&2
  exit 1
}

echo "🌐 Setting up Open OnDemand for PrimedSLURM using existing Dockerfile.demo"

# Check if the Dockerfile.demo exists in various possible locations
DOCKERFILE_FOUND=false
DOCKERFILE_LOCATIONS=(
  "/home/thinclient/Documents/PrimedSLURM/tmp/ondemand/Dockerfile.demo"
  "/home/vagrant/Documents/PrimedSLURM/tmp/ondemand/Dockerfile.demo"
  "/home/vagrant/tmp/ondemand/Dockerfile.demo"
  "/tmp/ondemand/Dockerfile.demo"
)

for location in "${DOCKERFILE_LOCATIONS[@]}"; do
  if [ -f "$location" ]; then
    echo "✅ Found Dockerfile.demo at: $location"
    DOCKERFILE_PATH="$location"
    DOCKERFILE_FOUND=true
    break
  fi
done

if [ "$DOCKERFILE_FOUND" = false ]; then
  handle_error "Dockerfile.demo not found in any expected locations"
fi

# Install Docker if not already installed
echo "📦 Checking Docker installation..."
if ! command -v docker &> /dev/null; then
  echo "Installing Docker..."
  apt-get update
  apt-get install -y apt-transport-https ca-certificates curl software-properties-common
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
  add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io
  systemctl enable docker
  systemctl start docker
  
  # Wait a moment for Docker to fully start
  echo "⏳ Waiting for Docker service to be ready..."
  sleep 5
fi

# Add vagrant user to docker group
echo "--- Adding vagrant user to docker group ---"
usermod -aG docker vagrant

# Fix for slurm-web package editable installation issue
echo "--- Creating fix for slurm-web package installation ---"
mkdir -p /opt/ood/fixes/slurm-web
cat > /opt/ood/fixes/slurm-web/setup.py << 'EOF'
from setuptools import setup, find_packages

setup(
    name="slurm-web",
    version="0.1.0",
    packages=find_packages(),
    install_requires=[
        "flask>=2.0.0",
        "requests>=2.25.0",
    ],
    python_requires=">=3.6",
)
EOF

# Use the found or created Dockerfile
echo "--- Building Open OnDemand image using Dockerfile.demo at $DOCKERFILE_PATH ---"
cd "$(dirname "$DOCKERFILE_PATH")"
docker build -t ondemand:latest -f "$(basename "$DOCKERFILE_PATH")" . || handle_error "Docker build failed"

# Create directories for configuration
echo "--- Creating enhanced Open OnDemand configuration ---"
mkdir -p /opt/ood/config/clusters.d
mkdir -p /opt/ood/config/apps/dashboard/initializers
mkdir -p /opt/ood/config/apps/dashboard/views/widgets
mkdir -p /opt/ood/config/apps/shell
mkdir -p /opt/ood/config/apps/files
mkdir -p /opt/ood/config/nginx_stage

# Create Slurm cluster configuration
cat > /opt/ood/config/clusters.d/slurm.yml << 'EOF'
---
v2:
  metadata:
    title: "PrimedSLURM Cluster"
    url: "https://github.com/yourusername/PrimedSLURM"
    hidden: false
  login:
    host: "controller"
  job:
    adapter: "slurm"
    cluster: "primed-slurm"
    bin: "/usr/bin"
    conf: "/etc/slurm/slurm.conf"
    submit_host: "controller"
    ssh_hosts:
      - controller
    site_timeout: 7200
    debug: true
EOF

# Create dashboard environment configuration
cat > /opt/ood/config/apps/dashboard/env.conf << 'EOF'
OOD_DASHBOARD_TITLE="PrimedSLURM Portal"
OOD_BRAND_BG_COLOR="#0066cc"
OOD_NAVBAR_TYPE="dark"
EOF

# Create shell app configuration
cat > /opt/ood/config/apps/shell/env.conf << 'EOF'
OOD_DEFAULT_SSHHOST="controller"
OOD_SSH_HOSTS="controller"
EOF

# Create files app configuration
cat > /opt/ood/config/apps/files/env.conf << 'EOF'
OOD_FILEROOT_MAX_UPLOAD_SIZE="10737418240"
OOD_FILE_EDITOR="true"
EOF

# Create Ruby initializer
cat > /opt/ood/config/apps/dashboard/initializers/ood.rb << 'EOF'
Rails.application.config.after_initialize do
  OodFilesApp.candidate_favorite_paths.tap do |paths|
    paths.delete_if { |p| p.include?("$HOME") }
    paths << FavoritePath.new("/shared", title: "Shared Directory")
    paths << FavoritePath.new("/home/vagrant", title: "Home Directory")
  end
end
EOF

# Create nginx stage configuration
cat > /opt/ood/config/nginx_stage/nginx_stage.yml << 'EOF'
---
min_uid: 1000
max_uid: 100000
upload_max_size: 10737418240
EOF

# Create custom message of the day
cat > /opt/ood/motd.txt << 'EOF'
# Welcome to PrimedSLURM Open OnDemand Portal!

This is a web-based portal for accessing:
- Interactive apps like Jupyter notebooks
- File management
- Shell access
- Job management and monitoring

For help, please see the documentation.
EOF

# Create dashboard widget for custom MOTD display
cat > /opt/ood/config/apps/dashboard/views/widgets/_motd.html.erb << 'EOF'
<div class="motd-widget">
  <div class="panel panel-primary">
    <div class="panel-heading">
      <h3 class="panel-title">PrimedSLURM HPC Portal</h3>
    </div>
    <div class="panel-body">
      <p>Welcome to the PrimedSLURM HPC Portal! This portal provides:</p>
      <ul class="list-unstyled">
        <li><i class="fa fa-check text-success"></i> Slurm job submission and management</li>
        <li><i class="fa fa-check text-success"></i> Interactive applications (Jupyter, RStudio, etc.)</li>
        <li><i class="fa fa-check text-success"></i> File management and editing</li>
        <li><i class="fa fa-check text-success"></i> Shell access to the cluster</li>
      </ul>
      <div class="btn-group btn-group-sm" role="group">
        <a href="/pun/sys/myjobs" class="btn btn-primary">
          <i class="fa fa-tasks"></i> Job Composer
        </a>
        <a href="/pun/sys/activejobs" class="btn btn-info">
          <i class="fa fa-clock-o"></i> Active Jobs
        </a>
        <a href="/pun/sys/shell/ssh/controller" class="btn btn-success">
          <i class="fa fa-terminal"></i> Shell
        </a>
        <a href="/pun/sys/files/fs/home" class="btn btn-warning">
          <i class="fa fa-file"></i> Files
        </a>
      </div>
    </div>
  </div>
</div>
EOF

echo "--- Starting Open OnDemand container with enhanced configuration ---"
# Stop existing container if it exists
docker stop ondemand 2>/dev/null || true
docker rm ondemand 2>/dev/null || true

# Start container with proper configuration
docker run -d --name ondemand --privileged \
  --network host \
  -v /opt/ood/config/clusters.d/slurm.yml:/etc/ood/config/clusters.d/slurm.yml:ro \
  -v /opt/ood/config/apps/dashboard/env.conf:/etc/ood/config/apps/dashboard/env:ro \
  -v /opt/ood/config/apps/shell/env.conf:/etc/ood/config/apps/shell/env:ro \
  -v /opt/ood/config/apps/files/env.conf:/etc/ood/config/apps/files/env:ro \
  -v /opt/ood/config/apps/dashboard/initializers/ood.rb:/etc/ood/config/apps/dashboard/initializers/ood.rb:ro \
  -v /opt/ood/config/nginx_stage/nginx_stage.yml:/etc/ood/config/nginx_stage/nginx_stage.yml:ro \
  -v /opt/ood/config/apps/dashboard/views/widgets/_motd.html.erb:/etc/ood/config/apps/dashboard/views/widgets/_motd.html.erb:ro \
  -v /opt/ood/motd.txt:/etc/motd:ro \
  -v /opt/ood/fixes/slurm-web/setup.py:/home/vagrant/tmp/slurm-web/setup.py:ro \
  -v /sys/fs/cgroup:/sys/fs/cgroup:ro \
  -v /tmp:/tmp \
  --hostname ondemand \
  --add-host controller:192.168.121.10 \
  --add-host node1:192.168.121.11 \
  --add-host node2:192.168.121.12 \
  --env OOD_PORTAL_TITLE="PrimedSLURM Portal" \
  --env OOD_BRAND_BG_COLOR="#0066cc" \
  --env OOD_NAVBAR_TYPE="dark" \
  ondemand:latest || handle_error "Docker run failed"

# Create docker-compose configuration for alternative deployment
cat > /opt/ood/docker-compose-ondemand.yml << 'EOF'
version: '3'
services:
  ondemand:
    image: ondemand:latest
    container_name: ondemand
    privileged: true
    network_mode: host
    volumes:
      - /opt/ood/config/clusters.d/slurm.yml:/etc/ood/config/clusters.d/slurm.yml:ro
      - /opt/ood/config/apps/dashboard/env.conf:/etc/ood/config/apps/dashboard/env:ro
      - /opt/ood/config/apps/shell/env.conf:/etc/ood/config/apps/shell/env:ro
      - /opt/ood/config/apps/files/env.conf:/etc/ood/config/apps/files/env:ro
      - /opt/ood/config/apps/dashboard/initializers/ood.rb:/etc/ood/config/apps/dashboard/initializers/ood.rb:ro
      - /opt/ood/config/nginx_stage/nginx_stage.yml:/etc/ood/config/nginx_stage/nginx_stage.yml:ro
      - /opt/ood/config/apps/dashboard/views/widgets/_motd.html.erb:/etc/ood/config/apps/dashboard/views/widgets/_motd.html.erb:ro
      - /opt/ood/motd.txt:/etc/motd:ro
      - /opt/ood/fixes/slurm-web/setup.py:/home/vagrant/tmp/slurm-web/setup.py:ro
      - /sys/fs/cgroup:/sys/fs/cgroup:ro
      - /tmp:/tmp
    hostname: ondemand
    extra_hosts:
      - "controller:192.168.121.10"
      - "node1:192.168.121.11"
      - "node2:192.168.121.12"
    environment:
      - OOD_PORTAL_TITLE=PrimedSLURM Portal
      - OOD_BRAND_BG_COLOR=#0066cc
      - OOD_NAVBAR_TYPE=dark
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080"]
      interval: 30s
      timeout: 10s
      retries: 3
EOF

# Health check
echo "🔍 Waiting for Open OnDemand to initialize..."
max_wait=120
wait_time=0
is_ready=false

while [ $wait_time -lt $max_wait ] && [ "$is_ready" = false ]; do
  echo "Checking Open OnDemand status... ($wait_time/$max_wait seconds)"
  
  # Check container status
  container_status=$(docker inspect -f '{{.State.Status}}' ondemand 2>/dev/null || echo "not_running")
  echo "  → Container status: $container_status"
  
  if [ "$container_status" = "running" ]; then
    # Try to check if SystemD is running inside container
    if docker exec ondemand systemctl status >/dev/null 2>&1; then
      echo "  ✅ SystemD is running"
      
      # Check httpd status
      if docker exec ondemand systemctl is-active httpd >/dev/null 2>&1; then
        echo "  ✅ HTTP service is active"
        
        # Test HTTP connectivity - THIS IS THE DEFINITIVE TEST
        if curl --silent --fail --connect-timeout 5 --max-time 10 http://localhost:8080/ >/dev/null 2>&1; then
          echo "  ✅ HTTP service responding"
          echo "  ✅ All checks passed!"
          is_ready=true
        else
          echo "  ⚠️ HTTP service not responding yet"
        fi
      else
        echo "  ⚠️ HTTP service not active yet, attempting to start..."
        docker exec ondemand systemctl start httpd || true
      fi
    else
      echo "  ⚠️ SystemD not fully initialized yet"
      
      # If SystemD is having issues, check directly for web services
      if docker exec ondemand ps aux | grep -E 'httpd|apache' | grep -v grep >/dev/null 2>&1; then
        echo "  ✅ Web server process found"
        
        # Test HTTP connectivity as a fallback
        if curl --silent --fail --connect-timeout 5 --max-time 10 http://localhost:8080/ >/dev/null 2>&1; then
          echo "  ✅ HTTP service responding via direct check"
          echo "  ✅ All checks passed!"
          is_ready=true
        else
          echo "  ⚠️ Web server running but not responding to HTTP requests yet"
        fi
      else
        echo "  ⚠️ No web server process found yet"
      fi
    fi
  else
    echo "  ⚠️ Container is not running"
  fi
  
  # Show detailed status every 30 seconds
  if [ $((wait_time % 30)) -eq 0 ] && [ $wait_time -gt 0 ]; then
    echo "--- Detailed status at $wait_time seconds ---"
    docker ps -a | grep ondemand
    docker exec ondemand ps aux | grep -E 'httpd|apache' || echo "No web server processes found"
    docker exec ondemand netstat -tulpn | grep :8080 || echo "No process listening on port 8080"
    
    # If we've been waiting for a while, try to manually start the web server
    if [ $wait_time -gt 60 ]; then
      echo "--- Attempting to manually start web services ---"
      docker exec ondemand systemctl restart httpd || true
      docker exec ondemand systemctl restart apache2 || true
    fi
  fi
  
  # Only increment wait time and sleep if we haven't confirmed readiness
  if [ "$is_ready" = false ]; then
    sleep 10
    wait_time=$((wait_time + 10))
  fi
done

# Final verification
if [ "$is_ready" = false ]; then
  echo "❌ Open OnDemand failed to start within $max_wait seconds"
  docker logs ondemand
  exit 1
else
  echo "✅ Open OnDemand setup complete!"
  echo 
  echo "-----------------------------------------------------------"
  echo "🌐 Access Open OnDemand at: http://localhost:8080"
  echo "-----------------------------------------------------------"
  echo
  echo "📋 Management commands:"
  echo "  • Check container: docker ps -a | grep ondemand"
  echo "  • View logs: docker logs ondemand"
  echo "  • Restart container: docker restart ondemand"
  echo "  • Stop container: docker stop ondemand"
  echo "  • Shell access: docker exec -it ondemand bash"
  echo 
  echo "Alternative deployment using docker-compose:"
  echo "  • docker-compose -f /opt/ood/docker-compose-ondemand.yml up -d"
  echo
  echo "If using Vagrant, remember to forward port 8080 to access from host machine"
  echo "Example: config.vm.network 'forwarded_port', guest: 8080, host: 8080"
fi