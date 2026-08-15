# GPU Fan Control

Automatic GPU temperature-based fan control for Linux systems.

## Overview

Reads GPU temperature and adjusts motherboard fan speed via PWM. Uses a simple hysteresis algorithm to avoid fan oscillation:

- **Fan max speed**: activates above 65°C
- **Fan min speed**: drops below 35°C
- **Between 35–65°C**: maintains current speed

This prevents the fan from chattering back and forth between speeds during temperature fluctuations.

## Hardware

Configured for:

| Component | Device | Path |
|---|---|---|
| GPU | AMD Instinct MI50 (PCI `0000:03:00`) | `amdgpu` hwmon |
| Temperature | GPU die temp sensor | `hwmonX/temp1_input` |
| Fan controller | it8628 Super I/O | `hwmonY/pwm3` (fan header 3) |

## Variants

### `gpu-fan-control.sh` — Hardcoded paths

Uses fixed hwmon device indices. Simple and fast, but will break if the kernel assigns different hwmon indices after a reboot or kernel update.

### `gpu-fan-control-dynamic.sh` — Dynamic discovery (recommended)

Discovers hwmon devices at runtime:

1. **amdgpu** — matched by PCI address (`0000:03:00`), so it won't pick up your second GPU
2. **it8628** — matched by driver name (only one Super I/O on the system)

Resilient to hwmon index shifts. This is the variant you want if you don't want to fix the script after every kernel update.

## Quick Start

### Install the dynamic version

```bash
sudo cp gpu-fan-control-dynamic.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/gpu-fan-control-dynamic.sh
sudo cp gpu-fan-control-dynamic.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now gpu-fan-control-dynamic.service
```

### Check it's running

```bash
systemctl status gpu-fan-control-dynamic.service
journalctl -u gpu-fan-control-dynamic.service -f
```

### Automated install

```bash
sudo ./install.sh
```

## Configuration

All settings are at the top of the script:

```bash
# Device paths (hardcoded variant)
GPU_TEMP_SENSOR="/sys/class/hwmon/hwmon5/temp1_input"
GPU_FAN_PWM="/sys/class/hwmon/hwmon3/pwm3"
PWM_ENABLE="/sys/class/hwmon/hwmon3/pwm3_enable"

# Fan speeds (0–255 range)
MIN_PWM=90          # Low fan speed
MAX_PWM=210         # High fan speed

# Temperature thresholds
TEMP_THRESHOLD_HIGH=65   # Above this → max speed
TEMP_THRESHOLD_LOW=35    # Below this → min speed
```

## How It Works

```
GPU temp >  65°C  →  fan to MAX_PWM (210)
GPU temp <  35°C  →  fan to MIN_PWM (90)
Between 35–65°C  →  keep current speed (hysteresis)
```

The script:

1. On startup, writes `1` to `pwmX_enable` to set manual mode
2. Enters a 10-second poll loop
3. Reads `temp1_input` (millidegrees Celsius) from the amdgpu hwmon
4. Writes the computed PWM value to the it8628 Super I/O fan header

## Finding Your Devices

Use `hw_scan.sh` to discover hwmon devices and verify the correct GPU/fan paths:

```bash
hw_scan.sh                              # all devices
hw_scan.sh --pci 0000:03:00             # just the MI50
```

This shows GPU names, PCI addresses, temps, fan RPM, and all motherboard fan headers with PWM values and control mode.

If you need to adapt this to different hardware, update the device paths at the top of the script accordingly.

## Troubleshooting

### Fan not spinning
- Check that `pwmX_enable` is set to `1` (manual mode)
- Verify the fan is plugged into the correct motherboard header
- Read the fan RPM directly: `cat /sys/class/hwmon/hwmon3/fan3_input`

### Service failing after reboot
The kernel assigns hwmon indices dynamically. If your hardcoded script breaks, switch to the dynamic variant.

### Verify the correct device
```bash
# What temp does the amdgpu report?
cat /sys/class/hwmon/hwmon5/temp1_input   # millidegrees

# What's the fan doing?
cat /sys/class/hwmon/hwmon3/pwm3            # PWM duty cycle
cat /sys/class/hwmon/hwmon3/pwm3_enable     # 1=manual, 2=auto
cat /sys/class/hwmon/hwmon3/fan3_input      # RPM
```

## License

MIT License — see [LICENSE](LICENSE)

Copyright (c) 2026 Chris Harris
