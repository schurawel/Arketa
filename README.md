# Arketa : : Schurawel — Standardizing HPC Infrastructure

Deploying HPC clusters is historically a fragmented, error-prone endeavor. Arketa : : Schurawel establishes a singular, authoritative "DNA Controller"—a master node encapsulating the entire system configuration and orchestration logic. By standardizing the stack around general-purpose hardware, this framework enables "infrastructure mobility," allowing clusters to be reproduced, migrated, or federated across any site that adheres to these open standards.

> **Development Status & Legacy Warning (2026)**
> The public state of this repository contains a deprecated legacy codebase (Vagrant/VirtualBox). This version is non-functional and highly overfitted to outdated network topologies. A complete architectural overhaul is currently underway in a private repository, discarding legacy abstraction layers for a modern stack utilizing Terraform, Ansible, and Warewulf.

---

## The Infrastructure DNA Philosophy

The core objective is to move from "manual configuration" to deterministic system injection. Compute nodes become ephemeral entities that inherit their entire system identity from the DNA Controller.

This framework will define a strict **HPC Standard**. Current objectives are:
* **Topology Specification**: Defined rack-level network fabrics.
* **Configuration Uniformity**: One source of truth across all nodes.
* **API Interoperability**: Standardized interfaces for cluster management.

---

## Architectural Roadmap: The Decoupled Data Center

Arkeda is supposed to be an elegant, decoupled, datacenter-grade architecture that bridges the gap between hardware and user experience through extensive standardized vertical integration:

1. **User Frontend**: No more "sbatch"... forget it! **Open OnDemand** provides researchers with a web-based, interactive portal for job submission and graphical applications, bypassing traditional SSH complexity.
2. **Resource Management & Analysis**: Integration of **Coldfront** for resource allocation and specialized **WebUIs** to provide real-time cluster telemetry and job performance auditing.
3. **Virtualization & Storage**: Future releases incorporate an **OpenStack** layer for core virtualization and a resilient **Ceph** cluster for dedicated stateful storage, cleanly separated from stateless compute pools.
4. **Holy Grail of parallel computing**: There are some recent initiatives trying to integrate SLURM with Kubernetes. We keep an eye on it. Sadly Borg still is not fully open source... nothing we can do about it.

---

## License & Intellectual Property

This framework is optimized for educational infrastructure design, sandbox engineering, and parallel code prototyping. 

**Copyright (c) 2026 Jason A. Schurawel. All rights reserved.**

Distributed under the [MIT License](https://opensource.org/licenses/MIT). This license allows for reuse, modification, and integration into proprietary or open-source projects, provided that the original copyright notice and this permission notice are included in all copies or substantial portions of the software.
