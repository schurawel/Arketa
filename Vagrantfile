# -*- mode: ruby -*-
# vi: set ft=ruby :

# Slurm Multi-Node Cluster Configuration
# Supports two modes:
# 1. Base building mode: SLURM_BUILD_BASE=true vagrant up base
# 2. Cluster mode: vagrant up controller node1 node2 node3

# Check if we should use base box or build from scratch
def get_base_box
  if ENV['SLURM_USE_BASE'] == 'true'
    result = `vagrant box list 2>/dev/null | grep slurm-base`
    if $?.success? && !result.empty?
      return "slurm-base"
    end
  end
  return "hashicorp/bionic64"
end

BASE_BOX = get_base_box()

Vagrant.configure("2") do |config|
  # Use either base box or Ubuntu 18.04 LTS
  config.vm.box = BASE_BOX

  # Shared folder configuration
  config.vm.synced_folder "./scripts", "/home/vagrant/scripts", type: "rsync"
  config.vm.synced_folder "./sample-jobs", "/home/vagrant/sample-jobs", type: "rsync"
  
  # Only sync slurm source if not using base box
  if BASE_BOX == "hashicorp/bionic64"
    config.vm.synced_folder "./tmp/slurm", "/home/vagrant/slurm-src", type: "rsync", rsync__exclude: [".git/", "*.o", "*.lo", "*.la"]
  end
  
  # Global VM settings
  config.vm.provider "virtualbox" do |vb|
    vb.gui = false
    vb.customize ["modifyvm", :id, "--natdnshostresolver1", "on"]
    vb.customize ["modifyvm", :id, "--natdnsproxy1", "on"]
  end

  # Base VM for creating Slurm base box (only when SLURM_BUILD_BASE=true)
  config.vm.define "base", autostart: false do |base|
    base.vm.box = "hashicorp/bionic64"  # Always use Ubuntu for base building
    base.vm.hostname = "slurm-base"
    base.vm.network "private_network", ip: "192.168.60.100"
    
    base.vm.provider "virtualbox" do |vb|
      vb.memory = "2048"
      vb.cpus = 2
      vb.name = "slurm-base-builder"
    end

    # Sync folders for base building
    base.vm.synced_folder "./tmp/slurm", "/home/vagrant/slurm-src", type: "rsync", rsync__exclude: [".git/", "*.o", "*.lo", "*.la"]

    # Build base system with Slurm compiled
    base.vm.provision "shell", inline: <<-SHELL
      echo "🏗️ Building Slurm base image..."
      
      # Update system
      apt-get update
      apt-get upgrade -y
      
      # Install all dependencies for both controller and compute nodes
      apt-get install -y build-essential git autoconf automake libtool \
          pkg-config libssl-dev libpam0g-dev libnuma-dev libhwloc-dev \
          libfreeipmi-dev librrd-dev libncurses5-dev libreadline-dev \
          python3-dev python3-pip munge libmunge-dev libmunge2 \
          cmake wget curl vim nfs-kernel-server nfs-common chrony
      
      # Create slurm user
      useradd -r -s /bin/false slurm || true
      
      # Build and install Slurm (done once for base image)
      echo "📦 Compiling Slurm from source..."
      
      # Create build directory with proper ownership
      mkdir -p /tmp/slurm-build
      cp -r /home/vagrant/slurm-src/* /tmp/slurm-build/
      chown -R vagrant:vagrant /tmp/slurm-build
      cd /tmp/slurm-build
      
      # Make sure configure script is executable
      chmod +x configure
      
      # Configure and build Slurm as vagrant user
      sudo -u vagrant ./configure --prefix=/opt/slurm --sysconfdir=/etc/slurm \
          --enable-pam --with-pam_dir=/lib/x86_64-linux-gnu/security/ \
          --without-shared-libslurm 2>&1 | tee configure.log
      
      # Check if configure succeeded
      if [ ! -f Makefile ]; then
        echo "❌ Configure failed! Check configure.log:"
        tail -20 configure.log
        exit 1
      fi
      
      sudo -u vagrant make -j$(nproc)
      make install
      
      # Create necessary directories
      mkdir -p /etc/slurm /var/spool/slurmctld /var/spool/slurmd /var/log/slurm /opt/slurm/var/run
      chown -R slurm:slurm /var/spool/slurmctld /var/spool/slurmd /var/log/slurm /opt/slurm/var/run
      
      # Add Slurm binaries to PATH
      echo 'export PATH="/opt/slurm/bin:/opt/slurm/sbin:$PATH"' > /etc/profile.d/slurm.sh
      echo 'export LD_LIBRARY_PATH="/opt/slurm/lib:$LD_LIBRARY_PATH"' >> /etc/profile.d/slurm.sh
      chmod +x /etc/profile.d/slurm.sh
      
      # Clean up build directory
      rm -rf /tmp/slurm-build
      
      # Mark as base image
      echo "slurm-base-$(date +%Y%m%d)" > /etc/slurm-base-version
      
      echo "✅ Slurm base image ready!"
      echo "📋 Slurm version: $(/opt/slurm/sbin/slurmctld -V 2>/dev/null | head -1 || echo 'Slurm installed successfully')"
    SHELL
  end

  # Slurm Controller Node (slurmctld)
  config.vm.define "controller" do |controller|
    controller.vm.hostname = "slurm-controller"
    controller.vm.network "private_network", ip: "192.168.60.10"
    
    controller.vm.provider "virtualbox" do |vb|
      vb.memory = "2048"
      vb.cpus = 2
      vb.name = "slurm-controller"
    end

    # Install and configure Slurm controller
    controller.vm.provision "shell", inline: <<-SHELL
      echo "🚀 Setting up Slurm Controller..."
      echo "📦 Using base box: #{BASE_BOX}"
      
      echo "192.168.60.10 slurm-controller" >> /etc/hosts
      echo "192.168.60.11 node1" >> /etc/hosts
      echo "192.168.60.12 node2" >> /etc/hosts
      echo "192.168.60.13 node3" >> /etc/hosts
      
      # Set hostname
      hostnamectl set-hostname slurm-controller
      
      # Only install dependencies if not using base box
      if [ "#{BASE_BOX}" = "hashicorp/bionic64" ]; then
        echo "📦 Installing dependencies (not using base box)..."
        apt-get update
        apt-get upgrade -y
        apt-get install -y build-essential git autoconf automake libtool \
            pkg-config libssl-dev libpam0g-dev libnuma-dev libhwloc-dev \
            libfreeipmi-dev librrd-dev libncurses5-dev libreadline-dev \
            python3-dev python3-pip munge libmunge-dev libmunge2 \
            cmake wget curl vim nfs-kernel-server chrony
        useradd -r -s /bin/false slurm || true
      else
        echo "⚡ Using pre-built base box - skipping dependency installation"
        apt-get update
        apt-get install -y nfs-kernel-server
      fi
      
      # Setup shared directory
      mkdir -p /shared
      chown slurm:slurm /shared
      chmod 755 /shared
      
      # Configure NFS export for shared directory
      echo "/shared 192.168.60.0/24(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports
      systemctl enable nfs-kernel-server
      systemctl start nfs-kernel-server
      exportfs -a
      
      # Run controller setup script
      /home/vagrant/scripts/setup-controller.sh
    SHELL
  end

  # Slurm Compute Nodes
  (1..3).each do |i|
    config.vm.define "node#{i}" do |node|
      node.vm.hostname = "node#{i}"
      node.vm.network "private_network", ip: "192.168.60.#{10+i}"
      
      node.vm.provider "virtualbox" do |vb|
        vb.memory = "1024"
        vb.cpus = 2
        vb.name = "slurm-node#{i}"
      end

      # Install and configure Slurm compute node
      node.vm.provision "shell", inline: <<-SHELL
        echo "⚙️ Setting up Compute Node #{i}..."
        echo "📦 Using base box: #{BASE_BOX}"
        
        echo "192.168.60.10 slurm-controller" >> /etc/hosts
        echo "192.168.60.11 node1" >> /etc/hosts
        echo "192.168.60.12 node2" >> /etc/hosts
        echo "192.168.60.13 node3" >> /etc/hosts
        
        # Set hostname
        hostnamectl set-hostname node#{i}
        
        # Only install dependencies if not using base box
        if [ "#{BASE_BOX}" = "hashicorp/bionic64" ]; then
          echo "📦 Installing dependencies (not using base box)..."
          apt-get update
          apt-get upgrade -y
          apt-get install -y build-essential git autoconf automake libtool \
              pkg-config libssl-dev libpam0g-dev libnuma-dev libhwloc-dev \
              libfreeipmi-dev librrd-dev libncurses5-dev libreadline-dev \
              python3-dev python3-pip munge libmunge-dev libmunge2 \
              libmariadb-dev cmake wget curl vim nfs-common chrony
          useradd -r -s /bin/false slurm || true
        else
          echo "⚡ Using pre-built base box - skipping dependency installation"
          apt-get update
          apt-get install -y nfs-common
        fi
        
        # Mount shared directory
        mkdir -p /shared
        echo "slurm-controller:/shared /shared nfs defaults 0 0" >> /etc/fstab
        
        # Run compute node setup script
        /home/vagrant/scripts/setup-compute.sh #{i}
      SHELL
    end
  end
end
