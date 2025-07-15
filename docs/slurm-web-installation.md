# Slurm-web Installation Guide

This document provides a comprehensive guide for installing Slurm-web on Ubuntu 24.04 LTS, following the official quickstart guide from Rackslab.

## Prerequisites

Before beginning the installation, ensure:

1. A working Slurm cluster with slurmctld running
2. slurmrestd installed and configured with JWT authentication
3. sudo/root privileges on the controller node

## Installation Steps

### 1. Add the Rackslab Package Repository

First, add the Rackslab package repository and GPG key:

```bash
# Download and install the GPG key
curl -fsSL https://pkgs.rackslab.io/keyring.asc | sudo gpg --dearmor -o /usr/share/keyrings/rackslab.gpg

# Create the repository source file
cat <<EOF | sudo tee /etc/apt/sources.list.d/rackslab.sources
Types: deb
URIs: https://pkgs.rackslab.io/deb
Suites: ubuntu24.04
Components: main slurmweb-5
Architectures: amd64
Signed-By: /usr/share/keyrings/rackslab.gpg
EOF

# Update package lists
sudo apt update
```

### 2. Install Slurm-web Packages

Install the Slurm-web agent and gateway packages:

```bash
sudo apt install -y slurm-web-agent slurm-web-gateway
```

### 3. Configure JWT Authentication

Slurm-web requires JWT authentication to be properly set up:

```bash
# Generate JWT key for Slurm-web
sudo /usr/libexec/slurm-web/slurm-web-gen-jwt-key

# Copy slurmrestd JWT key (assuming it already exists)
sudo cp /var/spool/slurm/jwt_hs256.key /var/lib/slurm-web/slurmrestd.key
sudo chown slurm-web:slurm-web /var/lib/slurm-web/slurmrestd.key
sudo chmod 400 /var/lib/slurm-web/slurmrestd.key
```

### 4. Configure the Slurm-web Agent

Create or edit the agent configuration file:

```bash
cat <<EOF | sudo tee /etc/slurm-web/agent.ini
[service]
cluster=vagrant-cluster  # Change to your cluster name
interface=0.0.0.0
port=5012

[slurmrestd]
socket=/run/slurmrestd/slurmrestd.socket
jwt_key=/var/lib/slurm-web/slurmrestd.key

[cache]
enabled=no

[racksdb]
enabled=no
EOF
```

### 5. Configure the Slurm-web Gateway

Create or edit the gateway configuration file:

```bash
cat <<EOF | sudo tee /etc/slurm-web/gateway.ini
[service]
interface=0.0.0.0
port=5011

[agents]
url=http://localhost:5012

[authentication]
enabled=no
EOF
```

For a demo environment, create an anonymous access policy:

```bash
cat <<EOF | sudo tee /etc/slurm-web/policy.ini
[roles]
anonymous

[anonymous]
actions=view-stats,view-jobs,view-nodes,view-partitions,view-qos,view-accounts,view-reservations,cache-view
EOF
```

### 6. Start and Enable the Services

Start and enable the Slurm-web services:

```bash
# Reload systemd configuration
sudo systemctl daemon-reload

# Restart slurmrestd to ensure it's properly configured
sudo systemctl restart slurmrestd

# Start and enable the agent first
sudo systemctl enable --now slurm-web-agent

# Wait a moment for the agent to start
sleep 5

# Start and enable the gateway
sudo systemctl enable --now slurm-web-gateway
```

### 7. Verify Installation

Check that all services are running correctly:

```bash
# Check slurmrestd status
systemctl status slurmrestd

# Check agent status
systemctl status slurm-web-agent

# Check gateway status
systemctl status slurm-web-gateway
```

Access the Slurm-web interface at: `http://<server-ip>:5011`

## Troubleshooting

If you encounter issues:

1. Check service logs:
   ```bash
   sudo journalctl -u slurm-web-agent
   sudo journalctl -u slurm-web-gateway
   sudo journalctl -u slurmrestd
   ```

2. Verify the slurmrestd socket exists:
   ```bash
   ls -la /run/slurmrestd/slurmrestd.socket
   ```

3. Check that JWT authentication is working:
   ```bash
   sudo -u slurm /opt/slurm/bin/scontrol token
   ```

4. Ensure port access:
   ```bash
   # Check if ports are open
   ss -tulpn | grep -E '5011|5012'
   ```

5. Manual service restart:
   ```bash
   sudo systemctl restart slurmrestd slurm-web-agent slurm-web-gateway
   ```

## Common Issues

1. **Agent unable to connect to slurmrestd**
   - Ensure the socket path is correct in agent.ini
   - Verify the socket exists and has proper permissions
   - Check that slurmrestd is running with the Unix socket option

2. **Gateway unable to connect to agent**
   - Verify the URL in gateway.ini is correct (use localhost, not 0.0.0.0)
   - Check if the agent is running and listening on port 5012

3. **Authentication failures**
   - Ensure JWT keys are properly created and have the correct permissions
   - Verify Slurm is configured with JWT authentication

## References

- [Official Slurm-web Documentation](https://docs.rackslab.io/slurm-web/)
- [Quickstart Guide](https://docs.rackslab.io/slurm-web/install/quickstart.html)
- [Rackslab GitHub Repository](https://github.com/rackslab/slurm-web)
