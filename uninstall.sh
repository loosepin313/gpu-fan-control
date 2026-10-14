#!/bin/bash

# Uninstall script for GPU Fan Control
# Removes the service, script and helpers. The config file is kept unless
# --purge is given.

set -e  # Exit on any error

PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

echo "Uninstalling GPU Fan Control Service..."

SERVICE_NAME="gpu-fan-control.service"
LEGACY_SERVICE_NAME="gpu-fan-control-dynamic.service"
INSTALL_DIR="/usr/local/bin"
SERVICE_DIR="/etc/systemd/system"
SCRIPT_NAME="gpu-fan-control.sh"
CONF_NAME="gpu-fan-control.conf"

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

echo "Stopping service..."
systemctl stop "$SERVICE_NAME" 2>/dev/null || true
systemctl stop "$LEGACY_SERVICE_NAME" 2>/dev/null || true

echo "Disabling service..."
systemctl disable "$SERVICE_NAME" 2>/dev/null || true
systemctl disable "$LEGACY_SERVICE_NAME" 2>/dev/null || true

echo "Removing service files..."
rm -f "$SERVICE_DIR/$SERVICE_NAME"
rm -f "$SERVICE_DIR/$LEGACY_SERVICE_NAME"

echo "Removing scripts..."
rm -f "$INSTALL_DIR/$SCRIPT_NAME"
rm -f "$INSTALL_DIR/gpu-fan-control-dynamic.sh"
rm -f "$INSTALL_DIR/fan_probe.sh"
rm -f "$INSTALL_DIR/calibrate_fan.sh"
rm -f "$INSTALL_DIR/loadgen.sh"

if [ "$PURGE" -eq 1 ]; then
    echo "Removing config /etc/$CONF_NAME (--purge)..."
    rm -f "/etc/$CONF_NAME"
else
    echo "Keeping /etc/$CONF_NAME (use --purge to remove it)"
fi

echo "Reloading systemd daemon..."
systemctl daemon-reload

echo ""
echo "GPU Fan Control service has been uninstalled."
echo "Note: the fan channel is left in whatever mode the script last set."
echo "      Re-run your BIOS fan curve or the Super I/O's auto mode if you"
echo "      want hardware control back."
