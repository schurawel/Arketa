# Slurm HPC Cluster Makefile
# Automated cluster management and testing

.PHONY: help cluster cluster-full test status connect logs health stop start clean clean-vms force-clean setup-libvirt
.PHONY: test-hello test-parallel test-stress test-array show-outputs wait-for-jobs test-and-wait
.PHONY: test-python test-apptainer test-ml test-distributed test-extended test-mpi
.PHONY: show-job-output show-all-outputs show-latest-outputs
.PHONY: ondemand slurm-web open-ondemand open-slurm-web slurm-web-diag
.PHONY: build-vagrant build-base remove-base list-boxes preflight setup-repos
.PHONY: metal sim-metal sim-metal-status sim-metal-stop sim-metal-clean sim-metal-connect metal-clean
.PHONY: q-cluster-refresh-samples

# Default target
.DEFAULT_GOAL := help

# Colors for output
RED = \033[0;31m
GREEN = \033[0;32m
YELLOW = \033[1;33m
BLUE = \033[0;34m
BOLD = \033[1m
NC = \033[0m # No Color

# Configuration
VAGRANT_WRAPPER = ./vagrant-wrapper.sh
CLUSTER_MANAGER = ./cluster-manager.sh
PREFLIGHT_CHECK = ./preflight-check-source.sh
QEMU_SCRIPT = ./qemu-cluster.sh

## 🎯 Main Targets

help: ## 📋 Show this help message
	@echo "$(BOLD)Slurm HPC Cluster - Available Commands$(NC)"
	@echo "======================================"
	@echo ""
	@echo "$(GREEN)🚀 Getting Started:$(NC)"
	@echo "  $(BOLD)make setup-repos$(NC)      - Clone required repositories (auto-run by other targets)"
	@echo "  $(BOLD)make build-base$(NC)       - Create base box with Slurm pre-compiled (do this first)"
	@echo "  $(BOLD)make cluster$(NC)          - Complete cluster setup using base box (Vagrant)"
	@echo "  $(BOLD)make q-cluster$(NC)        - Build and start QEMU-based Slurm cluster"
	@echo "  $(BOLD)make q-cluster-test$(NC)   - Run test jobs on QEMU cluster"
	@echo "  $(BOLD)make test$(NC)             - Run all sample jobs (Vagrant)"
	@echo "  $(BOLD)make test-and-wait$(NC)    - Run tests and wait for completion with results"
	@echo "  $(BOLD)make connect$(NC)          - SSH to controller node"
	@echo ""
	@echo "$(BLUE)📊 Cluster Management:$(NC)"
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  $(BOLD)%-20s$(NC) %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo ""
	@echo "$(YELLOW)💡 Vagrant Workflow:$(NC)"
	@echo "  make setup-repos      # Clone repositories (auto-run by other targets)"
	@echo "  make build-base       # Build once (takes ~10-15 min)"
	@echo "  make cluster          # Deploy fast cluster (~2-3 min)"
	@echo "  make test-and-wait    # Test with full monitoring"
	@echo ""
	@echo "$(BLUE)💡 QEMU Workflow:$(NC)"
	@echo "  make q-cluster        # Build and start QEMU cluster"
	@echo "  make q-cluster-test   # Run test jobs on QEMU cluster"
	@echo "  make q-cluster-status # Show QEMU cluster status"
	@echo "  make q-cluster-connect# SSH to QEMU controller"
	@echo "  make q-cluster-clean  # Remove QEMU cluster VMs (keep base image)"
	@echo "  make q-cluster-clean-all # Remove QEMU cluster and base image"
	@echo ""
	@echo "$(YELLOW)🏗️ Bare Metal Workflow:$(NC)"
	@echo "  make metal            # Create custom Ubuntu ISO (independent)"
	@echo "  make sim-metal        # Test with QEMU simulation"
	@echo "  make sim-metal-status # Check simulation status"
	@echo "  make metal-clean      # Clean up ISO workspace"
	@echo "  make clean            # Clean up completely"

cluster: clean setup-repos preflight build-base ## 🚀 Complete cluster setup using base box (recommended)
	@echo "$(GREEN)[INFO]$(NC) Starting cluster deployment..."
	@echo "$(BLUE)[INFO]$(NC) Base box check complete. Proceeding with cluster setup..."
	
	@# Step 1: Start VMs one by one to avoid network conflicts
	@echo "$(BLUE)[STEP 1/4]$(NC) Starting controller VM first..."
	SLURM_USE_BASE=true $(VAGRANT_WRAPPER) up --no-provision controller || { echo "$(RED)[ERROR]$(NC) Failed to start controller VM"; exit 1; }
	
	@echo "$(BLUE)[STEP 2/4]$(NC) Starting compute node1..."
	SLURM_USE_BASE=true $(VAGRANT_WRAPPER) up --no-provision node1 || { echo "$(RED)[ERROR]$(NC) Failed to start node1 VM"; exit 1; }
	
	@echo "$(BLUE)[STEP 3/4]$(NC) Starting compute node2..."
	SLURM_USE_BASE=true $(VAGRANT_WRAPPER) up --no-provision node2 || { echo "$(RED)[ERROR]$(NC) Failed to start node2 VM"; exit 1; }
	
	@echo "$(BLUE)[STEP 4/4]$(NC) Provisioning VMs in the correct order..."
	
	@# Wait for controller SSH with more logging
	@echo "$(BLUE)[INFO]$(NC) Waiting for controller to be ready for SSH..."
	@for attempt in 1 2 3 4 5; do \
		echo "$(BLUE)[INFO]$(NC) Controller SSH connectivity check (attempt $$attempt/5)..."; \
		if $(VAGRANT_WRAPPER) ssh controller -c "echo 'Controller SSH is ready'" >/dev/null 2>&1; then \
			echo "$(GREEN)[SUCCESS]$(NC) Controller SSH is ready!"; \
			break; \
		fi; \
		if [ $$attempt -eq 5 ]; then \
			echo "$(RED)[ERROR]$(NC) Failed to connect to controller after 5 attempts"; \
			echo "$(YELLOW)[INFO]$(NC) Showing controller status:"; \
			$(VAGRANT_WRAPPER) status controller; \
			exit 1; \
		fi; \
		echo "$(YELLOW)[WARN]$(NC) Controller not ready. Waiting 30 seconds..."; \
		sleep 30; \
	done
	
	@echo "$(BLUE)[INFO]$(NC) Running controller setup script..."
	@$(VAGRANT_WRAPPER) ssh controller -c "cd /home/vagrant && chmod +x scripts/*.sh && sudo scripts/setup-controller.sh" || { \
		echo "$(RED)[ERROR]$(NC) Controller setup script failed"; \
		exit 1; \
	}
	
	@# Wait for node1 SSH
	@echo "$(BLUE)[INFO]$(NC) Waiting for node1 to be ready for SSH..."
	@for attempt in 1 2 3 4 5; do \
		echo "Controller setup done. Checking node1 SSH connectivity (attempt $$attempt/5)..."; \
		if $(VAGRANT_WRAPPER) ssh node1 -c "echo 'Node1 SSH is ready'" >/dev/null 2>&1; then \
			echo "$(GREEN)[SUCCESS]$(NC) Node1 SSH is ready!"; \
			break; \
		fi; \
		if [ $$attempt -eq 5 ]; then \
			echo "$(YELLOW)[WARNING]$(NC) Could not connect to node1 after 5 attempts. Skipping."; \
			continue; \
		fi; \
		echo "$(YELLOW)[WARN]$(NC) Node1 not ready. Waiting 30 seconds..."; \
		sleep 30; \
	done
	
	@echo "$(BLUE)[INFO]$(NC) Copying setup files to node1..."
	@$(VAGRANT_WRAPPER) ssh node1 -c "cd /home/vagrant && tar -czf /tmp/compute-files.tar.gz scripts" || true
	@$(VAGRANT_WRAPPER) ssh node1 -c "sudo cp /tmp/compute-files.tar.gz /shared/" || true
	
	@echo "$(BLUE)[INFO]$(NC) Running node1 setup script..."
	@$(VAGRANT_WRAPPER) ssh node1 -c "cd /home/vagrant && \
		sudo mkdir -p /shared && \
		sudo mount -t nfs slurm-controller:/shared /shared || echo 'Warning: NFS mount failed' && \
		(if [ -f /shared/compute-files.tar.gz ]; then sudo tar -xzf /shared/compute-files.tar.gz -C /home/vagrant; fi) && \
		chmod +x scripts/*.sh && sudo scripts/setup-compute.sh 1" || { \
		echo "$(YELLOW)[WARNING]$(NC) Node1 setup script had issues."; \
	}
	
	@# Wait for node2 SSH
	@echo "$(BLUE)[INFO]$(NC) Waiting for node2 to be ready for SSH..."
	@for attempt in 1 2 3 4 5; do \
		echo "Node1 setup done. Checking node2 SSH connectivity (attempt $$attempt/5)..."; \
		if $(VAGRANT_WRAPPER) ssh node2 -c "echo 'Node2 SSH is ready'" >/dev/null 2>&1; then \
			echo "$(GREEN)[SUCCESS]$(NC) Node2 SSH is ready!"; \
			break; \
		fi; \
		if [ $$attempt -eq 5 ]; then \
			echo "$(YELLOW)[WARNING]$(NC) Could not connect to node2 after 5 attempts. Skipping."; \
			continue; \
		fi; \
		echo "$(YELLOW)[WARN]$(NC) Node2 not ready. Waiting 30 seconds..."; \
		sleep 30; \
	done
	
	@echo "$(BLUE)[INFO]$(NC) Running node2 setup script..."
	@$(VAGRANT_WRAPPER) ssh node2 -c "cd /home/vagrant && \
		sudo mkdir -p /shared && \
		sudo mount -t nfs slurm-controller:/shared /shared || echo 'Warning: NFS mount failed' && \
		(if [ -f /shared/compute-files.tar.gz ]; then sudo tar -xzf /shared/compute-files.tar.gz -C /home/vagrant; fi) && \
		chmod +x scripts/*.sh && sudo scripts/setup-compute.sh 2" || { \
		echo "$(YELLOW)[WARNING]$(NC) Node2 setup script had issues."; \
	}
	
	@echo "$(BLUE)[STEP]$(NC) Waiting for services to initialize..."
	@sleep 60
	@echo "$(BLUE)[STEP]$(NC) Performing health check..."
	@$(MAKE) health || echo "$(YELLOW)[WARNING]$(NC) Health check had issues, but cluster may still be usable."
	@echo "$(GREEN)[SUCCESS]$(NC) Cluster is ready!"
	@echo ""
	@echo "$(BOLD)Next steps:$(NC)"
	@echo "  - Connect to the controller: $(BOLD)make connect$(NC)"
	@echo "  - Run sample jobs: $(BOLD)make test$(NC)"
	@echo "  - Check cluster status: $(BOLD)make status$(NC)"
	@echo "  - Access Open OnDemand: http://localhost:8080"

cluster-full: setup-repos preflight build-vagrant ## 📦 Complete cluster setup from scratch (slower)
	@echo "$(YELLOW)[WARNING]$(NC) Starting full cluster deployment from scratch. This will take a while."
	@echo "$(BLUE)[STEP 1/3]$(NC) Starting controller node..."
	SLURM_USE_BASE=false $(VAGRANT_WRAPPER) up controller
	@echo "$(BLUE)[STEP 2/3]$(NC) Starting compute node 1..."
	SLURM_USE_BASE=false $(VAGRANT_WRAPPER) up node1
	@echo "$(BLUE)[STEP 3/3]$(NC) Starting compute node 2..."
	SLURM_USE_BASE=false $(VAGRANT_WRAPPER) up node2
	@echo "$(BLUE)[STEP]$(NC) Waiting for services to initialize..."
	@sleep 60
	@echo "$(BLUE)[STEP]$(NC) Performing health check..."
	@$(MAKE) health
	@echo "$(GREEN)[SUCCESS]$(NC) Cluster is ready!"

## 🏗️ Base Box Management

build-base: setup-repos preflight build-vagrant ## 📦 Create base box with Slurm pre-compiled
	@if [ -f "boxes/slurm-base.box" ]; then \
		echo "$(GREEN)[INFO]$(NC) Reusable Slurm base box file already exists. Skipping build."; \
		if ! $(VAGRANT_WRAPPER) box list | grep -q "slurm-base"; then \
			echo "$(BLUE)[INFO]$(NC) Adding box to Vagrant..."; \
			$(VAGRANT_WRAPPER) box add --force --name slurm-base boxes/slurm-base.box; \
		fi; \
	else \
		echo "$(YELLOW)[INFO]$(NC) Creating reusable Slurm base box... (This may take 10-15 minutes)"; \
		mkdir -p boxes; \
		$(MAKE) remove-base; \
		SLURM_BUILD_BASE=true $(VAGRANT_WRAPPER) up base; \
		$(VAGRANT_WRAPPER) halt base; \
		$(VAGRANT_WRAPPER) package base --output boxes/slurm-base.box; \
		$(VAGRANT_WRAPPER) box add --force --name slurm-base boxes/slurm-base.box; \
		$(VAGRANT_WRAPPER) destroy -f base; \
		echo "$(GREEN)[SUCCESS]$(NC) Slurm base box created successfully."; \
	fi

remove-base: ## 🗑️ Remove the Slurm base box and its file
	@echo "$(YELLOW)[INFO]$(NC) Removing existing Slurm base box and file..."
	@if $(VAGRANT_WRAPPER) box list | grep -q "slurm-base"; then \
		$(VAGRANT_WRAPPER) box remove -f slurm-base; \
		echo "$(GREEN)[SUCCESS]$(NC) Removed slurm-base box from Vagrant."; \
	else \
		echo "$(BLUE)[INFO]$(NC) No slurm-base box found in Vagrant to remove."; \
	fi
	@if [ -f "boxes/slurm-base.box" ]; then \
		rm -f boxes/slurm-base.box; \
		echo "$(GREEN)[SUCCESS]$(NC) Removed boxes/slurm-base.box file."; \
	fi
	@# Also destroy the base VM if it exists
	@if $(VAGRANT_WRAPPER) status base | grep -q "running"; then \
		$(VAGRANT_WRAPPER) destroy -f base; \
	fi

list-boxes: ## 📦 List all available Vagrant boxes
	@echo "$(BLUE)[INFO]$(NC) Available Vagrant boxes:"
	@$(VAGRANT_WRAPPER) box list

## 🛠️ Cluster Control

test: test-hello test-parallel test-stress test-array ## 🧪 Run all sample jobs
	@echo "$(GREEN)[SUCCESS]$(NC) All primary tests submitted. Use 'make status' to monitor."

status: ## 📊 Show cluster status and job queue
	@$(CLUSTER_MANAGER) status

connect: ## 🔌 SSH to the controller node
	@$(VAGRANT_WRAPPER) ssh controller

logs: ## 📜 Tail logs for a specific node (e.g., make logs node=controller)
	@$(VAGRANT_WRAPPER) ssh $(node) -- -t "sudo journalctl -fu slurmd"

health: ## ❤️ Perform a health check of the cluster
	@$(CLUSTER_MANAGER) health-check

stop: ## 🛑 Stop all running VMs
	@echo "$(YELLOW)[INFO]$(NC) Stopping all cluster VMs..."
	@$(VAGRANT_WRAPPER) halt controller node1 node2

start: ## ▶️ Start all cluster VMs
	@echo "$(GREEN)[INFO]$(NC) Starting all cluster VMs..."
	@$(VAGRANT_WRAPPER) up --no-provision controller node1 node2

clean: ## 🗑️ Clean up the cluster environment
	@echo "$(YELLOW)[INFO]$(NC) Destroying cluster VMs (controller, node1, node2)..."
	@$(VAGRANT_WRAPPER) destroy -f controller node1 node2 >/dev/null 2>&1 || true
	@echo "$(GREEN)[SUCCESS]$(NC) Cluster VMs destroyed."
	@echo "$(YELLOW)[INFO]$(NC) Cleaning up leftover libvirt domains and volumes..."
	@for domain in $$(virsh list --all --name | grep PrimedSLURM); do \
		echo "Removing domain: $$domain"; \
		virsh destroy $$domain >/dev/null 2>&1 || true; \
		virsh undefine $$domain --remove-all-storage >/dev/null 2>&1 || true; \
	done
	@echo "$(YELLOW)[INFO]$(NC) Cleaning up orphaned libvirt volumes..."
	@for volume in $$(virsh vol-list default 2>/dev/null | grep PrimedSLURM | awk '{print $$1}'); do \
		echo "Removing volume: $$volume"; \
		virsh vol-delete $$volume default >/dev/null 2>&1 || true; \
	done
	@echo "$(GREEN)[SUCCESS]$(NC) Libvirt domains and volumes cleaned up."
	@rm -rf .vagrant;
	@if [ -f "boxes/slurm-base.box" ]; then \
		echo; \
		printf "$(YELLOW)A reusable base box file was found. Do you want to delete it? [y/N] $(NC)"; \
		read -r reply; \
		case "$$reply" in \
			[Yy]*) \
				$(MAKE) remove-base; \
				;; \
			*) \
				echo "$(BLUE)INFO:$(NC) Base box preserved."; \
				;; \
		esac; \
	fi
	@echo
	@printf "$(YELLOW)The 'tmp' directory contains cloned source code. Do you want to delete it? [y/N] $(NC)"; \
	read -r reply; \
	case "$$reply" in \
		[Yy]*) \
			echo "Deleting 'tmp' directory..."; \
			rm -rf tmp; \
			echo "$(GREEN)[SUCCESS]$(NC) 'tmp' directory deleted."; \
			;; \
		*) \
			echo "$(BLUE)INFO:$(NC) 'tmp' directory preserved."; \
			;; \
	esac
	@echo
	@echo "$(GREEN)Cleanup complete.$(NC)"

## 🌐 Web Interfaces

ondemand: ## 🌐 Start Open OnDemand service
	@echo "$(BLUE)[INFO]$(NC) Ensuring Open OnDemand is set up..."
	@sshpass -p "ubuntu" ssh -o StrictHostKeyChecking=no ubuntu@192.168.7.10 "sudo systemctl status apache2 | grep Active" || \
		(echo "$(YELLOW)[WARNING]$(NC) Open OnDemand service not running on controller"; \
		echo "$(BLUE)[INFO]$(NC) Attempting to start Open OnDemand service..."; \
		sshpass -p "ubuntu" ssh -o StrictHostKeyChecking=no ubuntu@192.168.7.10 "sudo systemctl start apache2" || true)
	@echo "$(GREEN)[SUCCESS]$(NC) Open OnDemand is running. Access at http://192.168.7.10/"
	@xdg-open http://192.168.7.10/ 2>/dev/null || echo "$(BLUE)[INFO]$(NC) Open http://192.168.7.10/ in your browser."

open-ondemand: ## 🌐 Open the OnDemand web interface in browser
	@echo "$(BLUE)[INFO]$(NC) Opening OnDemand web interface..."
	@if ping -c 1 -W 2 192.168.7.10 > /dev/null 2>&1; then \
		echo "$(GREEN)[SUCCESS]$(NC) Controller VM is reachable at 192.168.7.10"; \
		echo "$(BLUE)[INFO]$(NC) Checking if OnDemand is properly configured..."; \
		if sshpass -p "ubuntu" ssh -o StrictHostKeyChecking=no ubuntu@192.168.7.10 "curl -s -u ooduser:ooduser http://localhost/ 2>&1 | grep -q 'Open OnDemand'" > /dev/null 2>&1; then \
			echo "$(GREEN)[SUCCESS]$(NC) OnDemand portal is running properly"; \
			echo "$(YELLOW)[INFO]$(NC) Login credentials - Username: ooduser, Password: ooduser"; \
			xdg-open http://192.168.7.10/ 2>/dev/null || echo "$(BLUE)[INFO]$(NC) Open http://192.168.7.10/ in your browser"; \
		else \
			echo "$(YELLOW)[WARNING]$(NC) OnDemand portal not responding correctly"; \
			echo "$(BLUE)[INFO]$(NC) Running diagnostics..."; \
			$(MAKE) ondemand-diag; \
		fi; \
	else \
		echo "$(RED)[ERROR]$(NC) Cannot reach controller VM at 192.168.7.10"; \
		echo "$(YELLOW)[TIP]$(NC) Make sure the QEMU cluster is running with: make q-cluster"; \
	fi

ondemand-diag: ## 🔍 Diagnose OnDemand configuration issues
	@echo "$(BLUE)[INFO]$(NC) Running OnDemand diagnostics..."
	@if ! ping -c 1 -W 2 192.168.7.10 > /dev/null 2>&1; then \
		echo "$(RED)[ERROR]$(NC) Cannot ping controller at 192.168.7.10. Is the cluster running?"; \
		exit 1; \
	fi
	@echo "$(GREEN)[SUCCESS]$(NC) Controller VM is reachable"
	
	@echo "$(BLUE)[INFO]$(NC) Checking Apache configuration..."
	@sshpass -p "ubuntu" ssh -o StrictHostKeyChecking=no ubuntu@192.168.7.10 "sudo apache2ctl -S" || \
		echo "$(RED)[ERROR]$(NC) Apache configuration has errors"
	
	@echo "$(BLUE)[INFO]$(NC) Checking enabled Apache sites..."
	@sshpass -p "ubuntu" ssh -o StrictHostKeyChecking=no ubuntu@192.168.7.10 "ls -la /etc/apache2/sites-enabled/" || true
	
	@echo "$(BLUE)[INFO]$(NC) Checking OnDemand portal configuration..."
	@sshpass -p "ubuntu" ssh -o StrictHostKeyChecking=no ubuntu@192.168.7.10 "sudo cat /etc/ood/config/ood_portal.yml 2>/dev/null | head -20" || \
		echo "$(YELLOW)[WARNING]$(NC) OnDemand portal config not found"
	
	@echo "$(BLUE)[INFO]$(NC) Attempting to fix OnDemand configuration..."
	@sshpass -p "ubuntu" ssh -o StrictHostKeyChecking=no ubuntu@192.168.7.10 << 'EOF'
		# Disable default site if enabled
		sudo a2dissite 000-default 2>/dev/null || true
		
		# Enable OnDemand portal
		sudo a2ensite ood-portal 2>/dev/null || {
			echo "ERROR: ood-portal site not found. OnDemand may not be installed correctly."
			echo "Try running: sudo /home/ubuntu/scripts/setup-ondemand.sh"
			exit 1
		}
		
		# Restart Apache
		sudo systemctl restart apache2
		
		echo "Waiting for Apache to restart..."
		sleep 5
		
		# Test if OnDemand is now accessible
		if curl -s -u ooduser:ooduser http://localhost/ 2>&1 | grep -q "Open OnDemand"; then
			echo "✅ OnDemand is now accessible!"
		else
			echo "⚠️ OnDemand still not responding. Checking Apache error log..."
			sudo tail -20 /var/log/apache2/error.log
		fi
	EOF
	
	@echo "$(BLUE)[INFO]$(NC) Diagnostics complete. Try accessing http://192.168.7.10/ again."
	@echo "$(YELLOW)[INFO]$(NC) Default credentials - Username: ooduser, Password: ooduser"

## 🖥️ QEMU Cluster Management

q-cluster: setup-repos ## 🚀 Build and start QEMU-based Slurm cluster
	@echo "$(BLUE)[INFO]$(NC) Building QEMU-based Slurm cluster..."
	@chmod +x ./qemu-cluster-build.sh
	@./qemu-cluster-build.sh build
	@echo "$(GREEN)[SUCCESS]$(NC) QEMU cluster is ready!"
	@echo "$(BOLD)Access the cluster:$(NC)"
	@echo "  Controller: ssh ubuntu@192.168.7.10"
	@echo "  Node1: ssh ubuntu@192.168.7.11"  
	@echo "  Node2: ssh ubuntu@192.168.7.12"
	@echo "  Password: ubuntu"

q-cluster-start: ## ▶️ Start existing QEMU cluster VMs
	@echo "$(BLUE)[INFO]$(NC) Starting QEMU cluster VMs..."
	@chmod +x ./qemu-cluster-build.sh
	@./qemu-cluster-build.sh start

q-cluster-stop: ## ⏹️ Stop running QEMU cluster VMs
	@echo "$(YELLOW)[INFO]$(NC) Stopping QEMU cluster VMs..."
	@chmod +x ./qemu-cluster-build.sh
	@./qemu-cluster-build.sh stop

q-cluster-clean: ## 🧹 Clean up QEMU cluster (remove VMs but keep base image)
	@echo "$(YELLOW)[INFO]$(NC) Cleaning up QEMU cluster..."
	@chmod +x ./qemu-cluster-build.sh
	@./qemu-cluster-build.sh clean
	@echo "$(GREEN)[SUCCESS]$(NC) QEMU cluster cleaned up."

q-cluster-clean-all: ## 🗑️ Clean up everything including base image
	@echo "$(YELLOW)[INFO]$(NC) Cleaning up QEMU cluster and base image..."
	@chmod +x ./qemu-cluster-build.sh
	@./qemu-cluster-build.sh clean-all
	@echo "$(GREEN)[SUCCESS]$(NC) All QEMU cluster files removed."

q-cluster-status: ## 📊 Check QEMU cluster status
	@echo "$(BLUE)[INFO]$(NC) QEMU Cluster Status:"
	@echo "$(BLUE)Virtual Switch:$(NC)"
	@sudo ovs-vsctl show 2>/dev/null || echo "  No virtual switch found"
	@echo ""
	@echo "$(BLUE)Running VMs:$(NC)"
	@ps aux | grep -E "qemu.*slurm-(controller|node)" | grep -v grep || echo "  No cluster VMs running"
	@echo ""
	@echo "$(BLUE)VM Images:$(NC)"
	@ls -lh qemu-vms/slurm-*.qcow2 2>/dev/null || echo "  No cluster images found"

q-cluster-connect: ## 🔌 SSH to QEMU cluster controller
	@echo "$(BLUE)[INFO]$(NC) Connecting to QEMU cluster controller..."
	@ssh -o StrictHostKeyChecking=no ubuntu@192.168.7.10

q-cluster-test: ## 🧪 Run test jobs on the QEMU cluster
	@echo "$(BLUE)[INFO]$(NC) Running test jobs on QEMU cluster..."
	@echo "$(BLUE)[INFO]$(NC) Checking controller VM connectivity..."
	@if ! ping -c 1 -W 2 192.168.7.10 > /dev/null 2>&1; then \
		echo "$(RED)[ERROR]$(NC) Cannot ping controller at 192.168.7.10. Is the cluster running?"; \
		echo "$(YELLOW)[TIP]$(NC) Start cluster with: make q-cluster"; \
		exit 1; \
	fi
	@echo "$(BLUE)[INFO]$(NC) Copying sample jobs to controller VM..."
	@sshpass -p "ubuntu" scp -o StrictHostKeyChecking=no -r ./sample-jobs/* ubuntu@192.168.7.10:~/sample-jobs/ || { \
		echo "$(RED)[ERROR]$(NC) Failed to copy sample jobs to controller VM"; \
		exit 1; \
	}
	@echo "$(BLUE)[INFO]$(NC) Verifying Apptainer SIF file was copied..."
	@sshpass -p "ubuntu" ssh -o StrictHostKeyChecking=no ubuntu@192.168.7.10 "ls -la ~/sample-jobs/ubuntu_python.sif" || { \
		echo "$(YELLOW)[WARNING]$(NC) Apptainer SIF file not found. Copying it specifically..."; \
		sshpass -p "ubuntu" scp -o StrictHostKeyChecking=no ./sample-jobs/ubuntu_python.sif ubuntu@192.168.7.10:~/sample-jobs/ || { \
			echo "$(RED)[ERROR]$(NC) Failed to copy Apptainer SIF file"; \
			echo "$(YELLOW)[TIP]$(NC) If the file is large, try creating it directly on the controller VM"; \
		}; \
	}
	@echo "$(BLUE)[INFO]$(NC) Submitting test jobs on controller VM..."
	@sshpass -p "ubuntu" ssh -o StrictHostKeyChecking=no ubuntu@192.168.7.10 "mkdir -p ~/sample-jobs-output"
	@sshpass -p "ubuntu" ssh -o StrictHostKeyChecking=no ubuntu@192.168.7.10 "cd ~/sample-jobs && chmod +x *.sh && echo 'Submitting jobs...' && for f in *.sh; do echo \"Submitting job: \$$f\"; sbatch \"\$$f\"; done"
	@echo "$(BLUE)[INFO]$(NC) Checking job status..."
	@sshpass -p "ubuntu" ssh -o StrictHostKeyChecking=no ubuntu@192.168.7.10 "squeue"
	@echo "$(BLUE)[INFO]$(NC) Waiting for jobs to complete (120 second timeout)..."
	@sshpass -p "ubuntu" ssh -o StrictHostKeyChecking=no ubuntu@192.168.7.10 "timeout 120s bash -c 'while squeue | grep -q ubuntu; do echo -n \".\"; sleep 2; done; echo \"\"'" || { \
		echo ""; \
		echo "$(YELLOW)[WARNING]$(NC) Not all jobs completed within the timeout period."; \
		echo "$(BLUE)[INFO]$(NC) Current job status:"; \
		sshpass -p "ubuntu" ssh -o StrictHostKeyChecking=no ubuntu@192.168.7.10 "squeue"; \
	}
	@echo "$(BLUE)[INFO]$(NC) Displaying job output files from ~/sample-jobs directory..."
	@sshpass -p "ubuntu" ssh -o StrictHostKeyChecking=no ubuntu@192.168.7.10 "cd ~/sample-jobs && ls -la *.out *.err 2>/dev/null || echo 'No output files found'"
	@sshpass -p "ubuntu" ssh -o StrictHostKeyChecking=no ubuntu@192.168.7.10 'cd ~/sample-jobs && for file in $$(ls *.out *.err 2>/dev/null); do \
		echo "------------------------------------------------------------"; \
		echo "FILE: $$file"; \
		echo "------------------------------------------------------------"; \
		cat "$$file"; \
		echo ""; \
	done || echo "$(YELLOW)[WARNING]$(NC) No output files found in ~/sample-jobs"'
	@echo "$(GREEN)[SUCCESS]$(NC) Sample jobs have been submitted to the QEMU cluster."
	@echo "$(BLUE)[INFO]$(NC) To check job status: ssh ubuntu@192.168.7.10 squeue"
	@echo "$(BLUE)[INFO]$(NC) To view job outputs: ssh ubuntu@192.168.7.10 \"cd ~/sample-jobs && cat *.out\""

q-cluster-refresh-samples: ## 🔄 Refresh sample jobs on QEMU cluster controller
	@echo "$(BLUE)[INFO]$(NC) Refreshing sample jobs on QEMU cluster controller..."
	@echo "$(BLUE)[INFO]$(NC) Checking controller VM connectivity..."
	@if ! ping -c 1 -W 2 192.168.7.10 > /dev/null 2>&1; then \
		echo "$(RED)[ERROR]$(NC) Cannot ping controller at 192.168.7.10. Is the cluster running?"; \
		echo "$(YELLOW)[TIP]$(NC) Start cluster with: make q-cluster"; \
		exit 1; \
	fi
	@echo "$(BLUE)[INFO]$(NC) Removing old sample jobs from controller VM..."
	@sshpass -p "ubuntu" ssh -o StrictHostKeyChecking=no ubuntu@192.168.7.10 "rm -rf ~/sample-jobs" || { \
		echo "$(RED)[ERROR]$(NC) Failed to remove old sample jobs from controller VM"; \
		exit 1; \
	}
	@echo "$(BLUE)[INFO]$(NC) Copying fresh sample jobs to controller VM..."
	@sshpass -p "ubuntu" scp -o StrictHostKeyChecking=no -r ./sample-jobs/* ubuntu@192.168.7.10:~/sample-jobs/ || { \
		echo "$(RED)[ERROR]$(NC) Failed to copy sample jobs to controller VM"; \
		exit 1; \
	}
	@echo "$(BLUE)[INFO]$(NC) Verifying Apptainer SIF file was copied..."
	@sshpass -p "ubuntu" ssh -o StrictHostKeyChecking=no ubuntu@192.168.7.10 "ls -la ~/sample-jobs/ubuntu_python.sif" || { \
		echo "$(YELLOW)[WARNING]$(NC) Apptainer SIF file not found. Copying it specifically..."; \
		sshpass -p "ubuntu" scp -o StrictHostKeyChecking=no ./sample-jobs/ubuntu_python.sif ubuntu@192.168.7.10:~/sample-jobs/ || { \
			echo "$(RED)[ERROR]$(NC) Failed to copy Apptainer SIF file"; \
			echo "$(YELLOW)[TIP]$(NC) If the file is large, try creating it directly on the controller VM"; \
		}; \
	}
	@echo "$(GREEN)[SUCCESS]$(NC) Sample jobs have been refreshed on the QEMU cluster controller."
	@echo "$(BLUE)[INFO]$(NC) Submit jobs with: ssh ubuntu@192.168.7.10 \"cd ~/sample-jobs && sbatch <job-script.sh>\""
