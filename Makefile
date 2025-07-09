# Slurm HPC Cluster Makefile
# Automated cluster management and testing

.PHONY: help cluster cluster-full test status connect logs health stop start clean clean-vms force-clean setup-libvirt
.PHONY: test-hello test-parallel test-stress test-array show-outputs wait-for-jobs test-and-wait
.PHONY: test-python test-apptainer test-ml test-distributed test-extended test-mpi
.PHONY: show-job-output show-all-outputs show-latest-outputs
.PHONY: ondemand slurm-web
.PHONY: build-vagrant build-base remove-base list-boxes preflight setup-repos
.PHONY: metal sim-metal sim-metal-status sim-metal-stop sim-metal-clean sim-metal-connect metal-clean

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
	@echo "  $(BOLD)make setup-repos$(NC) - Clone required repositories (auto-run by other targets)"
	@echo "  $(BOLD)make build-base$(NC)  - Create base box with Slurm pre-compiled (do this first)"
	@echo "  $(BOLD)make cluster$(NC)     - Complete cluster setup using base box"
	@echo "  $(BOLD)make cluster-full$(NC) - Complete cluster setup from scratch (slower)"
	@echo "  $(BOLD)make test$(NC)        - Run all sample jobs"
	@echo "  $(BOLD)make test-and-wait$(NC) - Run tests and wait for completion with results"
	@echo "  $(BOLD)make connect$(NC)     - SSH to controller node"
	@echo ""
	@echo "$(YELLOW)🏗️ Bare Metal Deployment (Independent):$(NC)"
	@echo "  $(BOLD)make metal$(NC)       - Create custom Ubuntu ISO for bare metal deployment"
	@echo "  $(BOLD)make sim-metal$(NC)   - Simulate bare metal installation with QEMU"
	@echo "  $(BOLD)make metal-clean$(NC) - Clean up ISO workspace and generated files"
	@echo ""
	@echo "$(BLUE)📊 Cluster Management:$(NC)"
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  $(BOLD)%-15s$(NC) %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo ""
	@echo "$(YELLOW)💡 Vagrant Workflow:$(NC)"
	@echo "  make setup-repos      # Clone repositories (auto-run by other targets)"
	@echo "  make build-base       # Build once (takes ~10-15 min)"
	@echo "  make cluster          # Deploy fast cluster (~2-3 min)"
	@echo "  make test-and-wait    # Test with full monitoring"
	@echo ""
	@echo "$(YELLOW)🔄 Development Workflow:$(NC)"
	@echo "  make cluster-full     # Full build from scratch"
	@echo "  make clean-vms        # Clean VMs but keep base box (fast cleanup)"
	@echo ""
	@echo "$(YELLOW)🏗️ Bare Metal Workflow:$(NC)"
	@echo "  make metal            # Create custom Ubuntu ISO (independent)"
	@echo "  make sim-metal        # Test with QEMU simulation"
	@echo "  make sim-metal-status # Check simulation status"
	@echo "  make metal-clean      # Clean up ISO workspace"
	@echo "  make clean            # Clean up completely"

cluster: setup-repos preflight build-base ## 🚀 Complete cluster setup using base box (recommended)
	@echo "$(GREEN)[INFO]$(NC) Starting cluster deployment..."
	@echo "$(BLUE)[INFO]$(NC) Base box check complete. Proceeding with cluster setup..."
	@echo "$(BLUE)[STEP 1/3]$(NC) Starting controller node..."
	SLURM_USE_BASE=true $(VAGRANT_WRAPPER) up controller
	@echo "$(BLUE)[STEP 2/3]$(NC) Starting compute node 1..."
	SLURM_USE_BASE=true $(VAGRANT_WRAPPER) up node1
	@echo "$(BLUE)[STEP 3/3]$(NC) Starting compute node 2..."
	SLURM_USE_BASE=true $(VAGRANT_WRAPPER) up node2
	@echo "$(BLUE)[STEP]$(NC) Waiting for services to initialize..."
	@sleep 60
	@echo "$(BLUE)[STEP]$(NC) Performing health check..."
	@$(MAKE) health
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
	@if $(VAGRANT_WRAPPER) box list | grep -q "slurm-base"; then \
		echo "$(GREEN)[INFO]$(NC) Reusable Slurm base box already exists. Skipping build."; \
	else \
		echo "$(YELLOW)[INFO]$(NC) Creating reusable Slurm base box... (This may take 10-15 minutes)"; \
		$(MAKE) remove-base; \
		SLURM_BUILD_BASE=true $(VAGRANT_WRAPPER) up base; \
		$(VAGRANT_WRAPPER) halt base; \
		$(VAGRANT_WRAPPER) package base --output slurm-base.box; \
		$(VAGRANT_WRAPPER) box add --force --name slurm-base slurm-base.box; \
		$(VAGRANT_WRAPPER) destroy -f base; \
		rm -f slurm-base.box; \
		echo "$(GREEN)[SUCCESS]$(NC) Slurm base box created successfully."; \
	fi

remove-base: ## 🗑️ Remove the Slurm base box
	@echo "$(YELLOW)[INFO]$(NC) Removing existing Slurm base box..."
	@if $(VAGRANT_WRAPPER) box list | grep -q "slurm-base"; then \
		$(VAGRANT_WRAPPER) box remove -f slurm-base; \
		echo "$(GREEN)[SUCCESS]$(NC) Removed slurm-base box."; \
	else \
		echo "$(BLUE)[INFO]$(NC) No slurm-base box found to remove."; \
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

clean-vms: ## 🧹 Destroy cluster VMs but keep base box
	@echo "$(YELLOW)[INFO]$(NC) Destroying cluster VMs (controller, node1, node2)..."
	@$(VAGRANT_WRAPPER) destroy -f controller node1 node2
	@echo "$(GREEN)[SUCCESS]$(NC) Cluster VMs destroyed."

clean: ## 🗑️ Destroy all VMs and remove the base box
	@echo "$(RED)[DANGER]$(NC) This will destroy all VMs and the base box."
	@read -p "Are you sure? [y/N] " -n 1 -r; \
	echo; \
	if [[ $$REPLY =~ ^[Yy]$$ ]]; then \
		echo "Destroying all VMs..."; \
		$(VAGRANT_WRAPPER) destroy -f; \
		$(MAKE) remove-base; \
		echo "Cleaning up repositories..."; \
		rm -rf tmp; \
		echo "$(GREEN)[SUCCESS]$(NC) Full cleanup complete."; \
	else \
		echo "Cleanup cancelled."; \
	fi

force-clean: ## 💥 Force destroy all VMs and data without confirmation
	@echo "$(RED)[DANGER]$(NC) Forcibly destroying all VMs, base box, and repositories..."
	@$(VAGRANT_WRAPPER) destroy -f
	@$(MAKE) remove-base
	@rm -rf tmp
	@echo "$(GREEN)[SUCCESS]$(NC) Forced cleanup complete."

## 🌐 Web Interfaces

ondemand: ## 🌐 Start Open OnDemand service
	@echo "$(BLUE)[INFO]$(NC) Ensuring Open OnDemand is set up..."
	@$(VAGRANT_WRAPPER) ssh controller -c "/home/vagrant/scripts/setup-ondemand.sh"
	@echo "$(GREEN)[SUCCESS]$(NC) Open OnDemand is running. Access at http://localhost:8080"

slurm-web: ## 🌐 Start slurm-web service
	@echo "$(BLUE)[INFO]$(NC) Ensuring slurm-web is set up..."
	@$(VAGRANT_WRAPPER) ssh controller -c "/home/vagrant/scripts/setup-slurm-web.sh"
	@echo "$(GREEN)[SUCCESS]$(NC) slurm-web is running. Access at http://localhost:8081"

## 📜 Job Testing Targets

# Helper for waiting
define wait_for_jobs
    @echo "$(BLUE)[INFO]$(NC) Waiting for all jobs to complete..."
    @timeout 300s $(VAGRANT_WRAPPER) ssh controller -- "while squeue | grep -q 'vagrant'; do echo -n '.'; sleep 5; done; echo"
    @echo "$(GREEN)[SUCCESS]$(NC) All jobs completed."
endef

test-and-wait: test ## 🧪 Run all tests and wait for completion
	@$(call wait_for_jobs)
	@$(MAKE) show-all-outputs

test-hello: ## 👋 Submit a simple 'hello world' job
	@echo "$(BLUE)[TEST]$(NC) Submitting Hello World job..."
	@$(VAGRANT_WRAPPER) ssh controller -c "sbatch /home/vagrant/sample-jobs/hello_world.sh"

test-parallel: ## 👯 Submit a simple parallel (MPI) job
	@echo "$(BLUE)[TEST]$(NC) Submitting Parallel Hello (MPI) job..."
	@$(VAGRANT_WRAPPER) ssh controller -c "sbatch /home/vagrant/sample-jobs/parallel_hello.sh"

test-stress: ## 💪 Submit a CPU stress test job
	@echo "$(BLUE)[TEST]$(NC) Submitting CPU Stress Test job..."
	@$(VAGRANT_WRAPPER) ssh controller -c "sbatch /home/vagrant/sample-jobs/cpu_stress.sh"

test-array: ## 🔢 Submit a job array
	@echo "$(BLUE)[TEST]$(NC) Submitting Job Array..."
	@$(VAGRANT_WRAPPER) ssh controller -c "sbatch /home/vagrant/sample-jobs/array_job.sh"

test-python: ## 🐍 Submit a Python simulation job
	@echo "$(BLUE)[TEST]$(NC) Submitting Python Simulation job..."
	@$(VAGRANT_WRAPPER) ssh controller -c "sbatch /home/vagrant/sample-jobs/python_simulation.sh"

test-apptainer: ## 📦 Submit an Apptainer/Singularity job
	@echo "$(BLUE)[TEST]$(NC) Submitting Apptainer job..."
	@$(VAGRANT_WRAPPER) ssh controller -c "sbatch /home/vagrant/sample-jobs/apptainer_job.sh"

test-ml: ## 🧠 Submit a mock ML training job
	@echo "$(BLUE)[TEST]$(NC) Submitting ML Simulation job..."
	@$(VAGRANT_WRAPPER) ssh controller -c "sbatch /home/vagrant/sample-jobs/ml_simulation.sh"

test-distributed: ## 🌐 Submit a distributed simulation job
	@echo "$(BLUE)[TEST]$(NC) Submitting Distributed Simulation job..."
	@$(VAGRANT_WRAPPER) ssh controller -c "sbatch /home/vagrant/sample-jobs/distributed_simulation.sh"

test-mpi: ## 🚀 Submit a basic MPI job
	@echo "$(BLUE)[TEST]$(NC) Submitting basic MPI job..."
	@$(VAGRANT_WRAPPER) ssh controller -c "sbatch /home/vagrant/sample-jobs/mpi_job.sh"

test-extended: test-python test-apptainer test-ml test-distributed test-mpi ## 🧪 Run extended tests
	@echo "$(GREEN)[SUCCESS]$(NC) All extended tests submitted."

## 📄 Job Output Management

show-outputs: ## 📄 Show output of a specific job (e.g., make show-outputs job_id=1)
	@echo "$(BLUE)[INFO]$(NC) Showing output for job $(job_id)..."
	@$(VAGRANT_WRAPPER) ssh controller -c "cat slurm-$(job_id).out"

show-job-output: ## 📄 Show output for a specific job script (e.g., make show-job-output script=hello_world.sh)
	@job_id=`$(VAGRANT_WRAPPER) ssh controller -c "squeue -o '%A %j' | grep '$(script)' | cut -d' ' -f1"`; \
	if [ -n "$$job_id" ]; then \
		echo "Showing output for job $$job_id (slurm-$$job_id.out)"; \
		$(VAGRANT_WRAPPER) ssh controller -c "cat slurm-$$job_id.out"; \
	else \
		echo "Could not find job for script $(script)"; \
	fi

show-all-outputs: ## 📄 Show outputs of all completed jobs
	@echo "$(BLUE)[INFO]$(NC) Showing outputs of all completed jobs in ~/ ..."
	@$(VAGRANT_WRAPPER) ssh controller -c "cat ~/slurm-*.out"

show-latest-outputs: ## 📄 Show the most recent job output
	@echo "$(BLUE)[INFO]$(NC) Showing the most recent job output..."
	@$(VAGRANT_WRAPPER) ssh controller -c "ls -t ~/slurm-*.out | head -n 1 | xargs cat"

## 🛠️ Setup & Preflight

setup-repos: ## 📥 Clone required source repositories
	@echo "$(BLUE)[INFO]$(NC) Setting up required source repositories..."
	@if [ -d "tmp/slurm" ] && [ -d "tmp/ondemand" ] && [ -d "tmp/slurm-web" ]; then \
		echo "$(GREEN)[OK]$(NC) Repositories already exist. Skipping clone."; \
	else \
		./setup-repos.sh; \
	fi

preflight: ## ✅ Run preflight checks for dependencies
	@echo "$(BLUE)[INFO]$(NC) Running preflight checks..."
	@$(PREFLIGHT_CHECK)

setup-libvirt: ## 🔧 Install libvirt and required tools
	@echo "$(BLUE)[INFO]$(NC) Installing libvirt, Vagrant, and required plugins..."
	@if ! command -v vagrant &> /dev/null; then \
		echo "Vagrant not found. Please install it first."; \
		exit 1; \
	fi
	@sudo apt-get update
	@sudo apt-get install -y libvirt-daemon-system libvirt-clients qemu-kvm ebtables dnsmasq-base
	@vagrant plugin install vagrant-libvirt
	@echo "$(GREEN)[SUCCESS]$(NC) Libvirt setup is complete."

build-vagrant: ## 🏗️ Build the vagrant-wrapper utility
	@if [ -x "$(VAGRANT_WRAPPER)" ]; then \
		echo "$(BLUE)[INFO]$(NC) vagrant-wrapper.sh is executable. Skipping build."; \
	else \
		echo "$(RED)[ERROR]$(NC) $(VAGRANT_WRAPPER) not found or not executable."; \
		exit 1; \
	fi

## ⚙️ Bare Metal Deployment (Advanced)

metal: ## 💿 Create custom Ubuntu ISO for bare metal deployment
	@echo "$(BLUE)[INFO]$(NC) Creating custom Ubuntu ISO for HPC deployment..."
	@./scripts/create-metal-iso.sh

sim-metal: ## 🖥️ Simulate bare metal installation with QEMU
	@echo "$(BLUE)[INFO]$(NC) Starting bare metal simulation with QEMU..."
	@./scripts/simulate-metal.sh start

sim-metal-status: ## 📊 Check status of the QEMU simulation
	@./scripts/simulate-metal.sh status

sim-metal-stop: ## 🛑 Stop the QEMU simulation
	@./scripts/simulate-metal.sh stop

sim-metal-clean: ## 🧹 Clean up QEMU simulation files
	@./scripts/simulate-metal.sh clean

sim-metal-connect: ## 🔌 Connect to the simulated controller via VNC
	@./qemu-workspace/connect-vnc.sh

metal-clean: ## 🧹 Clean up ISO workspace and generated files
	@echo "$(YELLOW)[INFO]$(NC) Cleaning up ISO workspace..."
	@rm -rf iso-workspace/ubuntu-22.04-hpc-cluster.iso iso-workspace/iso-rebuild
	@echo "$(GREEN)[SUCCESS]$(NC) ISO workspace cleaned."
