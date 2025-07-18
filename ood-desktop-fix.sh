#!/bin/bash
# OnDemand VNC Desktop Diagnostic and Repair Script
# Fixes issues with VNC desktop sessions in Open OnDemand

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=======================================================${NC}"
echo -e "${BLUE}  Open OnDemand VNC Desktop Diagnostic and Repair Tool  ${NC}"
echo -e "${BLUE}=======================================================${NC}"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo -e "${YELLOW}This script should be run as root to properly fix all issues.${NC}"
  echo -e "${YELLOW}Please run with: sudo $0${NC}"
  exit 1
fi

echo -e "${BLUE}[1/7] Checking for required packages...${NC}"
# Array of packages to install
PACKAGES=(
  tigervnc-standalone-server
  tigervnc-common
  tigervnc-tools
  websockify
  xauth
  xterm
  xvfb
  twm
  fluxbox
  openbox
  x11-xserver-utils
  dbus-x11
  libnotify-bin
  zenity
  libpam-systemd
  python3-websockify
)

# Install the minimal set of packages first
apt-get update
apt-get install -y ${PACKAGES[@]}

echo -e "${BLUE}[2/7] Installing a desktop environment that works...${NC}"
# Try to install XFCE (preferred) but also install a minimal fallback
if ! dpkg -l | grep -q xfce4-session; then
  echo -e "${YELLOW}Installing XFCE desktop environment...${NC}"
  apt-get install -y xfce4 xfce4-goodies xfce4-terminal
fi

# Make sure we have a fallback window manager 
if ! dpkg -l | grep -q fluxbox; then
  echo -e "${YELLOW}Installing Fluxbox as fallback window manager...${NC}"
  apt-get install -y fluxbox
fi

echo -e "${BLUE}[3/7] Creating universal xstartup script for VNC...${NC}"
cat > /etc/xstartup-universal.sh << 'EOF'
#!/bin/bash
# Universal xstartup script for VNC that tries multiple window managers

# Set up essential X environment variables
export XAUTHORITY="$HOME/.Xauthority"
export DISPLAY=${DISPLAY:-:1}
export XDG_SESSION_TYPE=x11
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"

# Create a log file for debugging
LOG_FILE="$HOME/.vnc/xstartup-universal.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "====== VNC xstartup: $(date) ======"
echo "DISPLAY=$DISPLAY"
echo "USER=$(whoami)"
echo "XAUTHORITY=$XAUTHORITY"
echo "PATH=$PATH"
echo "HOME=$HOME"

# Start DBUS if not already running
if [ -z "$DBUS_SESSION_BUS_ADDRESS" ]; then
  echo "Starting dbus session"
  mkdir -p $HOME/.vnc
  dbus-launch --sh-syntax > $HOME/.vnc/dbus.env
  source $HOME/.vnc/dbus.env
  echo "DBUS_SESSION_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS"
fi

# Start simple X utilities that are likely to work
xsetroot -solid grey
xrdb -merge $HOME/.Xresources 2>/dev/null || true

# Ensure .Xauthority exists and has proper permissions
touch $HOME/.Xauthority
chmod 600 $HOME/.Xauthority
echo "X authority file set up"

# Try to start a window manager in this order of preference
WM_LIST=("xfce4-session" "fluxbox" "openbox" "twm")

for wm in "${WM_LIST[@]}"; do
  if command -v $wm >/dev/null; then
    echo "Attempting to start $wm..."
    case $wm in
      xfce4-session)
        # Clear any existing XFCE sessions
        rm -rf $HOME/.cache/sessions/* 2>/dev/null || true
        # Start with a clean XFCE configuration
        mkdir -p $HOME/.config/xfce4/xfconf/xfce-perchannel-xml/
        # Start xfce4-session
        xfce4-session || echo "xfce4-session failed"
        ;;
      fluxbox)
        # Start fluxbox - a lightweight window manager
        fluxbox -log $HOME/.vnc/fluxbox.log &
        # Add a terminal for usability
        xterm -geometry 80x24+10+10 -title "Terminal" &
        # Keep script running
        wait
        ;;
      openbox)
        # Start openbox - another lightweight window manager
        openbox-session || echo "openbox-session failed"
        ;;
      twm)
        # Start twm - the most basic window manager
        xterm -geometry 80x24+10+10 -title "Terminal" &
        twm || echo "twm failed"
        ;;
    esac
    # If we got here, we found and tried to start a window manager
    # Break loop so we don't try multiple window managers
    break
  else
    echo "$wm not found, trying next window manager..."
  fi
done
EOF

chmod +x /etc/xstartup-universal.sh

echo -e "${BLUE}[4/7] Creating system-wide VNC configuration...${NC}"

mkdir -p /etc/tigervnc
cat > /etc/tigervnc/vncserver-config-defaults << 'EOF'
## TigerVNC Server default configuration
# Modified for OnDemand compatibility

# Use the universal xstartup script
session=custom
custom=/etc/xstartup-universal.sh

# Security options
securitytypes=vncauth,tlsvnc
desktop=OnDemand VNC Desktop
alwaysshared
localhost
EOF

echo -e "${BLUE}[5/7] Modifying OnDemand desktop script templates...${NC}"

# Find the OnDemand installation path
OOD_PATH=$(find /var/www/ood -name "bc_desktop" -type d | head -1)
if [ -z "$OOD_PATH" ]; then
  echo -e "${RED}ERROR: Could not find OnDemand installation path${NC}"
  exit 1
fi

echo "OnDemand path: $OOD_PATH"

# Update the main desktop script to use our universal xstartup script
DESKTOP_PATH="$OOD_PATH/template/desktops"
mkdir -p "$DESKTOP_PATH"

# Create new universal desktop script
cat > "$DESKTOP_PATH/universal.sh" << 'EOF'
#!/bin/bash
# Universal desktop script that tries multiple window managers

# Debug information
echo "Starting universal desktop launcher"
echo "DISPLAY=$DISPLAY"
echo "USER=$(whoami)"
echo "PATH=$PATH"

# Run the system-wide universal xstartup script
if [ -f "/etc/xstartup-universal.sh" ]; then
  echo "Running system universal xstartup script"
  exec /etc/xstartup-universal.sh
else
  echo "Universal xstartup script not found, using fallback"
  # Fallback to a minimal X session
  export DISPLAY=${DISPLAY:-:1}
  xterm -geometry 80x24+10+10 -title "OnDemand Terminal" &
  exec twm
fi
EOF

chmod +x "$DESKTOP_PATH/universal.sh"

echo -e "${BLUE}[6/7] Updating OnDemand configuration to use universal desktop...${NC}"

# Update form.yml to add the universal desktop option
FORM_PATH="$OOD_PATH/form.yml"
if [ -f "$FORM_PATH" ]; then
  cp "$FORM_PATH" "$FORM_PATH.backup"
  
  # Check if Universal Desktop is already in the file
  if ! grep -q "Universal Desktop" "$FORM_PATH"; then
    # Add Universal Desktop as the first option
    sed -i 's/options:/options:\n      - ["Universal Desktop (Most Compatible)", "universal"]/' "$FORM_PATH"
    # Set it as default
    sed -i 's/value: "xfce"/value: "universal"/' "$FORM_PATH"
    echo -e "${GREEN}Added Universal Desktop option to form.yml${NC}"
  else
    echo -e "${YELLOW}Universal Desktop option already exists in form.yml${NC}"
  fi
else
  echo -e "${RED}ERROR: Could not find form.yml at $FORM_PATH${NC}"
fi

echo -e "${BLUE}[7/7] Testing VNC server configuration...${NC}"

# Test the VNC server configuration
VNC_USER=$(grep -v "^#" /etc/passwd | grep -v "nologin\|false" | tail -1 | cut -d: -f1)
echo -e "${YELLOW}Testing VNC server with user $VNC_USER...${NC}"

# Create a test directory
TEST_DIR="/tmp/vnc-test"
mkdir -p "$TEST_DIR"
chown $VNC_USER:$VNC_USER "$TEST_DIR"

# Generate a test script
cat > "$TEST_DIR/test-vnc.sh" << 'EOF'
#!/bin/bash
set -e

# Clean up function
cleanup() {
  echo "Cleaning up..."
  vncserver -kill :42 >/dev/null 2>&1 || true
  rm -f ~/.vnc/passwd
  exit
}

trap cleanup EXIT

# Create VNC password
mkdir -p ~/.vnc
echo "password" | vncpasswd -f > ~/.vnc/passwd
chmod 600 ~/.vnc/passwd

# Start VNC server on a test display
echo "Starting VNC server on display :42..."
vncserver :42 -localhost no -geometry 1024x768 -depth 24

# Wait a bit
echo "VNC server started. Waiting 5 seconds..."
sleep 5

# Check if server is running
if ps aux | grep -v grep | grep -q "Xvnc.*:42"; then
  echo "VNC server is running correctly!"
else
  echo "VNC server failed to start!"
  exit 1
fi

# Kill the VNC server
echo "Killing VNC server..."
vncserver -kill :42
echo "Test completed successfully!"
EOF

chmod +x "$TEST_DIR/test-vnc.sh"
chown $VNC_USER:$VNC_USER "$TEST_DIR/test-vnc.sh"

# Run the test as the selected user
sudo -u $VNC_USER bash -c "cd $TEST_DIR && ./test-vnc.sh"

echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN}  OnDemand VNC Desktop fixes applied successfully!  ${NC}"
echo -e "${GREEN}====================================================${NC}"
echo ""
echo -e "${BLUE}To use the fixed desktop:${NC}"
echo "1. Log in to OnDemand web interface"
echo "2. Start a new desktop session using the 'Universal Desktop' option"
echo "3. If issues persist, check the logs at ~/.vnc/xstartup-universal.log"
echo ""
echo -e "${YELLOW}You may need to restart Apache to apply all changes:${NC}"
echo "  systemctl restart apache2"
echo ""
