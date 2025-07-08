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
  return "ubuntu/jammy64"  # Ubuntu 22.04 LTS
end

BASE_BOX = get_base_box()

Vagrant.configure("2") do |config|
  # Use either base box or Ubuntu 18.04 LTS
  config.vm.box = BASE_BOX

  # Shared folder configuration
  config.vm.synced_folder "./scripts", "/home/vagrant/scripts", type: "rsync"
  config.vm.synced_folder "./sample-jobs", "/home/vagrant/sample-jobs", type: "rsync"
  config.vm.synced_folder "./tmp/slurm", "/home/vagrant/slurm-src", type: "rsync", rsync__exclude: [".git/", "*.o", "*.lo", "*.la"]
  config.vm.synced_folder "./tmp", "/home/vagrant/tmp", type: "rsync", rsync__exclude: ["*.o", "*.lo", "*.la", "node_modules/", "*.pyc", "__pycache__/"]
  
  # Global VM settings
  config.vm.provider "virtualbox" do |vb|
    vb.gui = false
    vb.customize ["modifyvm", :id, "--natdnshostresolver1", "on"]
    vb.customize ["modifyvm", :id, "--natdnsproxy1", "on"]
  end

  # Base VM for creating Slurm base box (only when SLURM_BUILD_BASE=true)
  config.vm.define "base", autostart: false do |base|
    base.vm.box = "ubuntu/jammy64"  # Always use Ubuntu 22.04 LTS for base building
    base.vm.hostname = "slurm-base"
    base.vm.network "private_network", ip: "192.168.60.100"
    
    base.vm.provider "virtualbox" do |vb|
      vb.memory = "2048"
      vb.cpus = 2
      vb.name = "slurm-base-builder"
    end

    # Sync folders for base building
    base.vm.synced_folder "./scripts", "/home/vagrant/scripts", type: "rsync"
    base.vm.synced_folder "./tmp/slurm", "/home/vagrant/slurm-src", type: "rsync", rsync__exclude: [".git/", "*.o", "*.lo", "*.la"]

    # Build base system with Slurm compiled using shared setup script
    base.vm.provision "shell", inline: <<-SHELL
      echo "🏗️ Building Slurm base image using shared setup script..."
      
      # Make scripts executable
      chmod +x /home/vagrant/scripts/*.sh

      # Run the shared HPC base setup script
      /home/vagrant/scripts/setup-base.sh --clean-for-imaging
      
      # Mark as base image (additional marker for Vagrant)
      echo "slurm-base-$(date +%Y%m%d)" > /etc/slurm-base-version
      
      echo "✅ Slurm base image ready!"
      echo "📋 Slurm version: $(/opt/slurm/sbin/slurmctld -V 2>/dev/null | head -1 || echo 'Slurm installed successfully')"
    SHELL
  end

  # Slurm Controller Node (slurmctld)
  config.vm.define "controller" do |controller|
    controller.vm.hostname = "slurm-controller"
    controller.vm.network "private_network", ip: "192.168.60.10"
    controller.vm.network "forwarded_port", guest: 80, host: 8080, auto_correct: true
    controller.vm.network "forwarded_port", guest: 8081, host: 8081, auto_correct: true
    
    controller.vm.provider "virtualbox" do |vb|
      vb.memory = "2048"
      vb.cpus = 2
      vb.name = "slurm-controller"
    end

    # Install and configure Slurm controller
    controller.vm.provision "shell", inline: <<-SHELL
      echo "🚀 Setting up Slurm Controller..."
      echo "📦 Using base box: #{BASE_BOX}"
      
      # Make scripts executable
      chmod +x /home/vagrant/scripts/*.sh

      echo "192.168.60.10 slurm-controller controller" >> /etc/hosts
      echo "192.168.60.11 node1" >> /etc/hosts
      echo "192.168.60.12 node2" >> /etc/hosts
      echo "192.168.60.13 node3" >> /etc/hosts
      
      # Set hostname
      hostnamectl set-hostname slurm-controller
      
      # Only install dependencies if not using base box
      if [ "#{BASE_BOX}" = "ubuntu/jammy64" ]; then
        echo "📦 Installing dependencies using shared setup script..."
        /home/vagrant/scripts/setup-base.sh
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

      # Run the setup script for the Slurm Database Daemon
      /home/vagrant/scripts/setup-slurmdbd.sh
      
      echo "✅ Slurm Database Daemon setup complete."
    SHELL

    # Install and configure Open OnDemand
    controller.vm.provision "shell", inline: <<-SHELL
      echo "🌐 Setting up Open OnDemand..."
      if [ -f /home/vagrant/scripts/setup-ondemand.sh ]; then
        chmod +x /home/vagrant/scripts/setup-ondemand.sh
        /home/vagrant/scripts/setup-ondemand.sh
        echo "✅ Open OnDemand setup complete."
        echo "👉 Access the portal at http://localhost:8080"
      else
        echo "🤷 Skipping Open OnDemand setup: script not found."
      fi
    SHELL

    # Install and configure slurm-web from source
    controller.vm.provision "shell", inline: <<-SHELL
      echo "🌐 Setting up slurm-web from source..."
      if [ -f /home/vagrant/scripts/setup-slurm-web.sh ]; then
        chmod +x /home/vagrant/scripts/setup-slurm-web.sh
        /home/vagrant/scripts/setup-slurm-web.sh
        echo "✅ slurm-web setup complete."
        echo "👉 Access the portal at http://localhost:8081"
      else
        echo "🤷 Skipping slurm-web setup: script not found."
      fi
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

        # Make scripts executable
        chmod +x /home/vagrant/scripts/*.sh

        echo "192.168.60.10 slurm-controller controller" >> /etc/hosts
        echo "192.168.60.11 node1" >> /etc/hosts
        echo "192.168.60.12 node2" >> /etc/hosts
        echo "192.168.60.13 node3" >> /etc/hosts
        
        # Set hostname
        hostnamectl set-hostname node#{i}
        
        # Only install dependencies if not using base box
        if [ "#{BASE_BOX}" = "ubuntu/jammy64" ]; then
          echo "📦 Installing dependencies using shared setup script..."
          /home/vagrant/scripts/setup-base.sh
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
