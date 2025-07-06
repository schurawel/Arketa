#!/bin/bash
# QEMU-based Metal Installation Simulation
# Simulates bare metal deployment using QEMU VMs

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
QEMU_WORKSPACE="${PROJECT_DIR}/qemu-workspace"
CUSTOM_ISO="${PROJECT_DIR}/ubuntu-22.04-hpc-cluster.iso"
BASE_ISO="${PROJECT_DIR}/ubuntu-22.04.5-live-server-amd64.iso"

# VM Configuration
CONTROLLER_DISK="${QEMU_WORKSPACE}/controller.qcow2"
COMPUTE1_DISK="${QEMU_WORKSPACE}/compute1.qcow2"
COMPUTE2_DISK="${QEMU_WORKSPACE}/compute2.qcow2"
COMPUTE3_DISK="${QEMU_WORKSPACE}/compute3.qcow2"

# Network configuration
BRIDGE_NAME="hpc-bridge"
NETWORK_SUBNET="192.168.100"

# Utility functions
log() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

check_dependencies() {
    log "Checking QEMU dependencies..."
    
    local missing_deps=()
    
    for cmd in qemu-system-x86_64 qemu-img brctl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        warn "Missing dependencies: ${missing_deps[*]}"
        log "Installing QEMU and bridge utilities..."
        sudo apt update
        sudo apt install -y qemu-system-x86 qemu-utils bridge-utils
    fi
    
    success "Dependencies check passed"
}

setup_network() {
    log "Setting up virtual network bridge..."
    
    # Check if bridge already exists
    if ! brctl show | grep -q "$BRIDGE_NAME"; then
        sudo brctl addbr "$BRIDGE_NAME"
        sudo ip addr add "${NETWORK_SUBNET}.1/24" dev "$BRIDGE_NAME"
        sudo ip link set dev "$BRIDGE_NAME" up
        success "Bridge $BRIDGE_NAME created"
    else
        log "Bridge $BRIDGE_NAME already exists"
    fi
    
    # Enable IP forwarding
    echo 1 | sudo tee /proc/sys/net/ipv4/ip_forward > /dev/null
}

cleanup_network() {
    log "Cleaning up network bridge..."
    if brctl show | grep -q "$BRIDGE_NAME"; then
        sudo ip link set dev "$BRIDGE_NAME" down
        sudo brctl delbr "$BRIDGE_NAME"
        success "Bridge $BRIDGE_NAME removed"
    fi
}

create_vm_disks() {
    log "Creating VM disk images..."
    
    mkdir -p "$QEMU_WORKSPACE"
    
    # Create disk images for each VM
    for disk in "$CONTROLLER_DISK" "$COMPUTE1_DISK" "$COMPUTE2_DISK" "$COMPUTE3_DISK"; do
        if [ ! -f "$disk" ]; then
            qemu-img create -f qcow2 "$disk" 20G
            log "Created disk: $(basename "$disk")"
        else
            log "Disk already exists: $(basename "$disk")"
        fi
    done
    
    success "VM disks ready"
}

select_iso() {
    local iso_path=""
    
    if [ -f "$CUSTOM_ISO" ]; then
        log "Found custom HPC ISO: $CUSTOM_ISO"
        echo "$CUSTOM_ISO"
    elif [ -f "$BASE_ISO" ]; then
        log "Using base Ubuntu ISO: $BASE_ISO"
        echo "$BASE_ISO"
    else
        error "No ISO found. Please create metal ISO first with 'make metal' or download base ISO."
    fi
}

start_controller() {
    local iso_path="$1"
    log "Starting controller VM..."
    
    qemu-system-x86_64 \
        -name "hpc-controller" \
        -machine type=pc,accel=kvm:tcg \
        -cpu host \
        -smp 2 \
        -m 2048 \
        -drive file="$CONTROLLER_DISK",format=qcow2,if=virtio \
        -cdrom "$iso_path" \
        -boot order=dc \
        -netdev bridge,id=net0,br="$BRIDGE_NAME" \
        -device virtio-net-pci,netdev=net0,mac=52:54:00:12:34:10 \
        -vnc :1 \
        -monitor stdio \
        -daemonize \
        -pidfile "${QEMU_WORKSPACE}/controller.pid"
    
    success "Controller VM started (VNC: localhost:5901)"
}

start_compute_node() {
    local node_id="$1"
    local iso_path="$2"
    local disk_path="${QEMU_WORKSPACE}/compute${node_id}.qcow2"
    local mac_suffix="1${node_id}"
    local vnc_port="$((1 + node_id))"
    
    log "Starting compute node $node_id..."
    
    qemu-system-x86_64 \
        -name "hpc-compute$node_id" \
        -machine type=pc,accel=kvm:tcg \
        -cpu host \
        -smp 2 \
        -m 1024 \
        -drive file="$disk_path",format=qcow2,if=virtio \
        -cdrom "$iso_path" \
        -boot order=dc \
        -netdev bridge,id=net0,br="$BRIDGE_NAME" \
        -device virtio-net-pci,netdev=net0,mac=52:54:00:12:34:${mac_suffix} \
        -vnc :$vnc_port \
        -nographic \
        -daemonize \
        -pidfile "${QEMU_WORKSPACE}/compute${node_id}.pid"
    
    success "Compute node $node_id started (VNC: localhost:590${vnc_port})"
}

start_cluster() {
    local iso_path
    iso_path=$(select_iso)
    
    setup_network
    create_vm_disks
    
    log "Starting HPC cluster simulation..."
    
    # Start controller
    start_controller "$iso_path"
    sleep 2
    
    # Start compute nodes
    for i in 1 2 3; do
        start_compute_node "$i" "$iso_path"
        sleep 1
    done
    
    echo ""
    success "HPC cluster simulation started!"
    echo ""
    echo -e "${YELLOW}VNC Access:${NC}"
    echo "  Controller: localhost:5901"
    echo "  Compute 1:  localhost:5902"
    echo "  Compute 2:  localhost:5903"
    echo "  Compute 3:  localhost:5904"
    echo ""
    echo -e "${YELLOW}Expected Network:${NC}"
    echo "  Controller: ${NETWORK_SUBNET}.10"
    echo "  Compute 1:  ${NETWORK_SUBNET}.11"
    echo "  Compute 2:  ${NETWORK_SUBNET}.12"
    echo "  Compute 3:  ${NETWORK_SUBNET}.13"
    echo ""
    echo -e "${BLUE}Commands:${NC}"
    echo "  View status: make sim-metal-status"
    echo "  Stop cluster: make sim-metal-stop"
    echo "  Connect via VNC: vncviewer localhost:5901"
}

stop_cluster() {
    log "Stopping HPC cluster simulation..."
    
    # Stop all VMs
    for pidfile in "${QEMU_WORKSPACE}"/*.pid; do
        if [ -f "$pidfile" ]; then
            local pid
            pid=$(cat "$pidfile")
            local vm_name
            vm_name=$(basename "$pidfile" .pid)
            
            if kill -0 "$pid" 2>/dev/null; then
                log "Stopping $vm_name (PID: $pid)"
                kill "$pid"
                rm -f "$pidfile"
            else
                log "$vm_name not running"
                rm -f "$pidfile"
            fi
        fi
    done
    
    sleep 2
    cleanup_network
    success "Cluster simulation stopped"
}

show_status() {
    echo -e "${BOLD}HPC Cluster Simulation Status${NC}"
    echo "================================"
    echo ""
    
    local running_vms=0
    
    for pidfile in "${QEMU_WORKSPACE}"/*.pid; do
        if [ -f "$pidfile" ]; then
            local pid
            pid=$(cat "$pidfile")
            local vm_name
            vm_name=$(basename "$pidfile" .pid)
            
            if kill -0 "$pid" 2>/dev/null; then
                echo -e "${GREEN}✓${NC} $vm_name (PID: $pid)"
                ((running_vms++))
            else
                echo -e "${RED}✗${NC} $vm_name (not running)"
                rm -f "$pidfile"
            fi
        fi
    done
    
    if [ $running_vms -eq 0 ]; then
        echo -e "${YELLOW}No VMs currently running${NC}"
    else
        echo ""
        echo -e "${BLUE}VNC Access:${NC}"
        [ -f "${QEMU_WORKSPACE}/controller.pid" ] && echo "  Controller: localhost:5901"
        [ -f "${QEMU_WORKSPACE}/compute1.pid" ] && echo "  Compute 1:  localhost:5902"
        [ -f "${QEMU_WORKSPACE}/compute2.pid" ] && echo "  Compute 2:  localhost:5903"
        [ -f "${QEMU_WORKSPACE}/compute3.pid" ] && echo "  Compute 3:  localhost:5904"
    fi
    
    echo ""
    if brctl show | grep -q "$BRIDGE_NAME"; then
        echo -e "${GREEN}✓${NC} Network bridge: $BRIDGE_NAME"
    else
        echo -e "${RED}✗${NC} Network bridge: $BRIDGE_NAME"
    fi
}

clean_workspace() {
    log "Cleaning simulation workspace..."
    
    stop_cluster
    
    if [ -d "$QEMU_WORKSPACE" ]; then
        rm -rf "$QEMU_WORKSPACE"
        success "Workspace cleaned"
    fi
}

create_vnc_script() {
    log "Creating VNC connection script..."
    
    cat > "${QEMU_WORKSPACE}/connect-vnc.sh" << 'EOF'
#!/bin/bash
# Connect to cluster VMs via VNC

NODE="$1"

case "$NODE" in
    controller|ctrl)
        echo "Connecting to controller..."
        vncviewer localhost:5901 2>/dev/null &
        ;;
    compute1|node1|1)
        echo "Connecting to compute node 1..."
        vncviewer localhost:5902 2>/dev/null &
        ;;
    compute2|node2|2)
        echo "Connecting to compute node 2..."
        vncviewer localhost:5903 2>/dev/null &
        ;;
    compute3|node3|3)
        echo "Connecting to compute node 3..."
        vncviewer localhost:5904 2>/dev/null &
        ;;
    *)
        echo "Usage: $0 {controller|compute1|compute2|compute3}"
        echo ""
        echo "Available nodes:"
        echo "  controller - HPC controller node"
        echo "  compute1   - Compute node 1"
        echo "  compute2   - Compute node 2"
        echo "  compute3   - Compute node 3"
        exit 1
        ;;
esac
EOF

    chmod +x "${QEMU_WORKSPACE}/connect-vnc.sh"
}

usage() {
    echo "Usage: $0 {start|stop|status|clean|connect}"
    echo ""
    echo "Commands:"
    echo "  start   - Start the HPC cluster simulation"
    echo "  stop    - Stop all running VMs"
    echo "  status  - Show cluster status"
    echo "  clean   - Stop VMs and clean workspace"
    echo "  connect - Show VNC connection information"
    echo ""
    echo "Requirements:"
    echo "  - QEMU/KVM installed"
    echo "  - VNC viewer for console access"
    echo "  - Bridge utilities for networking"
}

main() {
    case "${1:-start}" in
        start)
            echo -e "${BOLD}🖥️ HPC Cluster Metal Simulation${NC}"
            echo "=================================="
            echo ""
            check_dependencies
            start_cluster
            create_vnc_script
            ;;
        stop)
            stop_cluster
            ;;
        status)
            show_status
            ;;
        clean)
            clean_workspace
            ;;
        connect)
            echo -e "${BLUE}VNC Connection Information:${NC}"
            echo "  Controller: vncviewer localhost:5901"
            echo "  Compute 1:  vncviewer localhost:5902"
            echo "  Compute 2:  vncviewer localhost:5903"
            echo "  Compute 3:  vncviewer localhost:5904"
            echo ""
            echo "Or use the helper script:"
            echo "  ${QEMU_WORKSPACE}/connect-vnc.sh controller"
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

# Check for sudo privileges for network setup
if [ "$1" = "start" ] && [ "$EUID" -ne 0 ]; then
    echo "Note: This script may require sudo for network bridge setup"
fi

main "$@"
