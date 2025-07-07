# Slurm HPC Cluster Makefile
# Automated cluster management and testing

.PHONY: help cluster cluster-full test status connect logs health stop start clean clean-vms force-clean
.PHONY: test-hello test-parallel test-stress test-array show-outputs wait-for-jobs test-and-wait
.PHONY: test-python test-apptainer test-ml test-distributed test-extended
.PHONY: show-job-output show-all-outputs show-latest-outputs
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

cluster: setup-repos preflight build-vagrant ## 🚀 Complete cluster setup using base box (recommended)
	@echo "$(GREEN)[INFO]$(NC) Starting cluster deployment..."
	@echo "$(BLUE)[STEP]$(NC) Ensuring repositories are available..."
	@if [ ! -d "tmp/vagrant-src" ] || [ ! -d "tmp/slurm" ]; then \
		echo "$(YELLOW)[WARNING]$(NC) Required repositories not found. Setting them up..."; \
		$(MAKE) setup-repos; \
	else \
		echo "$(GREEN)[OK]$(NC) Repositories are available"; \
	fi
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

cluster-full: setup-repos preflight build-vagrant ## 🔨 Complete cluster setup from scratch (slower)
	@echo "$(GREEN)[INFO]$(NC) Starting complete cluster setup from scratch..."
	@echo "$(YELLOW)[WARNING]$(NC) This will build Slurm 4 times (~40-60 minutes)"
	@echo "$(BLUE)[STEP]$(NC) Ensuring repositories are available..."
	@if [ ! -d "tmp/vagrant-src" ] || [ ! -d "tmp/slurm" ]; then \
		echo "$(YELLOW)[WARNING]$(NC) Required repositories not found. Setting them up..."; \
		$(MAKE) setup-repos; \
	else \
		echo "$(GREEN)[OK]$(NC) Repositories are available"; \
	fi
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
	@echo "$(GREEN)[INFO]$(NC) Running all sample jobs with output monitoring..."
	@echo "$(BLUE)[STEP 1/4]$(NC) Running hello world job..."
	@$(MAKE) test-hello
	@echo "$(BLUE)[STEP 2/4]$(NC) Running parallel job..."
	@$(MAKE) test-parallel  
	@echo "$(BLUE)[STEP 3/4]$(NC) Running stress test..."
	@$(MAKE) test-stress
	@echo "$(BLUE)[STEP 4/4]$(NC) Running array job..."
	@$(MAKE) test-array
	@echo ""
	@echo "$(GREEN)[INFO]$(NC) All basic jobs submitted! Waiting for completion..."
	@sleep 10
	@echo "$(BLUE)[MONITORING]$(NC) Job status:"
	@$(VAGRANT_WRAPPER) ssh controller -c "source /etc/profile.d/slurm.sh && squeue" || echo "$(YELLOW)No active jobs$(NC)"
	@echo ""
	@echo "$(BLUE)[RESULTS]$(NC) Recent job history:"
	@$(VAGRANT_WRAPPER) ssh controller -c "source /etc/profile.d/slurm.sh && sacct --format=JobID,JobName%15,State,ExitCode,Start,End,NodeList -n | tail -20" || echo "$(YELLOW)No job history$(NC)"
	@echo ""
	@echo "$(GREEN)[SUCCESS]$(NC) Basic test completed!"
	@echo ""
	@echo "$(BOLD)View job outputs:$(NC)"
	@echo "  make show-outputs             # Show latest outputs from recent test"
	@echo "  make show-latest-outputs      # Show most recent outputs with smart detection"
	@echo "  make show-all-outputs         # Show all job outputs from all nodes"
	@echo "  make show-job-output JOB_ID=17  # Show specific job output"
	@echo "  make status                   # Check current cluster status"
	@echo "  make connect                  # SSH to controller for manual inspection"
	@echo ""
	@echo "$(BOLD)Advanced Tests:$(NC)"
	@echo "  make test-extended            # Run Python, ML, containers, distributed"
	@echo "  make test-python              # Scientific Python simulation"
	@echo "  make test-apptainer           # Container-based jobs"
	@echo "  make test-ml                  # Machine learning workflows"
	@echo "  make test-distributed         # Multi-node distributed computing"

test-hello: ## 👋 Run hello world job
	@echo "$(BLUE)[TEST]$(NC) Submitting hello world job..."
	@job_id=$$($(VAGRANT_WRAPPER) ssh controller -c "source /etc/profile.d/slurm.sh && sbatch /home/vagrant/sample-jobs/hello_world.sh" | grep -o '[0-9]*'); \
	echo "$(GREEN)[SUBMITTED]$(NC) Hello world job ID: $$job_id"; \
	echo "$(YELLOW)[MONITOR]$(NC) Track with: squeue, or check output: ~/hello_world_$$job_id.out"

test-parallel: ## ⚡ Run parallel job across multiple nodes
	@echo "$(BLUE)[TEST]$(NC) Submitting parallel job..."
	@job_id=$$($(VAGRANT_WRAPPER) ssh controller -c "source /etc/profile.d/slurm.sh && sbatch /home/vagrant/sample-jobs/parallel_hello.sh" | grep -o '[0-9]*'); \
	echo "$(GREEN)[SUBMITTED]$(NC) Parallel job ID: $$job_id"; \
	echo "$(YELLOW)[MONITOR]$(NC) Track with: squeue, or check output: ~/parallel_hello_$$job_id.out"

test-stress: ## 💪 Run CPU stress test
	@echo "$(BLUE)[TEST]$(NC) Submitting CPU stress test..."
	@job_id=$$($(VAGRANT_WRAPPER) ssh controller -c "source /etc/profile.d/slurm.sh && sbatch /home/vagrant/sample-jobs/cpu_stress.sh" | grep -o '[0-9]*'); \
	echo "$(GREEN)[SUBMITTED]$(NC) CPU stress test job ID: $$job_id"; \
	echo "$(YELLOW)[MONITOR]$(NC) Track with: squeue, or check output: ~/cpu_stress_$$job_id.out"

test-array: ## 📊 Run job array with multiple tasks
	@echo "$(BLUE)[TEST]$(NC) Submitting job array..."
	@job_id=$$($(VAGRANT_WRAPPER) ssh controller -c "source /etc/profile.d/slurm.sh && sbatch /home/vagrant/sample-jobs/array_job.sh" | grep -o '[0-9]*'); \
	echo "$(GREEN)[SUBMITTED]$(NC) Job array ID: $$job_id"; \
	echo "$(YELLOW)[MONITOR]$(NC) Track with: squeue, or check output: ~/array_job_$$job_id*.out"

test-python: ## 🐍 Run Python scientific simulation
	@echo "$(BLUE)[TEST]$(NC) Submitting Python simulation..."
	@job_id=$$($(VAGRANT_WRAPPER) ssh controller -c "source /etc/profile.d/slurm.sh && sbatch /home/vagrant/sample-jobs/python_simulation.sh" | grep -o '[0-9]*'); \
	echo "$(GREEN)[SUBMITTED]$(NC) Python simulation job ID: $$job_id"; \
	echo "$(YELLOW)[MONITOR]$(NC) Track with: squeue, or check output: ~/python_simulation_$$job_id.out"

test-apptainer: ## 📦 Run Apptainer container job
	@echo "$(BLUE)[TEST]$(NC) Submitting Apptainer container job..."
	@job_id=$$($(VAGRANT_WRAPPER) ssh controller -c "source /etc/profile.d/slurm.sh && sbatch /home/vagrant/sample-jobs/apptainer_job.sh" | grep -o '[0-9]*'); \
	echo "$(GREEN)[SUBMITTED]$(NC) Apptainer job ID: $$job_id"; \
	echo "$(YELLOW)[MONITOR]$(NC) Track with: squeue, or check output: ~/apptainer_test_$$job_id.out"

test-ml: ## 🤖 Run machine learning simulation
	@echo "$(BLUE)[TEST]$(NC) Submitting ML simulation..."
	@job_id=$$($(VAGRANT_WRAPPER) ssh controller -c "source /etc/profile.d/slurm.sh && sbatch /home/vagrant/sample-jobs/ml_simulation.sh" | grep -o '[0-9]*'); \
	echo "$(GREEN)[SUBMITTED]$(NC) ML simulation job ID: $$job_id"; \
	echo "$(YELLOW)[MONITOR]$(NC) Track with: squeue, or check output: ~/ml_simulation_$$job_id.out"

test-distributed: ## 🌐 Run distributed multi-node simulation
	@echo "$(BLUE)[TEST]$(NC) Submitting distributed simulation..."
	@job_id=$$($(VAGRANT_WRAPPER) ssh controller -c "source /etc/profile.d/slurm.sh && sbatch /home/vagrant/sample-jobs/distributed_simulation.sh" | grep -o '[0-9]*'); \
	echo "$(GREEN)[SUBMITTED]$(NC) Distributed simulation job ID: $$job_id"; \
	echo "$(YELLOW)[MONITOR]$(NC) Track with: squeue, or check output: ~/multi_container_$$job_id.out"

test-extended: ## 🔬 Run all extended tests (Python, containers, ML, distributed)
	@echo "$(GREEN)[INFO]$(NC) Running extended test suite..."
	@echo "$(BLUE)[STEP 1/4]$(NC) Python simulation..."
	@$(MAKE) test-python
	@echo "$(BLUE)[STEP 2/4]$(NC) Apptainer container..."
	@$(MAKE) test-apptainer  
	@echo "$(BLUE)[STEP 3/4]$(NC) Machine learning..."
	@$(MAKE) test-ml
	@echo "$(BLUE)[STEP 4/4]$(NC) Distributed simulation..."
	@$(MAKE) test-distributed
	@echo ""
	@echo "$(GREEN)[SUCCESS]$(NC) Extended test suite submitted!"
	@echo ""
	@echo "$(BOLD)Monitor extended jobs:$(NC)"
	@echo "  make status                    # Check all job status"
	@echo "  make show-latest-outputs       # View latest outputs"
	@echo "  make wait-for-jobs            # Wait for completion"

## 📊 Monitoring Targets

show-outputs: ## 📄 Display recent job output files
	@echo "$(BOLD)=== Recent Job Outputs ===$(NC)"
	@echo ""
	@echo "$(BLUE)[JOB OUTPUT FILES ON ALL NODES]$(NC)"
	@for node in controller node1 node2 node3; do \
		echo "$(YELLOW)--- $$node ---$(NC)"; \
		$(VAGRANT_WRAPPER) ssh $$node -c "ls -la /home/vagrant/*.out /home/vagrant/*.err 2>/dev/null | tail -5" || echo "No output files on $$node"; \
		echo ""; \
	done
	@echo ""
	@echo "$(BLUE)[LATEST HELLO WORLD OUTPUT]$(NC)"
	@$(VAGRANT_WRAPPER) ssh node1 -c "if [ -f /home/vagrant/hello_world_17.out ]; then echo 'File: hello_world_17.out'; echo '---'; cat /home/vagrant/hello_world_17.out | head -15; echo '---'; else echo 'No hello_world_17.out found'; fi" || echo "$(YELLOW)Cannot access node1$(NC)"
	@echo ""
	@echo "$(BLUE)[LATEST PARALLEL OUTPUT]$(NC)"
	@$(VAGRANT_WRAPPER) ssh node2 -c "if [ -f /home/vagrant/parallel_hello_18.out ]; then echo 'File: parallel_hello_18.out'; echo '---'; cat /home/vagrant/parallel_hello_18.out | head -20; echo '---'; else echo 'No parallel_hello_18.out found'; fi" || echo "$(YELLOW)Cannot access node2$(NC)"
	@echo ""
	@echo "$(BLUE)[LATEST CPU STRESS OUTPUT]$(NC)"
	@$(VAGRANT_WRAPPER) ssh node1 -c "if [ -f /home/vagrant/cpu_stress_19.out ]; then echo 'File: cpu_stress_19.out'; echo '---'; cat /home/vagrant/cpu_stress_19.out | head -10; echo '---'; else echo 'No cpu_stress_19.out found'; fi" || echo "$(YELLOW)Cannot access node1$(NC)"
	@echo ""
	@echo "$(BLUE)[LATEST ARRAY JOB OUTPUT]$(NC)"
	@$(VAGRANT_WRAPPER) ssh node2 -c "if [ -f /home/vagrant/array_job_20_1.out ]; then echo 'File: array_job_20_1.out'; echo '---'; cat /home/vagrant/array_job_20_1.out; echo '---'; else echo 'No array_job_20_1.out found'; fi" || echo "$(YELLOW)Cannot access node2$(NC)"

show-job-output: ## 📄 Show output for a specific job ID (usage: make show-job-output JOB_ID=17)
	@if [ -z "$(JOB_ID)" ]; then \
		echo "$(RED)[ERROR]$(NC) Please specify JOB_ID. Usage: make show-job-output JOB_ID=17"; \
		exit 1; \
	fi
	@echo "$(BOLD)=== Job $(JOB_ID) Output ===$(NC)"
	@echo ""
	@echo "$(BLUE)[SEARCHING FOR JOB $(JOB_ID) OUTPUT FILES]$(NC)"
	@found=false; \
	for node in controller node1 node2 node3; do \
		if $(VAGRANT_WRAPPER) status $$node | grep -q "running"; then \
			echo "$(YELLOW)Checking $$node...$(NC)"; \
			$(VAGRANT_WRAPPER) ssh $$node -c "ls /home/vagrant/*$(JOB_ID)*.out /home/vagrant/*$(JOB_ID)*.err 2>/dev/null" | while read file; do \
				if [ -n "$$file" ]; then \
					echo "$(GREEN)Found: $$file$(NC)"; \
					echo "---"; \
					$(VAGRANT_WRAPPER) ssh $$node -c "cat $$file"; \
					echo "---"; \
					echo ""; \
					found=true; \
				fi; \
			done || true; \
		fi; \
	done

show-latest-outputs: ## 📄 Show the most recent job outputs with smart detection
	@echo "$(BOLD)=== Latest Job Outputs ===$(NC)"
	@echo ""
	@echo "$(BLUE)[MOST RECENT HELLO WORLD]$(NC)"
	@$(VAGRANT_WRAPPER) ssh node1 -c "latest=\$$(ls -t /home/vagrant/hello_world_*.out 2>/dev/null | head -1); if [ -n \"\$$latest\" ]; then echo \"File: \$$latest\"; echo '---'; cat \"\$$latest\" | head -15; echo '---'; else echo 'No hello world outputs found'; fi" || echo "$(YELLOW)Cannot access node1$(NC)"
	@echo ""
	@echo "$(BLUE)[MOST RECENT PARALLEL JOB]$(NC)"
	@$(VAGRANT_WRAPPER) ssh node2 -c "latest=\$$(ls -t /home/vagrant/parallel_hello_*.out 2>/dev/null | head -1); if [ -n \"\$$latest\" ]; then echo \"File: \$$latest\"; echo '---'; cat \"\$$latest\" | head -20; echo '---'; else echo 'No parallel job outputs found'; fi" || echo "$(YELLOW)Cannot access node2$(NC)"
	@echo ""
	@echo "$(BLUE)[MOST RECENT CPU STRESS]$(NC)"
	@$(VAGRANT_WRAPPER) ssh node1 -c "latest=\$$(ls -t /home/vagrant/cpu_stress_*.out 2>/dev/null | head -1); if [ -n \"\$$latest\" ]; then echo \"File: \$$latest\"; echo '---'; cat \"\$$latest\"; echo '---'; else echo 'No CPU stress outputs found'; fi" || echo "$(YELLOW)Cannot access node1$(NC)"
	@echo ""
	@echo "$(BLUE)[MOST RECENT ARRAY JOB]$(NC)"
	@$(VAGRANT_WRAPPER) ssh node2 -c "latest=\$$(ls -t /home/vagrant/array_job_*.out 2>/dev/null | head -1); if [ -n \"\$$latest\" ]; then echo \"File: \$$latest\"; echo '---'; cat \"\$$latest\"; echo '---'; else echo 'No array job outputs found'; fi" || echo "$(YELLOW)Cannot access node2$(NC)"

show-all-outputs: ## 📄 Display all job output files from all nodes
	@echo "$(BOLD)=== All Job Outputs ===$(NC)"
	@echo ""
	@for node in controller node1 node2 node3; do \
		if $(VAGRANT_WRAPPER) status $$node | grep -q "running"; then \
			echo "$(BLUE)[$$node OUTPUT FILES]$(NC)"; \
			files=$$($(VAGRANT_WRAPPER) ssh $$node -c "ls /home/vagrant/*.out 2>/dev/null" || true); \
			if [ -n "$$files" ]; then \
				for file in $$files; do \
					echo "$(YELLOW)$$file:$(NC)"; \
					echo "---"; \
					$(VAGRANT_WRAPPER) ssh $$node -c "head -10 $$file"; \
					echo "... (showing first 10 lines)"; \
					echo "---"; \
					echo ""; \
				done; \
			else \
				echo "No output files on $$node"; \
			fi; \
			echo ""; \
		fi; \
	done

wait-for-jobs: ## ⏳ Wait for all jobs to complete and show results
	@echo "$(YELLOW)[WAITING]$(NC) Waiting for all jobs to complete..."
	@while [ $$($(VAGRANT_WRAPPER) ssh controller -c "source /etc/profile.d/slurm.sh && squeue -h | wc -l" 2>/dev/null || echo "0") -gt 0 ]; do \
		echo "$(BLUE)[STATUS]$(NC) Jobs still running..."; \
		$(VAGRANT_WRAPPER) ssh controller -c "source /etc/profile.d/slurm.sh && squeue" 2>/dev/null || true; \
		sleep 10; \
	done
	@echo "$(GREEN)[COMPLETE]$(NC) All jobs finished!"
	@echo ""
	@$(MAKE) show-outputs

test-and-wait: ## 🧪⏳ Run all tests and wait for completion with results
	@echo "$(GREEN)[INFO]$(NC) Running comprehensive test with monitoring..."
	@$(MAKE) test
	@$(MAKE) wait-for-jobs
	@echo ""
	@echo "$(GREEN)[SUCCESS]$(NC) All tests completed with results displayed!"

status: ## 📊 Show comprehensive cluster and job status
	@echo "$(BOLD)=== Cluster Status ===$(NC)"
	@echo ""
	@echo "$(BLUE)[VM STATUS]$(NC)"
	@$(VAGRANT_WRAPPER) status || echo "$(RED)Error getting VM status$(NC)"
	@echo ""
	@echo "$(BLUE)[SLURM STATUS]$(NC)"
	@$(VAGRANT_WRAPPER) ssh controller -c "source /etc/profile.d/slurm.sh && echo 'Cluster Info:' && sinfo && echo '' && echo 'Node Details:' && scontrol show nodes | grep -E '(NodeName|State|CPUAlloc)'" 2>/dev/null || echo "$(YELLOW)Slurm not ready yet$(NC)"
	@echo ""
	@echo "$(BLUE)[ACTIVE JOBS]$(NC)"
	@$(VAGRANT_WRAPPER) ssh controller -c "source /etc/profile.d/slurm.sh && squeue -o '%.8i %.12j %.8u %.8T %.10M %.6D %R'" 2>/dev/null || echo "$(YELLOW)No jobs in queue$(NC)"
	@echo ""
	@echo "$(BLUE)[RECENT COMPLETED JOBS]$(NC)"
	@$(VAGRANT_WRAPPER) ssh controller -c "source /etc/profile.d/slurm.sh && sacct --format=JobID%10,JobName%15,State%12,ExitCode%8,Start%19,End%19,NodeList%10 -S now-1hour" 2>/dev/null || echo "$(YELLOW)No recent job history$(NC)"
	@echo ""
	@echo "$(BLUE)[JOB OUTPUT FILES]$(NC)"
	@$(VAGRANT_WRAPPER) ssh controller -c "ls -la ~/*.out ~/*.err 2>/dev/null | tail -5" 2>/dev/null || echo "$(YELLOW)No output files found$(NC)"
	@echo ""
	@echo "$(YELLOW)Quick commands:$(NC)"
	@echo "  make show-outputs     # View job outputs"
	@echo "  make wait-for-jobs    # Wait for jobs to finish"
	@echo "  make test-and-wait    # Run tests and monitor"

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
	@echo "Type 'yes' to continue or anything else to cancel:"
	@read REPLY && \
	if [ "$$REPLY" = "yes" ]; then \
		echo "$(YELLOW)[INFO]$(NC) Destroying cluster..."; \
		$(VAGRANT_WRAPPER) destroy -f || true; \
		rm -rf .vagrant; \
		echo "$(BLUE)[INFO]$(NC) Removing Slurm base box..."; \
		$(VAGRANT_WRAPPER) box remove slurm-base -f 2>/dev/null || true; \
		echo "$(BLUE)[INFO]$(NC) Cleaning up any remaining VirtualBox VMs..."; \
		for vm in $$(VBoxManage list vms | grep -E "(slurm-|vagrant-)" | cut -d'"' -f2); do \
			echo "$(YELLOW)[CLEANUP]$(NC) Removing VM: $$vm"; \
			VBoxManage controlvm "$$vm" poweroff 2>/dev/null || true; \
			VBoxManage unregistervm "$$vm" --delete 2>/dev/null || true; \
		done; \
		echo "$(BLUE)[INFO]$(NC) Cleaning up build artifacts..."; \
		rm -f slurm-base.box; \
		echo "$(GREEN)[SUCCESS]$(NC) Cluster destroyed."; \
	else \
		echo "$(BLUE)[INFO]$(NC) Cancelled."; \
	fi

force-clean: ## 🧨 Force cleanup all VMs without confirmation (use with caution)
	@echo "$(RED)[WARNING]$(NC) Force cleaning all Slurm-related VMs..."
	@$(VAGRANT_WRAPPER) destroy -f || true
	@rm -rf .vagrant
	@echo "$(BLUE)[INFO]$(NC) Removing Slurm base box..."
	@$(VAGRANT_WRAPPER) box remove slurm-base -f 2>/dev/null || true
	@echo "$(BLUE)[INFO]$(NC) Cleaning up any remaining VirtualBox VMs..."
	@for vm in $$(VBoxManage list vms | grep -E "(slurm-|vagrant-)" | cut -d'"' -f2); do \
		echo "$(YELLOW)[CLEANUP]$(NC) Removing VM: $$vm"; \
		VBoxManage controlvm "$$vm" poweroff 2>/dev/null || true; \
		VBoxManage unregistervm "$$vm" --delete 2>/dev/null || true; \
	done
	@echo "$(BLUE)[INFO]$(NC) Cleaning up build artifacts..."
	@rm -f slurm-base.box
	@echo "$(GREEN)[SUCCESS]$(NC) Force cleanup completed."

clean-vms: ## 🧽 Remove cluster VMs but keep base box (preserves build time)
	@echo "$(YELLOW)[INFO]$(NC) Removing cluster VMs while preserving base box..."
	@echo "Type 'yes' to continue or anything else to cancel:"
	@read REPLY && \
	if [ "$$REPLY" = "yes" ]; then \
		echo "$(BLUE)[INFO]$(NC) Destroying cluster VMs..."; \
		$(VAGRANT_WRAPPER) destroy -f controller node1 node2 node3 2>/dev/null || true; \
		rm -rf .vagrant; \
		echo "$(BLUE)[INFO]$(NC) Cleaning up cluster VirtualBox VMs..."; \
		for vm in $$(VBoxManage list vms | grep -E "(controller|node[0-9]+)" | cut -d'"' -f2); do \
			echo "$(YELLOW)[CLEANUP]$(NC) Removing VM: $$vm"; \
			VBoxManage controlvm "$$vm" poweroff 2>/dev/null || true; \
			VBoxManage unregistervm "$$vm" --delete 2>/dev/null || true; \
		done; \
		echo "$(GREEN)[SUCCESS]$(NC) Cluster VMs destroyed. Base box preserved."; \
		echo "$(BLUE)[TIP]$(NC) Use 'make cluster' for fast redeployment with preserved base box"; \
	else \
		echo "$(BLUE)[INFO]$(NC) Cancelled."; \
	fi

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

build-vagrant: setup-repos ## 🔨 Build Vagrant from source if needed
	@echo "$(BLUE)[BUILD]$(NC) Ensuring Vagrant is available..."
	@if [ ! -f "$(VAGRANT_WRAPPER)" ]; then \
		echo "$(YELLOW)[INFO]$(NC) Vagrant wrapper not found, setting up..."; \
		echo "Please ensure Vagrant source is available in vagrant-src/"; \
	else \
		chmod +x $(VAGRANT_WRAPPER); \
		echo "$(GREEN)[OK]$(NC) Vagrant wrapper ready"; \
	fi

setup-slurm-source: ## 📦 Setup Slurm source repository (for metal ISO creation)
	@echo "$(BLUE)[SETUP]$(NC) Setting up Slurm source repository..."
	@if [ -d "tmp/slurm" ]; then \
		echo "$(GREEN)[OK]$(NC) Slurm source already exists"; \
		if [ -d "tmp/slurm/.git" ]; then \
			echo "$(BLUE)[INFO]$(NC) Updating Slurm repository..."; \
			cd tmp/slurm && git pull; \
		else \
			echo "$(GREEN)[SKIP]$(NC) Slurm source exists but is not a git repo"; \
		fi \
	else \
		echo "$(BLUE)[INFO]$(NC) Cloning Slurm repository..."; \
		mkdir -p tmp; \
		git clone https://github.com/SchedMD/slurm.git tmp/slurm; \
		echo "$(GREEN)[SUCCESS]$(NC) Slurm source ready"; \
	fi

setup-repos: ## 📦 Clone and setup required repositories
	@echo "$(BLUE)[SETUP]$(NC) Setting up required repositories..."
	@if [ ! -f "./setup-repos.sh" ]; then \
		echo "$(RED)[ERROR]$(NC) setup-repos.sh not found!"; \
		exit 1; \
	fi
	@chmod +x ./setup-repos.sh
	@if [ -d "tmp/vagrant-src" ] && [ -d "tmp/slurm" ]; then \
		echo "$(GREEN)[OK]$(NC) Repositories already exist"; \
		if [ -d "tmp/vagrant-src/.git" ] && [ -d "tmp/slurm/.git" ]; then \
			echo "$(BLUE)[INFO]$(NC) Updating existing repositories..."; \
			./setup-repos.sh; \
		else \
			echo "$(GREEN)[SKIP]$(NC) Repositories exist but are not git repos"; \
		fi \
	else \
		echo "$(BLUE)[INFO]$(NC) Cloning repositories for the first time..."; \
		./setup-repos.sh; \
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

## 🏗️ Bare Metal Deployment

metal: setup-slurm-source ## 🏗️ Create custom Ubuntu ISO for automated bare metal deployment
	@echo "$(BOLD)🏗️ Creating HPC Cluster Custom ISO$(NC)"
	@echo "====================================="
	@echo ""
	@echo "$(BLUE)[INFO]$(NC) This will create a custom Ubuntu Desktop ISO with HPC stack pre-installed"
	@echo "$(BLUE)[INFO]$(NC) Uses Ubuntu Desktop ISO for complete live system modification"
	@echo "$(BLUE)[INFO]$(NC) The ISO can be used to deploy the cluster on bare metal servers"
	@echo ""
	@if [ ! -f "./scripts/create-metal-iso.sh" ]; then \
		echo "$(RED)[ERROR]$(NC) Metal ISO creation script not found!"; \
		exit 1; \
	fi
	@chmod +x ./scripts/create-metal-iso.sh
	@./scripts/create-metal-iso.sh
	@echo ""
	@echo "$(GREEN)[SUCCESS]$(NC) Custom HPC ISO creation complete!"

sim-metal: ## 🖥️ Simulate bare metal installation using QEMU
	@echo "$(BOLD)🖥️ Starting HPC Cluster Metal Simulation$(NC)"
	@echo "========================================"
	@echo ""
	@if [ ! -f "./scripts/simulate-metal.sh" ]; then \
		echo "$(RED)[ERROR]$(NC) Metal simulation script not found!"; \
		exit 1; \
	fi
	@chmod +x ./scripts/simulate-metal.sh
	@./scripts/simulate-metal.sh start

sim-metal-status: ## 📊 Show QEMU simulation status
	@if [ ! -f "./scripts/simulate-metal.sh" ]; then \
		echo "$(RED)[ERROR]$(NC) Metal simulation script not found!"; \
		exit 1; \
	fi
	@./scripts/simulate-metal.sh status

sim-metal-stop: ## ⏹️ Stop QEMU simulation
	@echo "$(BLUE)[INFO]$(NC) Stopping metal simulation..."
	@if [ ! -f "./scripts/simulate-metal.sh" ]; then \
		echo "$(RED)[ERROR]$(NC) Metal simulation script not found!"; \
		exit 1; \
	fi
	@./scripts/simulate-metal.sh stop

sim-metal-clean: ## 🧹 Clean QEMU simulation workspace
	@echo "$(BLUE)[INFO]$(NC) Cleaning metal simulation workspace..."
	@if [ ! -f "./scripts/simulate-metal.sh" ]; then \
		echo "$(RED)[ERROR]$(NC) Metal simulation script not found!"; \
		exit 1; \
	fi
	@./scripts/simulate-metal.sh clean

sim-metal-connect: ## 🔗 Show VNC connection info for QEMU simulation
	@if [ ! -f "./scripts/simulate-metal.sh" ]; then \
		echo "$(RED)[ERROR]$(NC) Metal simulation script not found!"; \
		exit 1; \
	fi
	@./scripts/simulate-metal.sh connect

metal-clean: ## 🧹 Clean up ISO workspace and generated files
	@echo "$(BLUE)[INFO]$(NC) Cleaning up ISO workspace and generated files..."
	@echo "$(YELLOW)[CLEANUP]$(NC) Removing temporary ISO creation directories..."
	@sudo rm -rf iso-workspace/iso-extract iso-workspace/iso-rebuild iso-workspace/squashfs-root 2>/dev/null || true
	@rm -f iso-workspace/.squashfs_filename iso-workspace/install-hpc-stack.sh iso-workspace/grub.cfg 2>/dev/null || true
	@echo "$(YELLOW)[CLEANUP]$(NC) Unmounting any mounted ISOs..."
	@sudo umount /mnt 2>/dev/null || true
	@echo "$(YELLOW)[CLEANUP]$(NC) Removing generated ISO files..."
	@rm -f ubuntu-22.04-hpc-cluster.iso 2>/dev/null || true
	@echo "$(YELLOW)[CLEANUP]$(NC) Cleaning up QEMU simulation workspace..."
	@if [ -f "./scripts/simulate-metal.sh" ]; then \
		./scripts/simulate-metal.sh clean 2>/dev/null || true; \
	fi
	@echo "$(GREEN)[SUCCESS]$(NC) ISO workspace cleaned up!"

# Error handling for missing files
$(VAGRANT_WRAPPER):
	@echo "$(RED)[ERROR]$(NC) Vagrant wrapper not found!"
	@echo "Please ensure vagrant-wrapper.sh exists and is executable."
	@exit 1

$(CLUSTER_MANAGER):
	@echo "$(RED)[ERROR]$(NC) Cluster manager not found!"
	@echo "Please ensure cluster-manager.sh exists and is executable."
	@exit 1
