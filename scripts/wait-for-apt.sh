#!/bin/bash
# wait-for-apt.sh - Utility to wait for apt/dpkg locks to be released

# Function to check if apt/dpkg is locked
apt_is_locked() {
    # Check if apt/dpkg is locked
    if lsof /var/lib/dpkg/lock-frontend &>/dev/null || lsof /var/lib/apt/lists/lock &>/dev/null || 
       lsof /var/lib/dpkg/lock &>/dev/null || lsof /var/cache/apt/archives/lock &>/dev/null; then
        return 0  # Locks exist
    else
        return 1  # No locks
    fi
}

# Function to get the process holding the lock
get_lock_process() {
    local pid process_name
    
    # Try to find the process holding the frontend lock
    pid=$(lsof /var/lib/dpkg/lock-frontend 2>/dev/null | awk 'NR>1 {print $2}')
    
    if [ -n "$pid" ]; then
        process_name=$(ps -p $pid -o comm=)
        echo "$process_name (PID: $pid)"
    else
        echo "Unknown process"
    fi
}

# Main function to wait for apt/dpkg locks to be released
wait_for_apt_locks() {
    local max_wait=${1:-300}  # Default timeout of 300 seconds (5 minutes)
    local wait_time=0
    local lock_process=""
    
    echo "🔍 Checking for apt/dpkg locks..."
    
    if ! apt_is_locked; then
        echo "✅ No apt/dpkg locks detected. Proceeding with installation."
        return 0
    fi
    
    lock_process=$(get_lock_process)
    echo "⚠️ apt/dpkg is locked by $lock_process"
    echo "⏳ Waiting for locks to be released (timeout: ${max_wait}s)..."
    
    while apt_is_locked; do
        if [ $wait_time -ge $max_wait ]; then
            echo "❌ Timeout reached. apt/dpkg is still locked after ${max_wait} seconds."
            echo "🛑 You may need to wait for automatic updates to complete or run:"
            echo "   sudo killall apt apt-get dpkg unattended-upgr"
            return 1
        fi
        
        # Every 30 seconds, show an update
        if [ $((wait_time % 30)) -eq 0 ]; then
            lock_process=$(get_lock_process)
            echo "⏳ Still waiting for $lock_process to release apt/dpkg locks... (${wait_time}/${max_wait}s)"
        fi
        
        sleep 5
        wait_time=$((wait_time + 5))
    done
    
    echo "✅ apt/dpkg locks have been released. Proceeding with installation."
    
    # Wait an additional 5 seconds to ensure locks are fully released
    sleep 5
    return 0
}

# If script is run directly (not sourced), execute the main function
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    wait_for_apt_locks "$@"
    exit $?
fi
