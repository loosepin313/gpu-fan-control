#!/bin/bash

# Install script for GPU Fan Control
# Installs the control script, config file and systemd service.

set -e  # Exit on any error

echo "Installing GPU Fan Control Service..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INSTALL_DIR="/usr/local/bin"
SERVICE_DIR="/etc/systemd/system"
CONF_DIR="/etc"
SCRIPT_NAME="gpu-fan-control.sh"
SERVICE_NAME="gpu-fan-control.service"
CONF_NAME="gpu-fan-control.conf"

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

# Copy control script
echo "Copying script to $INSTALL_DIR..."
cp "$SCRIPT_DIR/$SCRIPT_NAME" "$INSTALL_DIR/$SCRIPT_NAME"
chmod +x "$INSTALL_DIR/$SCRIPT_NAME"

# Copy service file
echo "Copying service file to $SERVICE_DIR..."
cp "$SCRIPT_DIR/$SERVICE_NAME" "$SERVICE_DIR/$SERVICE_NAME"

# Copy config file, but never overwrite an existing one
if [ -f "$CONF_DIR/$CONF_NAME" ]; then
    echo "Config $CONF_DIR/$CONF_NAME already exists - leaving it alone."
    echo "Compare against $SCRIPT_DIR/$CONF_NAME if you expected new options."
else
    echo "Installing default config to $CONF_DIR/$CONF_NAME ..."
    cp "$SCRIPT_DIR/$CONF_NAME" "$CONF_DIR/$CONF_NAME"
    echo "  >> EDIT THIS FIRST: the shipped example is tuned for one specific"
    echo "     board/GPU pair. Run fan_probe.sh to find your PWM_CHANNEL."
fi

# Install the probe/calibration helpers
echo "Installing helpers to $INSTALL_DIR ..."
cp "$SCRIPT_DIR/fan_probe.sh" "$INSTALL_DIR/fan_probe.sh"
chmod +x "$INSTALL_DIR/fan_probe.sh"
for tool in "$SCRIPT_DIR"/tools/*.sh; do
    [ -e "$tool" ] || continue
    cp "$tool" "$INSTALL_DIR/$(basename "$tool")"
    chmod +x "$INSTALL_DIR/$(basename "$tool")"
done

echo "Reloading systemd daemon..."
systemctl daemon-reload

echo "Enabling and starting service..."
systemctl enable "$SERVICE_NAME"
systemctl start "$SERVICE_NAME"

echo "Verifying installation..."
if systemctl is-active --quiet "$SERVICE_NAME"; then
    echo "GPU Fan Control service installed and running."
    echo
    echo "First-run check - confirm the fan actually responds:"
    echo "  journalctl -u $SERVICE_NAME -n 20 --no-pager"
    echo "If the log says 'fanN reads 0 RPM', the PWM_CHANNEL in"
    echo "/etc/$CONF_NAME is the wrong header. Run: fan_probe.sh"
    echo
    systemctl status "$SERVICE_NAME" --no-pager || true
else
    echo "Warning: service may not be running. Check with: systemctl status $SERVICE_NAME"
fi

echo ""
echo "Installation complete!"
echo "To view logs: journalctl -u $SERVICE_NAME -f"
echo "To uninstall: run $SCRIPT_DIR/uninstall.sh"
