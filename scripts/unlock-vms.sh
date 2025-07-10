#!/bin/bash
# Helper script to remove stale Vagrant locks for libvirt VMs

echo "🔓 Vagrant VM Lock Remover"
echo "This script will remove stale Vagrant locks for libvirt VMs."
echo

LOCK_DIR="${HOME}/.vagrant.d/locks/machine"

if [ ! -d "$LOCK_DIR" ]; then
  echo "❌ Lock directory does not exist: $LOCK_DIR"
  exit 1
fi

# List all locks
echo "Current locks:"
find "$LOCK_DIR" -type f | sort

# Ask for confirmation
echo
echo "Would you like to remove all locks? (y/n)"
read -r response
if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
  find "$LOCK_DIR" -type f -delete
  echo "✅ All locks removed."
else
  echo "Operation cancelled."
fi

echo
echo "You can now run 'vagrant up node1' (or other VM) to continue."
