#!/bin/bash

# Uninstall script for GPU Fan Control
# This script removes the GPU fan control service and cleans up files

set -e  # Exit on any error

echo "Uninstalling GPU Fan Control Service..."

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Service details
SERVICE_NAME="gpu-fan-control.service"
INSTALL_DIR="/usr/local/bin"
SERVICE_DIR="/etc/systemd/system"
SCRIPT_NAME="gpu-fan-control.sh"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" 
   exit 1
fi

# Stop the service if running
echo "Stopping service..."
systemctl stop "$SERVICE_NAME" 2>/dev/null || true

# Disable the service
echo "Disabling service..."
systemctl disable "$SERVICE_NAME" 2>/dev/null || true

# Remove service file
echo "Removing service file..."
rm -f "$SERVICE_DIR/$SERVICE_NAME"

# Remove script
echo "Removing script..."
rm -f "$INSTALL_DIR/$SCRIPT_NAME"

# Reload systemd daemon
echo "Reloading systemd daemon..."
systemctl daemon-reload

echo ""
echo "GPU Fan Control service has been uninstalled successfully!"
echo "Note: Any custom configuration in the script may still exist."