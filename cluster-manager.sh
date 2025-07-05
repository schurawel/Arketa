#!/bin/bash
# Vagrant Slurm Cluster Management Script

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if we're in the right directory
check_directory() {
    if [[ ! -f "Vagrantfile" ]]; then
        print_error "Vagrantfile not found. Please run this script from the cluster directory."
        exit 1
    fi
}

# Function to show cluster status
show_status() {
    print_status "Checking Vagrant cluster status..."
    ./vagrant-wrapper.sh status
    
    print_status "Checking if VMs are accessible..."
    local nodes=("controller" "node1" "node2" "node3")
    
    for node in "${nodes[@]}"; do
        if ./vagrant-wrapper.sh status "$node" | grep -q "running"; then
            print_success "$node is running"
            # Test SSH connectivity
            if ./vagrant-wrapper.sh ssh "$node" -c "echo 'SSH test successful'" >/dev/null 2>&1; then
                print_success "$node SSH connectivity OK"
            else
                print_warning "$node SSH connectivity failed"
            fi
        else
            print_warning "$node is not running"
        fi
    done
}

# Function to start the cluster
start_cluster() {
    local start_mode=${1:-"all"}
    
    print_status "Starting Slurm cluster..."
    
    case $start_mode in
        "controller")
            print_status "Starting controller node only..."
            ./vagrant-wrapper.sh up controller
            ;;
        "compute")
            print_status "Starting compute nodes only..."
            ./vagrant-wrapper.sh up node1 node2 node3
            ;;
        "all")
            print_status "Starting all nodes..."
            ./vagrant-wrapper.sh up
            ;;
        *)
            print_error "Invalid start mode: $start_mode"
            print_status "Valid modes: all, controller, compute"
            exit 1
            ;;
    esac
    
    print_success "Cluster startup completed!"
    print_status "Waiting for services to initialize..."
    sleep 30
    
    # Check if controller is accessible
    if ./vagrant-wrapper.sh ssh controller -c "command -v sinfo >/dev/null" >/dev/null 2>&1; then
        print_success "Slurm controller is ready!"
        ./vagrant-wrapper.sh ssh controller -c "source /etc/profile.d/slurm.sh && sinfo"
    else
        print_warning "Slurm controller might still be initializing..."
        print_status "Try running: ./vagrant-wrapper.sh ssh controller"
        print_status "Then: source /etc/profile.d/slurm.sh && sinfo"
    fi
}

# Function to stop the cluster
stop_cluster() {
    local stop_mode=${1:-"all"}
    
    print_status "Stopping Slurm cluster..."
    
    case $stop_mode in
        "controller")
            print_status "Stopping controller node only..."
            ./vagrant-wrapper.sh halt controller
            ;;
        "compute")
            print_status "Stopping compute nodes only..."
            ./vagrant-wrapper.sh halt node1 node2 node3
            ;;
        "all")
            print_status "Stopping all nodes..."
            ./vagrant-wrapper.sh halt
            ;;
        *)
            print_error "Invalid stop mode: $stop_mode"
            print_status "Valid modes: all, controller, compute"
            exit 1
            ;;
    esac
    
    print_success "Cluster stopped successfully!"
}

# Function to restart the cluster
restart_cluster() {
    print_status "Restarting Slurm cluster..."
    stop_cluster all
    sleep 10
    start_cluster all
}

# Function to destroy and recreate the cluster
rebuild_cluster() {
    print_warning "This will destroy all VMs and recreate them from scratch!"
    read -p "Are you sure? (yes/no): " -r
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        print_status "Rebuild cancelled."
        return 0
    fi
    
    print_status "Destroying existing cluster..."
    ./vagrant-wrapper.sh destroy -f
    
    print_status "Creating new cluster..."
    start_cluster all
}

# Function to connect to a specific node
connect_node() {
    local node=${1:-"controller"}
    
    if [[ ! "$node" =~ ^(controller|node1|node2|node3)$ ]]; then
        print_error "Invalid node: $node"
        print_status "Valid nodes: controller, node1, node2, node3"
        exit 1
    fi
    
    print_status "Connecting to $node..."
    if ./vagrant-wrapper.sh status "$node" | grep -q "running"; then
        ./vagrant-wrapper.sh ssh "$node"
    else
        print_error "$node is not running. Start it first with: $0 start"
        exit 1
    fi
}

# Function to run a command on all nodes
run_on_all() {
    local command="$1"
    local nodes=("controller" "node1" "node2" "node3")
    
    if [[ -z "$command" ]]; then
        print_error "Please provide a command to run"
        exit 1
    fi
    
    print_status "Running command on all nodes: $command"
    
    for node in "${nodes[@]}"; do
        if ./vagrant-wrapper.sh status "$node" | grep -q "running"; then
            print_status "Running on $node..."
            ./vagrant-wrapper.sh ssh "$node" -c "$command" || print_warning "Command failed on $node"
        else
            print_warning "$node is not running, skipping..."
        fi
    done
}

# Function to check cluster health
health_check() {
    print_status "Performing cluster health check..."
    
    # Check if controller is running and accessible
    if ! ./vagrant-wrapper.sh status controller | grep -q "running"; then
        print_error "Controller is not running"
        return 1
    fi
    
    # Check Slurm services on controller
    print_status "Checking Slurm services on controller..."
    if ./vagrant-wrapper.sh ssh controller -c "sudo systemctl is-active --quiet slurmctld"; then
        print_success "slurmctld service is active"
    else
        print_error "slurmctld service is not active"
    fi
    
    if ./vagrant-wrapper.sh ssh controller -c "sudo systemctl is-active --quiet slurmdbd"; then
        print_success "slurmdbd service is active"
    else
        print_error "slurmdbd service is not active"
    fi
    
    # Check compute nodes
    local nodes=("node1" "node2" "node3")
    for node in "${nodes[@]}"; do
        if ./vagrant-wrapper.sh status "$node" | grep -q "running"; then
            print_status "Checking $node..."
            if ./vagrant-wrapper.sh ssh "$node" -c "sudo systemctl is-active --quiet slurmd"; then
                print_success "$node slurmd service is active"
            else
                print_error "$node slurmd service is not active"
            fi
        else
            print_warning "$node is not running"
        fi
    done
    
    # Check cluster connectivity from controller
    print_status "Checking cluster connectivity..."
    if ./vagrant-wrapper.sh ssh controller -c "source /etc/profile.d/slurm.sh && sinfo >/dev/null 2>&1"; then
        print_success "Slurm cluster is responsive"
        ./vagrant-wrapper.sh ssh controller -c "source /etc/profile.d/slurm.sh && sinfo"
    else
        print_error "Slurm cluster is not responsive"
    fi
}

# Function to show logs
show_logs() {
    local service=${1:-"all"}
    local node=${2:-"controller"}
    
    if [[ ! "$node" =~ ^(controller|node1|node2|node3)$ ]]; then
        print_error "Invalid node: $node"
        print_status "Valid nodes: controller, node1, node2, node3"
        exit 1
    fi
    
    if ! ./vagrant-wrapper.sh status "$node" | grep -q "running"; then
        print_error "$node is not running"
        exit 1
    fi
    
    case $service in
        "slurmctld")
            print_status "Showing slurmctld logs from $node..."
            ./vagrant-wrapper.sh ssh "$node" -c "sudo journalctl -u slurmctld -f"
            ;;
        "slurmdbd")
            print_status "Showing slurmdbd logs from $node..."
            ./vagrant-wrapper.sh ssh "$node" -c "sudo journalctl -u slurmdbd -f"
            ;;
        "slurmd")
            print_status "Showing slurmd logs from $node..."
            ./vagrant-wrapper.sh ssh "$node" -c "sudo journalctl -u slurmd -f"
            ;;
        "all")
            if [[ "$node" == "controller" ]]; then
                print_status "Showing all Slurm logs from controller..."
                ./vagrant-wrapper.sh ssh "$node" -c "sudo tail -f /var/log/slurm/*.log"
            else
                print_status "Showing slurmd logs from $node..."
                ./vagrant-wrapper.sh ssh "$node" -c "sudo journalctl -u slurmd -f"
            fi
            ;;
        *)
            print_error "Invalid service: $service"
            print_status "Valid services: slurmctld, slurmdbd, slurmd, all"
            exit 1
            ;;
    esac
}

# Function to show resource usage
show_resources() {
    print_status "Checking resource usage across cluster..."
    
    local nodes=("controller" "node1" "node2" "node3")
    for node in "${nodes[@]}"; do
        if ./vagrant-wrapper.sh status "$node" | grep -q "running"; then
            echo -e "\n${YELLOW}=== $node Resource Usage ===${NC}"
            ./vagrant-wrapper.sh ssh "$node" -c "echo 'CPU and Memory:' && top -bn1 | head -5 && echo && echo 'Disk Usage:' && df -h / && echo 'Memory Details:' && free -h"
        else
            print_warning "$node is not running"
        fi
    done
}

# Function to show help
show_help() {
    echo "Vagrant Slurm Cluster Management Script"
    echo "======================================="
    echo
    echo "Usage: $0 [COMMAND] [OPTIONS]"
    echo
    echo "Commands:"
    echo "  start [all|controller|compute]  Start cluster or specific components"
    echo "  stop [all|controller|compute]   Stop cluster or specific components"
    echo "  restart                         Restart entire cluster"
    echo "  status                          Show cluster status"
    echo "  rebuild                         Destroy and recreate cluster"
    echo "  connect [node]                  SSH to specific node (default: controller)"
    echo "  run <command>                   Run command on all nodes"
    echo "  health                          Perform health check"
    echo "  logs [service] [node]           Show service logs"
    echo "  resources                       Show resource usage"
    echo "  help                            Show this help message"
    echo
    echo "Examples:"
    echo "  $0 start                        # Start entire cluster"
    echo "  $0 start controller             # Start only controller"
    echo "  $0 connect node1                # SSH to node1"
    echo "  $0 run 'uptime'                 # Run uptime on all nodes"
    echo "  $0 logs slurmctld controller    # Show slurmctld logs"
    echo "  $0 health                       # Check cluster health"
    echo
    echo "Quick Test Sequence:"
    echo "  $0 start && sleep 60 && $0 health && $0 connect"
}

# Main script logic
main() {
    check_directory
    
    case "${1:-help}" in
        "start")
            start_cluster "${2:-all}"
            ;;
        "stop")
            stop_cluster "${2:-all}"
            ;;
        "restart")
            restart_cluster
            ;;
        "status")
            show_status
            ;;
        "rebuild")
            rebuild_cluster
            ;;
        "connect")
            connect_node "${2:-controller}"
            ;;
        "run")
            if [[ -z "$2" ]]; then
                print_error "Please provide a command to run"
                exit 1
            fi
            run_on_all "$2"
            ;;
        "health")
            health_check
            ;;
        "logs")
            show_logs "$2" "$3"
            ;;
        "resources")
            show_resources
            ;;
        "help"|"-h"|"--help")
            show_help
            ;;
        *)
            print_error "Unknown command: $1"
            echo
            show_help
            exit 1
            ;;
    esac
}

# Run main function with all arguments
main "$@"
