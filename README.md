# Slurm HPC Cluster with Vagrant

A complete, automated High-Performance Computing (HPC) cluster setup using Slurm workload manager, built with Vagrant and VirtualBox. Perfect for learning HPC concepts, testing Slurm configurations, and developing parallel applications.

## 🚀 Quick Start

```bash
# Initialize and start the cluster
make cluster

# Run test jobs
make test

# Connect to the cluster
make connect

# Stop the cluster
make clean
```

## 📋 Table of Contents

- [Features](#features)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Cluster Architecture](#cluster-architecture)
- [Usage](#usage)
- [Sample Jobs](#sample-jobs)
- [Makefile Targets](#makefile-targets)
- [Troubleshooting](#troubleshooting)
- [Project Structure](#project-structure)

## ✨ Features

- **Fully Automated Setup**: One command cluster deployment
- **Multi-Node Architecture**: 1 controller + 3 compute nodes
- **Complete Slurm Stack**: Scheduler, database, authentication
- **Sample Workloads**: Ready-to-run example jobs
- **Resource Management**: CPU and memory allocation
- **Job Accounting**: Database-backed job tracking
- **Network File System**: Shared storage across nodes
- **Source-Built Vagrant**: Latest Vagrant built from source

## 📦 Prerequisites

### System Requirements
- **OS**: Linux (Ubuntu/Debian recommended)
- **CPU**: 4+ cores, VT-x/AMD-V enabled in BIOS
- **RAM**: 8GB minimum (16GB recommended)
- **Disk**: 20GB free space
- **Network**: Internet connection for initial setup

### Software Dependencies
```bash
# Ubuntu/Debian
sudo apt update
sudo apt install -y make git virtualbox ruby ruby-dev build-essential

# The project will build Vagrant from source automatically
```

## 🏗️ Cluster Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Slurm HPC Cluster                       │
├─────────────────────────────────────────────────────────────┤
│  Controller Node (slurm-controller)                        │
│  • IP: 192.168.60.10                                       │
│  • Services: slurmctld, slurmdbd, MariaDB, NFS             │
│  • Resources: 2 CPU cores, 2GB RAM                         │
├─────────────────────────────────────────────────────────────┤
│  Compute Nodes (node1, node2, node3)                       │
│  • IPs: 192.168.60.11-13                                   │
│  • Services: slurmd, NFS client                            │
│  • Resources: 2 CPU cores each, 1GB RAM each               │
└─────────────────────────────────────────────────────────────┘
```

### Network Configuration
- **Private Network**: 192.168.60.0/24
- **Controller**: 192.168.60.10
- **Compute Nodes**: 192.168.60.11-13
- **Shared Storage**: NFS mounted on all nodes

### Slurm Configuration
- **Scheduler**: `sched/backfill` with `select/cons_tres`
- **Authentication**: Munge-based cluster authentication
- **Accounting**: MySQL/MariaDB via slurmdbd
- **Default Partition**: `compute` with all nodes

## 🎯 Usage

### Basic Workflow

1. **Start the cluster**:
   ```bash
   make cluster
   ```
   This will:
   - Build Vagrant from source if needed
   - Create and provision all VMs
   - Install and configure Slurm
   - Start all services

2. **Submit jobs**:
   ```bash
   make test              # Run all sample jobs
   make test-hello        # Run hello world job
   make test-parallel     # Run parallel job
   make test-stress       # Run CPU stress test
   make test-array        # Run job array
   ```

3. **Monitor the cluster**:
   ```bash
   make status            # Check cluster status
   make connect           # SSH to controller
   ```

4. **Clean up**:
   ```bash
   make clean             # Stop and destroy cluster
   ```

### Manual Operations

Connect to the controller node:
```bash
make connect
# OR
./vagrant-wrapper.sh ssh controller
```

Once connected, use standard Slurm commands:
```bash
# Load Slurm environment
source /etc/profile.d/slurm.sh

# Check cluster status
sinfo
scontrol show nodes

# Submit a job
sbatch sample-jobs/hello_world.sh

# Monitor jobs
squeue
squeue -u vagrant

# View job history
sacct
sacct -j <job_id> --format=JobID,JobName,State,ExitCode,Start,End
```

## 📋 Sample Jobs

The cluster includes several example jobs to demonstrate different Slurm features:

### 1. Hello World (`hello_world.sh`)
Basic single-node job that displays system information and performs a simple calculation.
```bash
sbatch sample-jobs/hello_world.sh
```

### 2. Parallel Job (`parallel_hello.sh`)
Multi-node parallel job using `srun` to execute tasks across multiple compute nodes.
```bash
sbatch sample-jobs/parallel_hello.sh
```

### 3. CPU Stress Test (`cpu_stress.sh`)
CPU-intensive workload to test cluster performance and resource allocation.
```bash
sbatch sample-jobs/cpu_stress.sh
```

### 4. Job Array (`array_job.sh`)
Demonstrates Slurm job arrays with multiple independent tasks.
```bash
sbatch sample-jobs/array_job.sh
```

## 🛠️ Makefile Targets

| Target | Description |
|--------|-------------|
| `make cluster` | Complete cluster setup (build Vagrant, start VMs, configure Slurm) |
| `make test` | Run all sample jobs and display results |
| `make test-hello` | Run hello world job |
| `make test-parallel` | Run parallel job |
| `make test-stress` | Run CPU stress test |
| `make test-array` | Run job array |
| `make status` | Show cluster and job status |
| `make connect` | SSH to controller node |
| `make logs` | Display Slurm service logs |
| `make health` | Perform cluster health check |
| `make stop` | Stop all VMs (keep them for restart) |
| `make start` | Start stopped VMs |
| `make clean` | Stop and destroy all VMs |
| `make help` | Show all available targets |

## 🔧 Troubleshooting

### Common Issues

#### VT-x/Hardware Virtualization
```bash
# Check if VT-x is enabled
grep -E "(vmx|svm)" /proc/cpuinfo

# If not found, enable VT-x in BIOS settings
```

#### Nodes Showing as DOWN
```bash
# Connect to controller and resume nodes
make connect
scontrol update NodeName=node[1-3] State=RESUME
```

#### Munge Authentication Errors
```bash
# Test munge on each node
./vagrant-wrapper.sh ssh node1
munge -n | unmunge

# Restart munge if needed
sudo systemctl restart munge
```

#### Database Connection Issues
```bash
# Check database connectivity
./vagrant-wrapper.sh ssh controller
mysql -h slurm-controller -u slurm -p slurm_acct_db

# Restart slurmdbd
sudo systemctl restart slurmdbd
```

#### Service Status Checks
```bash
# Check all services
make health

# Check specific logs
make logs

# Or manually check services
./vagrant-wrapper.sh ssh controller
sudo systemctl status slurmctld slurmdbd mariadb
sudo journalctl -u slurmctld -f
```

### Log Locations
- **Slurmctld**: `/var/log/slurm/slurmctld.log`
- **Slurmd**: `/var/log/slurm/slurmd.log`
- **Slurmdbd**: `/var/log/slurm/slurmdbd.log`
- **Job Output**: `~/hello_world_<job_id>.out`

## 📁 Project Structure

```
MyCluster/
├── Makefile                    # Main automation and build commands
├── README.md                   # This documentation
├── Vagrantfile                 # VM and cluster configuration
├── vagrant-wrapper.sh          # Wrapper for source-built Vagrant
├── cluster-manager.sh          # Cluster lifecycle management
├── preflight-check-source.sh   # Pre-deployment validation
│
├── scripts/                    # Provisioning scripts
│   ├── setup-controller.sh     # Controller node setup
│   ├── setup-compute.sh        # Compute node setup
│   ├── setup-database.sh       # Database configuration
│   └── test-cluster.sh         # Job testing utilities
│
├── sample-jobs/                # Example Slurm job scripts
│   ├── hello_world.sh          # Basic single-node job
│   ├── parallel_hello.sh       # Multi-node parallel job
│   ├── cpu_stress.sh           # CPU-intensive workload
│   └── array_job.sh            # Job array example
│
├── slurm/                      # Slurm source code
└── vagrant-src/                # Vagrant source code
```

## 🔐 Security Notes

This cluster is designed for **development and testing only**. It includes:
- Default passwords and keys
- Permissive network settings
- Minimal security hardening

**Do not use this configuration in production environments.**

## 🤝 Contributing

Feel free to:
- Report issues or bugs
- Suggest improvements
- Add new sample jobs
- Enhance documentation

## 📚 Resources

- [Slurm Documentation](https://slurm.schedmd.com/documentation.html)
- [Slurm Quick Start Guide](https://slurm.schedmd.com/quickstart.html)
- [Vagrant Documentation](https://www.vagrantup.com/docs)
- [VirtualBox Documentation](https://www.virtualbox.org/wiki/Documentation)

## 📄 License

This project is for educational and testing purposes. Slurm and other components retain their respective licenses.

---

**Happy HPC Computing!** 🚀
