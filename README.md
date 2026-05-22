# A Paradigm Shift to Elegant. Standardized. Parallel. Infrastructure.

![Arketa Logo](./arketa_logo.png)

Deploying HPC clusters is historically a fragmented, error-prone endeavor. This Package establishes a singular, authoritative "DNA Controller"—a master node encapsulating the entire system configuration, network topology, and compute resource definitions. This way it ensures deterministic cluster provisioning and eliminates manual configuration drift.

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

### Infrastructure and Resource Management Layer
1. **[OpenStack](https://www.openstack.org/)** — Virtualization abstraction layer for flexible infrastructure provisioning and live migration capabilities.
2. **[Ceph](https://ceph.io/)** — Resilient, distributed object storage for dedicated infrastructure workloads, cleanly separated from ephemeral compute node scratch space.
3. **[SLURM Workload Manager](https://slurm.schedmd.com/)** — The cornerstone of our HPC stack. SLURM provides open-source cluster resource management and job scheduling, managing compute node allocation, job queuing, and workload distribution. It serves as the authoritative resource arbiter upon which all higher layers depend. This logical scheduling layer is physically underpinned by **[Warewulf](https://warewulf.org/)**, our provisioning framework of choice. While SLURM orchestrates the application lifecycle, Warewulf manages the stateless provisioning, iPXE bootstrapping, and dynamic node initialization.

### User-Facing Layer
4. **[Open OnDemand](https://openondemand.org/)** — Replaces traditional `sbatch` complexity with an intuitive web-based portal. Researchers submit jobs, launch interactive applications, and access graphical desktops through a unified interface, eliminating SSH complexity.
5. **[Coldfront](https://coldfront.readthedocs.io/)** — Enterprise resource allocation and project management. Tracks compute allocations, enforces quotas, and provides granular access controls across research groups and departments.
6. **Specialized WebUIs** — Real-time cluster telemetry dashboards, job performance auditing, and historical analytics for capacity planning.

### Emerging Paradigm: **Kubernetes Integration** 
Experimental initiatives are exploring SLURM-Kubernetes integration for hybrid containerized workloads. While [Borg](https://research.google/pubs/large-scale-cluster-management-at-google-with-borg/) remains the gold standard, it is not yet fully open-source; we monitor community developments in this space.

---

### License & Intellectual Property

This software is licensed under the GNU General Public License v3.0, allowing you to freely use, modify, and distribute the code provided that you maintain the same license terms.
