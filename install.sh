#!/bin/bash

# Install script for Video Card Fan Control
# This script installs the video card fan control service and configures it to run at boot

set -e  # Exit on any error

echo "Installing Video Card Fan Control Service..."

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Create installation directory
INSTALL_DIR="/usr/local/bin"
SERVICE_DIR="/etc/systemd/system"
SCRIPT_NAME="gpu-fan-control.sh"
SERVICE_NAME="gpu-fan-control.service"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" 
   exit 1
fi

# Copy script to installation directory
echo "Copying script to $INSTALL_DIR..."
cp "$SCRIPT_DIR/gpu-fan-control.sh" "$INSTALL_DIR/$SCRIPT_NAME"
chmod +x "$INSTALL_DIR/$SCRIPT_NAME"

# Copy service file
echo "Copying service file to $SERVICE_DIR..."
cp "$SCRIPT_DIR/gpu-fan-control.service" "$SERVICE_DIR/$SERVICE_NAME"

# Reload systemd daemon
echo "Reloading systemd daemon..."
systemctl daemon-reload

# Enable and start the service
echo "Enabling and starting service..."
systemctl enable "$SERVICE_NAME"
systemctl start "$SERVICE_NAME"

# Verify installation
echo "Verifying installation..."
if systemctl is-active --quiet "$SERVICE_NAME"; then
    echo "Video Card Fan Control service installed and running successfully!"
    echo "Service status:"
    systemctl status "$SERVICE_NAME" --no-pager
else
    echo "Warning: Service may not be running. Check with: systemctl status $SERVICE_NAME"
fi

echo ""
echo "Installation complete!"
echo "To view logs: journalctl -u $SERVICE_NAME -f"
echo "To uninstall: run $SCRIPT_DIR/uninstall.sh"