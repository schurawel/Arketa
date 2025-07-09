# -*- mode: ruby -*-
# vi: set ft=ruby :

# Slurm Multi-Node Cluster Configuration
# Supports two modes:
# 1. Base building mode: SLURM_BUILD_BASE=true vagrant up base
# 2. Cluster mode: vagrant up controller node1 node2

# Check if we should use base box or build from scratch
def get_base_box
  if ENV['SLURM_USE_BASE'] == 'true'
    result = `vagrant box list 2>/dev/null | grep slurm-base`
    if $?.success? && !result.empty?
      return "slurm-base"
    end
  end
  return "generic/ubuntu2204"  # Ubuntu 22.04 LTS with libvirt support
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
  
  # Create a private network for cluster communication
  # config.vm.network "private_network", type: "dhcp"

  # Global VM settings for libvirt provider
  config.vm.provider "libvirt" do |lv|
    lv.driver = "kvm"
    lv.memory = 2048
    lv.cpus = 2
    lv.nested = true
    lv.cpu_mode = "host-passthrough"
    lv.graphics_type = "none"
    lv.management_network_name = "vagrant-libvirt"
  end

  # Base VM for creating Slurm base box (only when SLURM_BUILD_BASE=true)
  config.vm.define "base", autostart: false do |base|
    base.vm.box = "generic/ubuntu2204"  # Ubuntu 22.04 LTS with libvirt support
    base.vm.hostname = "slurm-base"
    
    # NOTE: No private network is defined for the base image. It only needs
    # to be provisioned, not to communicate with other cluster nodes.
    
    base.vm.provider "libvirt" do |lv|
      lv.memory = 3072
      lv.cpus = 2
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

  # Slurm Controller Node (slurmctld) - Must be provisioned first
  config.vm.define "controller", primary: true do |controller|
    controller.vm.hostname = "slurm-controller"
    controller.vm.network "private_network", ip: "192.168.121.10"
    
    # Port forwarding for web interfaces
    controller.vm.network "forwarded_port", guest: 80, host: 8080
    controller.vm.network "forwarded_port", guest: 8081, host: 8081
    
    controller.vm.provider "libvirt" do |lv|
      lv.memory = 3072
      lv.cpus = 2
    end

    # Install and configure Slurm controller
    controller.vm.provision "shell", inline: <<-SHELL
      echo "🚀 Setting up Slurm Controller..."
      echo "📦 Using base box: #{BASE_BOX}"
      
      # Make scripts executable
      chmod +x /home/vagrant/scripts/*.sh

      echo "192.168.121.10 slurm-controller controller" >> /etc/hosts
      echo "192.168.121.11 node1" >> /etc/hosts
      echo "192.168.121.12 node2" >> /etc/hosts
      
      # Set hostname
      hostnamectl set-hostname slurm-controller
      
      apt-get update
      apt-get install -y nfs-kernel-server
      
      # Setup shared directory
      mkdir -p /shared
      chown slurm:slurm /shared
      chmod 755 /shared
      
      # Configure NFS export for shared directory
      echo "/shared 192.168.121.0/24(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports
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

    # Mark controller as fully provisioned
    controller.vm.provision "shell", inline: <<-SHELL
      echo "🎯 Controller provisioning complete"
      echo "✅ Controller node fully configured and ready for compute nodes"
    SHELL
  end

  # Slurm Compute Nodes (slurmd)
  (1..2).each do |i|
    config.vm.define "node#{i}" do |node|
      node.vm.hostname = "node#{i}"
      node.vm.network "private_network", ip: "192.168.121.#{10 + i}"
      
      node.vm.provider "libvirt" do |lv|
        lv.memory = 2048
        lv.cpus = 2
      end

      # Install and configure Slurm compute node
      node.vm.provision "shell", inline: <<-SHELL
        echo "⚙️ Setting up Compute Node #{i}..."
        echo "📦 Using base box: #{BASE_BOX}"

        # Make scripts executable
        chmod +x /home/vagrant/scripts/*.sh

        echo "192.168.121.10 slurm-controller controller" >> /etc/hosts
        echo "192.168.121.11 node1" >> /etc/hosts
        echo "192.168.121.12 node2" >> /etc/hosts
        
        # Set hostname
        hostnamectl set-hostname node#{i}
        
        apt-get update
        apt-get install -y nfs-common

        
        # Mount shared directory
        mkdir -p /shared
        echo "slurm-controller:/shared /shared nfs defaults 0 0" >> /etc/fstab
        
        # Run compute node setup script
        /home/vagrant/scripts/setup-compute.sh
        
        echo "✅ Compute Node #{i} fully configured and ready"
      SHELL
    end
  end
end

