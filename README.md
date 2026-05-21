# Slurm HPC Cluster Framework

This framework provides an automated infrastructure stack for deploying a multi-node High-Performance Computing (HPC) cluster managed by the Slurm workload manager. Designed to transition smoothly from localized sandbox environments to physical infrastructure, the architecture handles compute provisioning, job accounting, network file sharing, and internal cluster authentication.

> ### ⚠️ Status and Configuration Warning (2026 Revision)
> This repository is currently undergoing a comprehensive architectural overhaul. The legacy codebase contains configurations tightly coupled to specific local area network (LAN) topologies and environmental variables. It requires significant polishing and refactoring before deployment in varying networks. 
>
> As part of the 2026 development cycle, the legacy Vagrant and VirtualBox abstraction layers have been completely deprecated in favor of enterprise-grade cloud and bare-metal provisioning tools.

---

## Evolving Infrastructure Stack

To build a production-ready, scalable HPC environment, this project is migrating away from local virtualization wrappers toward a modern DevOps workflow. The next-generation deployment model relies on Terraform to manage stateful compute instances, private subnets, and isolated network fabrics across both cloud targets and local hypervisors. This infrastructure is paired with Warewulf, which operates as the stateless provisioning engine, utilizing iPXE to orchestrate compute node deployments directly into memory. Finally, Ansible handles the deterministic host configuration, automating uniform Munge keys, Slurm daemons, and MariaDB accounting backends across the entire cluster.

---

## Architectural Layout

The cluster framework orchestrates a dedicated control plane linked to a scalable pool of execution nodes, interconnected via an isolated internal network fabric. 

```text
┌─────────────────────────────────────────────────────────────┐
│                      Slurm HPC Cluster                      │
├─────────────────────────────────────────────────────────────┤
│  [Control Plane] slurm-controller (Scheduler & Accounting)  │
├─────────────────────────────────────────────────────────────┤
│  [Execution Pool] node01 - nodeXX (Stateless Compute Nodes) │
└─────────────────────────────────────────────────────────────┘
```

The controller node manages scheduler orchestration, job accounting, and data exports through primary services like `slurmctld` and `slurmdbd`. Meanwhile, the stateless compute nodes handle parallel task execution and resource reporting via the `slurmd` execution layer. The control plane utilizes backfill scheduling mechanisms paired with trackable resource selection algorithms. Authentication across the cluster boundaries is validated securely via local cryptographic Munge tokens, while all historical job metrics are synchronized downstream into a centralized SQL database engine.

---

## Sample Workload Execution

Once the execution environment is active, individual tasks are dispatched via standard Slurm resource requests. The repository includes baseline verification templates located within the sample directory. You can dispatch a standard non-interactive tracking script via `sbatch sample-jobs/hello_world.sh`, allocate a multi-node task distributed via the internal launcher using `sbatch sample-jobs/parallel_hello.sh`, or trigger an execution array matrix for parallel computing with `sbatch sample-jobs/array_job.sh`.

Active job lifecycles can be audited inside the cluster environment using native diagnostic tools:

```bash
sinfo     # Evaluates partition states and node availability
squeue    # Inspects active scheduling queues and step states
sacct     # Queries the slurmdbd accounting registry for metrics
```

---

## Directory Infrastructure

The framework maps installation phases to specific subsystem layouts, organizing core configuration logic cleanly away from sample cluster payloads. The `terraform/` directory holds cloud and virtualized fabric state manifests, while `ansible/` contains the playbooks for uniform node orchestration. Operational automation and cluster tooling are abstracted through the root `Makefile`. Furthermore, the `scripts/` directory houses provisioning utilities and environment hooks, keeping the collective baseline software layers separated from specific controller or compute node deployment instructions.

---

## Troubleshooting and Node Maintenance

Compute nodes occasionally report a `DOWN` or `DRAIN` status if local telemetry flags unexpected hardware steps or communication timeouts during startup. The administrator can clear these defensive error flags manually from the controller console via `scontrol update NodeName=node[01-XX] State=RESUME` to restore scheduling access. 

Additionally, Munge daemons require absolute clock synchronization and matching cryptographic key symmetry across every compute layer. If log files record handshake authorization failures, verify system time configurations and ensure the payload at `/etc/munge/munge.key` mirrors the master controller hash exactly with restrictive permission flags.

---

## Architectural Roadmap

The long-term vision for this framework aims at building an elegant, decoupled, datacenter-grade architecture. Future releases will focus on the modular integration of three foundational layers. First, Open OnDemand will be integrated to provide researchers with an interactive, web-based frontend for job submission and graphical applications without SSH overhead. Beneath the surface, an OpenStack layer will be evaluated to orchestrate core virtualization boundaries on top of physical hardware. Finally, a resilient, distributed Ceph cluster will be implemented to handle dedicated stateful storage nodes, cleanly separated from the stateless compute pools that continue to be dynamically provisioned into memory via Warewulf and managed by Slurm.

---

## License & Development Notes

This framework is optimized exclusively for educational infrastructure design, sandbox engineering, and parallel code prototyping. Hardcoded default database credentials and relaxed network configurations are active within development scripts. Hardening routines must be implemented prior to scaling any component into production environments. Distributed under standard open-source provisions.
