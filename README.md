# Arketa : : Schurawel — Standardizing HPC Infrastructure

Deploying HPC clusters is historically a fragmented, error-prone endeavor. Arketa : : Schurawel establishes a singular, authoritative "DNA Controller"—a master node encapsulating the entire system configuration, network topology, and compute resource definitions. This architecture ensures deterministic cluster provisioning and eliminates manual configuration drift.

> **Development Status & Legacy Warning (2026)**
> The public state of this repository contains a deprecated legacy codebase (Vagrant/VirtualBox). This version is non-functional and highly overfitted to outdated network topologies. A complete architectural redesign is underway to leverage modern container orchestration and infrastructure-as-code paradigms.

---

## The Infrastructure DNA Philosophy

The core objective is to move from "manual configuration" to deterministic system injection. Compute nodes become ephemeral entities that inherit their entire system identity from the DNA Controller.

This framework will define a strict **HPC Standard**. Current objectives are:
* **Topology Specification**: Defined rack-level network fabrics.
* **Configuration Uniformity**: One source of truth across all nodes.
* **API Interoperability**: Standardized interfaces for cluster management.

---

## Architectural Roadmap: The Decoupled Data Center

Arketa is designed as an elegant, decoupled, datacenter-grade architecture that bridges the gap between hardware and user experience through extensive standardized vertical integration:

### Foundation Layer: Resource Management
0. **[SLURM Workload Manager](https://slurm.schedmd.com/)** — The cornerstone of our HPC stack. SLURM provides open-source cluster resource management and job scheduling, managing compute node allocation, job queuing, and workload distribution. This is the authoritative resource arbiter upon which all higher layers depend.

### User-Facing Layer
1. **[Open OnDemand](https://openondemand.org/)** — Replaces traditional `sbatch` complexity with an intuitive web-based portal. Researchers submit jobs, launch interactive applications, and access graphical desktops through a unified interface, eliminating SSH complexity.

### Resource & Telemetry Layer
2. **[Coldfront](https://coldfront.readthedocs.io/)** — Enterprise resource allocation and project management. Tracks compute allocations, enforces quotas, and provides granular access controls across research groups and departments.
3. **Specialized WebUIs** — Real-time cluster telemetry dashboards, job performance auditing, and historical analytics for capacity planning.

### Infrastructure Layer
4. **[OpenStack](https://www.openstack.org/)** — Virtualization abstraction layer for flexible compute provisioning and live migration capabilities.
5. **[Ceph](https://ceph.io/)** — Resilient, distributed object storage for dedicated stateful workloads, cleanly separated from ephemeral compute node scratch space.

### Emerging Paradigms
6. **Kubernetes Integration** — Experimental initiatives are exploring SLURM-Kubernetes integration for hybrid containerized workloads. While [Borg](https://research.google/pubs/large-scale-cluster-management-at-google-with-borg/) remains the gold standard, it is not yet fully open-source; we monitor community developments in this space.

---

## License & Intellectual Property

This framework is optimized for educational infrastructure design, sandbox engineering, and parallel code prototyping. 

**Copyright (c) 2026 Jason A. Schurawel. All rights reserved.**

Distributed under the [MIT License](https://opensource.org/licenses/MIT). This license allows for reuse, modification, and integration into proprietary or open-source projects, provided that the original copyright notice and disclaimer are retained.
