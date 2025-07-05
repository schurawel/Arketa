# Slurm HPC Cluster Makefile
# Automated cluster management and testing

.PHONY: help cluster cluster-full test status connect logs health stop start clean
.PHONY: test-hello test-parallel test-stress test-array
.PHONY: build-vagrant build-base remove-base list-boxes preflight

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

## 🎯 Main Targets

help: ## 📋 Show this help message
	@echo "$(BOLD)Slurm HPC Cluster - Available Commands$(NC)"
	@echo "======================================"
	@echo ""
	@echo "$(GREEN)🚀 Getting Started:$(NC)"
	@echo "  $(BOLD)make build-base$(NC)  - Create base box with Slurm pre-compiled (do this first)"
	@echo "  $(BOLD)make cluster$(NC)     - Complete cluster setup using base box"
	@echo "  $(BOLD)make cluster-full$(NC) - Complete cluster setup from scratch (slower)"
	@echo "  $(BOLD)make test$(NC)        - Run all sample jobs"
	@echo "  $(BOLD)make connect$(NC)     - SSH to controller node"
	@echo ""
	@echo "$(BLUE)📊 Cluster Management:$(NC)"
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  $(BOLD)%-15s$(NC) %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo ""
	@echo "$(YELLOW)💡 Recommended Workflow:$(NC)"
	@echo "  make build-base    # Build once (takes ~10-15 min)"
	@echo "  make cluster       # Deploy fast cluster (~2-3 min)"
	@echo "  make test          # Test the cluster"
	@echo ""
	@echo "$(YELLOW)🔄 Development Workflow:$(NC)"
	@echo "  make cluster-full  # Full build from scratch"
	@echo "  make clean         # Clean up completely"

cluster: preflight build-vagrant ## 🚀 Complete cluster setup using base box (recommended)
	@echo "$(GREEN)[INFO]$(NC) Starting cluster deployment..."
	@if $(VAGRANT_WRAPPER) box list | grep -q "slurm-base"; then \
		echo "$(BLUE)[INFO]$(NC) Using pre-built Slurm base box"; \
		SLURM_USE_BASE=true $(VAGRANT_WRAPPER) up controller node1 node2 node3; \
	else \
		echo "$(YELLOW)[WARNING]$(NC) Base box not found. Creating it first..."; \
		$(MAKE) build-base; \
		SLURM_USE_BASE=true $(VAGRANT_WRAPPER) up controller node1 node2 node3; \
	fi
	@echo "$(BLUE)[STEP]$(NC) Waiting for services to initialize..."
	@sleep 60
	@echo "$(BLUE)[STEP]$(NC) Performing health check..."
	@$(MAKE) health
	@echo "$(GREEN)[SUCCESS]$(NC) Cluster is ready!"
	@echo ""
	@echo "$(BOLD)Next steps:$(NC)"
	@echo "  make test       # Run sample jobs"
	@echo "  make connect    # Connect to cluster"
	@echo "  make status     # Check status"

cluster-full: preflight build-vagrant ## 🔨 Complete cluster setup from scratch (slower)
	@echo "$(GREEN)[INFO]$(NC) Starting complete cluster setup from scratch..."
	@echo "$(YELLOW)[WARNING]$(NC) This will build Slurm 4 times (~40-60 minutes)"
	@echo "$(BLUE)[STEP 1/4]$(NC) Starting controller node..."
	@$(VAGRANT_WRAPPER) up controller
	@echo "$(BLUE)[STEP 2/4]$(NC) Starting compute nodes..."
	@$(VAGRANT_WRAPPER) up node1 node2 node3
	@echo "$(BLUE)[STEP 3/4]$(NC) Waiting for services to initialize..."
	@sleep 60
	@echo "$(BLUE)[STEP 4/4]$(NC) Performing health check..."
	@$(MAKE) health
	@echo "$(GREEN)[SUCCESS]$(NC) Cluster is ready!"
	@echo ""
	@echo "$(BOLD)Next steps:$(NC)"
	@echo "  make test       # Run sample jobs"
	@echo "  make connect    # Connect to cluster"
	@echo "  make status     # Check status"

## 🧪 Testing Targets

test: ## 🧪 Run all sample jobs and show results
	@echo "$(GREEN)[INFO]$(NC) Running all sample jobs..."
	@$(MAKE) test-hello
	@sleep 5
	@$(MAKE) test-parallel  
	@sleep 5
	@$(MAKE) test-stress
	@sleep 5
	@$(MAKE) test-array
	@echo "$(GREEN)[SUCCESS]$(NC) All test jobs submitted!"
	@echo ""
	@echo "$(BOLD)Monitor jobs with:$(NC)"
	@echo "  make status"
	@echo "  make connect    # Then run: squeue, sacct"

test-hello: ## 👋 Run hello world job
	@echo "$(BLUE)[TEST]$(NC) Submitting hello world job..."
	@$(VAGRANT_WRAPPER) ssh controller -c "source /etc/profile.d/slurm.sh && sbatch /home/vagrant/sample-jobs/hello_world.sh"

test-parallel: ## ⚡ Run parallel job across multiple nodes
	@echo "$(BLUE)[TEST]$(NC) Submitting parallel job..."
	@$(VAGRANT_WRAPPER) ssh controller -c "source /etc/profile.d/slurm.sh && sbatch /home/vagrant/sample-jobs/parallel_hello.sh"

test-stress: ## 💪 Run CPU stress test
	@echo "$(BLUE)[TEST]$(NC) Submitting CPU stress test..."
	@$(VAGRANT_WRAPPER) ssh controller -c "source /etc/profile.d/slurm.sh && sbatch /home/vagrant/sample-jobs/cpu_stress.sh"

test-array: ## 📊 Run job array with multiple tasks
	@echo "$(BLUE)[TEST]$(NC) Submitting job array..."
	@$(VAGRANT_WRAPPER) ssh controller -c "source /etc/profile.d/slurm.sh && sbatch /home/vagrant/sample-jobs/array_job.sh"

## 📊 Monitoring Targets

status: ## 📊 Show comprehensive cluster and job status
	@echo "$(BOLD)=== Cluster Status ===$(NC)"
	@echo ""
	@echo "$(BLUE)[VM STATUS]$(NC)"
	@$(VAGRANT_WRAPPER) status || echo "$(RED)Error getting VM status$(NC)"
	@echo ""
	@echo "$(BLUE)[SLURM STATUS]$(NC)"
	@$(VAGRANT_WRAPPER) ssh controller -c "source /etc/profile.d/slurm.sh && echo 'Cluster Info:' && sinfo && echo '' && echo 'Node Details:' && scontrol show nodes | grep -E '(NodeName|State|CPUAlloc)'" 2>/dev/null || echo "$(YELLOW)Slurm not ready yet$(NC)"
	@echo ""
	@echo "$(BLUE)[JOB QUEUE]$(NC)"
	@$(VAGRANT_WRAPPER) ssh controller -c "source /etc/profile.d/slurm.sh && squeue" 2>/dev/null || echo "$(YELLOW)No jobs in queue$(NC)"
	@echo ""
	@echo "$(BLUE)[RECENT JOBS]$(NC)"
	@$(VAGRANT_WRAPPER) ssh controller -c "source /etc/profile.d/slurm.sh && sacct --format=JobID,JobName,State,ExitCode,Start,End -n | tail -10" 2>/dev/null || echo "$(YELLOW)No job history$(NC)"

connect: ## 🔗 SSH to controller node
	@echo "$(GREEN)[INFO]$(NC) Connecting to controller node..."
	@echo "$(YELLOW)Tip:$(NC) Once connected, run:"
	@echo "  source /etc/profile.d/slurm.sh"
	@echo "  sinfo              # Check cluster"
	@echo "  squeue             # Monitor jobs"
	@echo "  exit               # Return to host"
	@echo ""
	@$(VAGRANT_WRAPPER) ssh controller

logs: ## 📋 Display Slurm service logs
	@echo "$(BLUE)[LOGS]$(NC) Slurm Controller Logs:"
	@$(VAGRANT_WRAPPER) ssh controller -c "sudo tail -20 /var/log/slurm/slurmctld.log" 2>/dev/null || echo "$(RED)Cannot access slurmctld logs$(NC)"
	@echo ""
	@echo "$(BLUE)[LOGS]$(NC) Slurm Database Logs:"
	@$(VAGRANT_WRAPPER) ssh controller -c "sudo tail -20 /var/log/slurm/slurmdbd.log" 2>/dev/null || echo "$(RED)Cannot access slurmdbd logs$(NC)"

health: ## 🏥 Perform comprehensive health check
	@echo "$(GREEN)[INFO]$(NC) Performing cluster health check..."
	@$(CLUSTER_MANAGER) health || echo "$(YELLOW)Some health checks failed - cluster may still be starting$(NC)"

## 🔧 Management Targets

stop: ## ⏹️ Stop all VMs (preserves state for restart)
	@echo "$(YELLOW)[INFO]$(NC) Stopping cluster VMs..."
	@$(VAGRANT_WRAPPER) halt
	@echo "$(GREEN)[SUCCESS]$(NC) Cluster stopped. Use 'make start' to resume."

start: ## ▶️ Start stopped VMs
	@echo "$(GREEN)[INFO]$(NC) Starting cluster VMs..."
	@$(VAGRANT_WRAPPER) up
	@echo "$(GREEN)[SUCCESS]$(NC) Cluster started."

clean: ## 🧹 Stop and completely remove all VMs
	@echo "$(RED)[WARNING]$(NC) This will destroy all VMs and data!"
	@bash -c 'read -p "Are you sure? [y/N] " -n 1 -r; \
	echo ""; \
	if [[ $$REPLY =~ ^[Yy]$$ ]]; then \
		echo "$(YELLOW)[INFO]$(NC) Destroying cluster..."; \
		$(VAGRANT_WRAPPER) destroy -f; \
		rm -rf .vagrant; \
		echo "$(GREEN)[SUCCESS]$(NC) Cluster destroyed."; \
	else \
		echo "$(BLUE)[INFO]$(NC) Cancelled."; \
	fi'

## 🔨 Build Targets

preflight: ## ✈️ Run pre-flight checks
	@echo "$(BLUE)[CHECK]$(NC) Running pre-flight checks..."
	@if [ -f "$(PREFLIGHT_CHECK)" ]; then \
		chmod +x $(PREFLIGHT_CHECK) && $(PREFLIGHT_CHECK); \
	else \
		echo "$(YELLOW)[SKIP]$(NC) Pre-flight check not found"; \
	fi

build-base: preflight build-vagrant ## 🏗️ Create base Slurm box (build once, use many times)
	@echo "$(GREEN)[INFO]$(NC) Creating reusable Slurm base box..."
	@if ! $(VAGRANT_WRAPPER) box list | grep -q "slurm-base"; then \
		echo "$(YELLOW)[STEP 1/4]$(NC) Building base VM with Slurm (~10-15 minutes)..."; \
		$(VAGRANT_WRAPPER) up base; \
		echo "$(YELLOW)[STEP 2/4]$(NC) Packaging base box..."; \
		$(VAGRANT_WRAPPER) package base --output slurm-base.box; \
		echo "$(YELLOW)[STEP 3/4]$(NC) Adding to Vagrant..."; \
		$(VAGRANT_WRAPPER) box add slurm-base slurm-base.box; \
		echo "$(YELLOW)[STEP 4/4]$(NC) Cleaning up..."; \
		$(VAGRANT_WRAPPER) destroy base -f; \
		rm -f slurm-base.box; \
		echo "$(GREEN)[SUCCESS]$(NC) Base box 'slurm-base' created!"; \
		echo "$(BLUE)[INFO]$(NC) You can now use 'make cluster' for fast deployments"; \
	else \
		echo "$(GREEN)[INFO]$(NC) Base box 'slurm-base' already exists"; \
		echo "$(BLUE)[TIP]$(NC) Use 'make remove-base' to rebuild it"; \
	fi

remove-base: ## 🗑️ Remove base box (force rebuild)
	@echo "$(YELLOW)[INFO]$(NC) Removing Slurm base box..."
	@$(VAGRANT_WRAPPER) box remove slurm-base -f || echo "Base box not found"
	@echo "$(GREEN)[SUCCESS]$(NC) Base box removed. Use 'make build-base' to recreate."

list-boxes: ## 📦 List available Vagrant boxes
	@echo "$(BOLD)Available Vagrant Boxes:$(NC)"
	@$(VAGRANT_WRAPPER) box list

build-vagrant: ## 🔨 Build Vagrant from source if needed
	@echo "$(BLUE)[BUILD]$(NC) Ensuring Vagrant is available..."
	@if [ ! -f "$(VAGRANT_WRAPPER)" ]; then \
		echo "$(YELLOW)[INFO]$(NC) Vagrant wrapper not found, setting up..."; \
		echo "Please ensure Vagrant source is available in vagrant-src/"; \
	else \
		chmod +x $(VAGRANT_WRAPPER); \
		echo "$(GREEN)[OK]$(NC) Vagrant wrapper ready"; \
	fi

## 🐛 Debug Targets

debug: ## 🐛 Show debug information
	@echo "$(BOLD)=== Debug Information ===$(NC)"
	@echo ""
	@echo "$(BLUE)[SYSTEM]$(NC)"
	@echo "OS: $$(uname -a)"
	@echo "VirtualBox: $$(VBoxManage --version 2>/dev/null || echo 'Not found')"
	@echo "Ruby: $$(ruby --version 2>/dev/null || echo 'Not found')"
	@echo ""
	@echo "$(BLUE)[PROJECT]$(NC)"
	@echo "Directory: $$(pwd)"
	@echo "Vagrant wrapper: $$(test -f $(VAGRANT_WRAPPER) && echo 'Found' || echo 'Missing')"
	@echo "Cluster manager: $$(test -f $(CLUSTER_MANAGER) && echo 'Found' || echo 'Missing')"
	@echo ""
	@echo "$(BLUE)[CLUSTER]$(NC)"
	@$(VAGRANT_WRAPPER) status 2>/dev/null || echo "No VMs found"

inspect: ## 🔍 Inspect cluster configuration
	@echo "$(BOLD)=== Cluster Configuration ===$(NC)"
	@echo ""
	@echo "$(BLUE)[VAGRANTFILE]$(NC)"
	@grep -E "(vm\.box|memory|cpus|ip)" Vagrantfile || echo "Vagrantfile not found"
	@echo ""
	@echo "$(BLUE)[SAMPLE JOBS]$(NC)"
	@ls -la sample-jobs/ 2>/dev/null || echo "Sample jobs not found"
	@echo ""
	@echo "$(BLUE)[SCRIPTS]$(NC)"
	@ls -la scripts/ 2>/dev/null || echo "Scripts not found"

## 📋 Information Targets

info: ## ℹ️ Show cluster information
	@echo "$(BOLD)Slurm HPC Cluster Information$(NC)"
	@echo "=============================="
	@echo ""
	@echo "$(GREEN)Architecture:$(NC)"
	@echo "  • 1 Controller node (2 CPU, 2GB RAM) - Slurm controller + database"
	@echo "  • 3 Compute nodes (2 CPU, 1GB RAM each) - Slurm compute daemons"
	@echo "  • Private network: 192.168.60.0/24"
	@echo "  • Shared NFS storage across all nodes"
	@echo ""
	@echo "$(GREEN)Sample Jobs:$(NC)"
	@echo "  • hello_world.sh   - Basic system info job"
	@echo "  • parallel_hello.sh - Multi-node parallel job"
	@echo "  • cpu_stress.sh    - CPU-intensive workload"
	@echo "  • array_job.sh     - Job array example"
	@echo ""
	@echo "$(GREEN)Quick Commands:$(NC)"
	@echo "  make cluster       # Complete setup"
	@echo "  make test          # Run all sample jobs" 
	@echo "  make status        # Check cluster status"
	@echo "  make connect       # SSH to controller"

version: ## 📈 Show version information
	@echo "$(BOLD)Version Information$(NC)"
	@echo "==================="
	@echo "Project: Slurm HPC Cluster with Vagrant"
	@echo "Built: $$(date)"
	@echo "Vagrant: $$($(VAGRANT_WRAPPER) --version 2>/dev/null || echo 'Not available')"
	@echo "VirtualBox: $$(VBoxManage --version 2>/dev/null || echo 'Not available')"
	@echo "Ruby: $$(ruby --version 2>/dev/null || echo 'Not available')"

# Error handling for missing files
$(VAGRANT_WRAPPER):
	@echo "$(RED)[ERROR]$(NC) Vagrant wrapper not found!"
	@echo "Please ensure vagrant-wrapper.sh exists and is executable."
	@exit 1

$(CLUSTER_MANAGER):
	@echo "$(RED)[ERROR]$(NC) Cluster manager not found!"
	@echo "Please ensure cluster-manager.sh exists and is executable."
	@exit 1
