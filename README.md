# GPU Fan Control Script Documentation

## Overview
This script controls system fans based on GPU temperature. It provides automatic temperature-based fan control by reading GPU temperature sensors and adjusting system fan PWM values accordingly.

## Features
- Automatic GPU temperature monitoring (AMD MI50)
- Two-wavelength hysteresis fan control (65°C / 35°C)
- Two script variants: hardcoded paths or dynamic hwmon discovery
- Systemd service integration for automatic startup
- Installation and uninstallation scripts

## Hardware
This script is configured for:
- **GPU**: AMD Instinct MI50 (PCI 0000:03:00)
- **Temp sensor**: amdgpu hwmon device
- **Fan controller**: it8628 Super I/O chip (motherboard fan header 3)

## Variants

### gpu-fan-control.sh (hardcoded)
Uses fixed hwmon device indices. Simpler and faster startup, but will break if the kernel assigns different hwmon indices after a reboot or update.

### gpu-fan-control-dynamic.sh (recommended)
Dynamically discovers hwmon devices at startup by matching:
- amdgpu → PCI address `0000:03:00` (the MI50)
- it8628 → driver name (Super I/O fan controller)
Resilient to hwmon index shifts — recommended if you want to avoid future breakage.

## Requirements
- Linux system with hardware monitoring support
- GPU with hwmon sensor (NVIDIA, AMD, or other)
- Motherboard with PWM fan control headers
- Root privileges to access sensor files

## Installation

### Automated Installation (recommended)
Run the installation script as root:
```bash
sudo ./install.sh
```

### Install Dynamic Version
To use the dynamic discovery script instead:
```bash
sudo cp gpu-fan-control-dynamic.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/gpu-fan-control-dynamic.sh
sudo cp gpu-fan-control-dynamic.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now gpu-fan-control-dynamic.service
```

### Manual Installation
1. Copy script to `/usr/local/bin/gpu-fan-control.sh`
2. Make executable: `sudo chmod +x /usr/local/bin/gpu-fan-control.sh`
3. Create systemd service:
```ini
[Unit]
Description=GPU Fan Control Service
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/local/bin/gpu-fan-control.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```
4. Enable service: `sudo systemctl enable gpu-fan-control.service`

### Automated Installation
Run the installation script:
```bash
sudo ./install.sh
```

### Automated Uninstallation
Run the uninstallation script:
```bash
sudo ./uninstall.sh
```

## Configuration Variables

### Basic Settings
- `GPU_TEMP_SENSOR`: Path to the GPU temperature sensor
- `GPU_FAN_PWM`: Path to the fan PWM control
- `PWM_ENABLE`: Path to the PWM enable control (set to 1 for manual mode)

### Temperature Thresholds
- `TEMP_THRESHOLD_HIGH`: Fan max speed activates above this (default: 65°C)
- `TEMP_THRESHOLD_LOW`: Fan drops to min speed below this (default: 35°C)

### PWM Control Settings
- `MIN_PWM`: Minimum PWM value for low fan speed (default: 90)
- `MAX_PWM`: Maximum PWM value for high fan speed (default: 210)

The hysteresis window (35°C–65°C) prevents the fan from oscillating between speeds.

## Sensor Detection

The script includes automatic sensor detection functions that identify available sensors on your system. This helps ensure correct configuration without manual path identification.

## Testing Functions

### test_fans()
This function allows manual testing of fan operation at various PWM values to determine:
- Minimum effective PWM value
- Maximum PWM value
- Fan behavior across different speeds

## Usage

### Normal Operation
```bash
sudo ./gpu-fan-control.sh
```

### Command Line Options
```bash
sudo ./gpu-fan-control.sh --detect-sensors    # Detect sensors
sudo ./gpu-fan-control.sh --test-fans         # Test fan operation
sudo ./gpu-fan-control.sh --help              # Show help
```

## Finding Available Sensors

Use these commands to locate sensors on your system:

```bash
# List all hardware monitor directories
ls -la /sys/class/hwmon/

# Check all sensors and their values
for i in /sys/class/hwmon/hwmon*; do
  if [ -d "$i" ]; then
    echo "=== $i ==="
    if [ -f "$i/name" ]; then
      echo "Name: $(cat $i/name)"
    fi
    if [ -f "$i/temp1_input" ]; then
      echo "Temp1: $(cat $i/temp1_input) m°C"
    fi
    if [ -f "$i/pwm1" ]; then
      echo "PWM1: $(cat $i/pwm1)"
    fi
    if [ -f "$i/pwm2" ]; then
      echo "PWM2: $(cat $i/pwm2)"
    fi
    echo
  fi
done

# Identify GPU sensors specifically
for i in /sys/class/hwmon/hwmon*; do
  if [ -d "$i" ]; then
    if [ -f "$i/name" ]; then
      name=$(cat $i/name)
      if [[ "$name" == *"amdgpu"* ]] || [[ "$name" == *"nvidia"* ]] || [[ "$name" == *"radeon"* ]]; then
        echo "Found GPU sensor at $i"
        echo "Name: $name"
        if [ -f "$i/temp1_input" ]; then
          echo "Temp1: $(cat $i/temp1_input) m°C"
        fi
      fi
    fi
  fi
done

# Check motherboard PWM controls
for i in /sys/class/hwmon/hwmon*; do
  if [ -d "$i" ]; then
    if [ -f "$i/name" ]; then
      name=$(cat $i/name)
      if [[ "$name" == *"it8628"* ]] || [[ "$name" == *"pwm"* ]]; then
        echo "Found PWM controller at $i"
        echo "Name: $name"
        if [ -f "$i/pwm1" ]; then
          echo "PWM1: $(cat $i/pwm1)"
        fi
        if [ -f "$i/pwm2" ]; then
          echo "PWM2: $(cat $i/pwm2)"
        fi
      fi
    fi
  fi
done
```

## PWM Value Ranges

PWM values typically range from 0-255:
- 0: Fan off
- 30-50: Very low speed (idle)
- 100-150: Low to medium speed
- 200-255: High speed (full)
- The specific range and response may vary depending on your fan hardware

## Troubleshooting

### Common Issues
1. **Permissions**: Ensure script is run with `sudo` privileges
2. **Sensor Paths**: Confirm sensor paths exist using detection commands
3. **Fan Headers**: Verify your motherboard supports PWM control
4. **Manual Mode**: Ensure PWM is in manual mode (`pwmX_enable` set to 1)
5. **hwmon index shifts**: If the hardcoded script breaks after a kernel update, switch to the dynamic version

### hwmon Index Shifts
The kernel assigns hwmon indices dynamically. After a kernel update or module reload, indices can change (e.g., `hwmon1` → `hwmon3`). The **dynamic script** handles this automatically — if the hardcoded script stops working, see the install instructions above for the dynamic version.

### Sensor Detection Failure
If sensors aren't found:
- Check that hardware monitoring modules are loaded (`sudo modprobe hwmon`)
- Verify hardware is properly detected (`lspci | grep VGA`)
- Confirm correct paths using the detection commands above
- Use the dynamic script variant which discovers devices automatically

## Customization

To customize for different hardware:
1. Modify `GPU_TEMP_SENSOR` to point to your GPU sensor
2. Modify `GPU_FAN_PWM` to point to your fan header
3. Adjust temperature thresholds (`MIN_TEMP`, `MAX_TEMP`)
4. Adjust PWM range (`MIN_PWM`, `MAX_PWM`) based on testing

## System Integration

The script includes systemd service integration for automatic startup. The installation script will set this up automatically, or you can manually create the service file as shown in the installation section.

## Support

For issues or questions, please contact the author or submit a bug report to the project repository.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

Copyright (c) 2026 Chris Harris