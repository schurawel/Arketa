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
