#!/bin/bash
# Ultra-minimal desktop environment script for OnDemand VNC sessions
# This script will work on any node with basic X11 packages installed

set -x
exec > >(tee -a /tmp/minimal-desktop-$(date +%s).log) 2>&1

echo "Starting minimal desktop environment"
echo "DISPLAY=$DISPLAY"
echo "USER=$USER"
echo "PWD=$PWD"

# Ensure X environment is properly set up
export XAUTHORITY="${HOME}/.Xauthority"
export DISPLAY="${DISPLAY:-:1}"

# Ensure we have a proper Xauthority file
touch "${HOME}/.Xauthority"
chmod 600 "${HOME}/.Xauthority"

# Verify X11 packages are installed
if ! command -v xterm >/dev/null 2>&1; then
  echo "ERROR: xterm not found - X11 packages may not be installed correctly"
  echo "Required packages: xorg xterm twm x11-apps"
  echo "Installing essential X packages..."
  sudo apt-get update -y
  sudo apt-get install -y xorg xterm twm x11-apps
fi

# Start a very minimal window manager setup
xsetroot -solid "#333366" 2>/dev/null || echo "xsetroot failed"

# Start a terminal with a useful diagnostic display
xterm -geometry 80x24+10+10 -title "Terminal" &
xterm -geometry 100x16+10+300 -title "System Information" -e "
echo -e '\n=== VNC Session Info ===\n'
echo 'DISPLAY=$DISPLAY'
echo 'Date: $(date)'
echo 'Hostname: $(hostname)'
echo -e '\n=== System Info ===\n'
echo 'System: $(uname -a)'
echo -e '\n=== Available Desktop Environments ===\n'
dpkg -l | grep -E 'xfce|kde|gnome|fluxbox|openbox|twm'
echo -e '\n=== DISPLAY Variable Check ===\n'
echo \$DISPLAY
echo -e '\n=== X11 Authentication ===\n'
xauth list
echo -e '\n=== X11 Connection Test ===\n'
xdpyinfo | head -5 || echo 'X11 connection test failed'
echo -e '\nThis terminal will remain open for the duration of your VNC session...'
sleep 3600" &

# Try each window manager until one works
for wm in fluxbox openbox twm; do
  if command -v $wm >/dev/null 2>&1; then
    echo "Starting window manager: $wm"
    exec $wm
  fi
done

# If we get here, no window manager was found - just keep running
echo "No window manager found! Using bare X11 session."
sleep infinity
