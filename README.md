# GPU Fan Control

A tool for controlling GPU fan speeds on Linux systems.

## Features

- Automatic GPU fan speed control
- Support for NVIDIA and AMD GPUs
- Service integration for automatic startup
- Configuration management

## Installation

```bash
# Clone the repository
git clone <repository-url>
cd gpu-fan-control

# Make the script executable
chmod +x gpu-fan-control.sh

# Install the service
sudo cp gpu-fan-control.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable gpu-fan-control.service
```

## Usage

```bash
# Start the service
sudo systemctl start gpu-fan-control.service

# Check service status
sudo systemctl status gpu-fan-control.service

# View logs
sudo journalctl -u gpu-fan-control.service
```

## Configuration

Edit the script to adjust fan speed settings for your GPU.