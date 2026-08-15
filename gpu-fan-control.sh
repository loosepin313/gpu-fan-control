#!/bin/bash
# Simple GPU Fan Control Script with Hysteresis
# Uses hardcoded device paths as specified
# MI50 (03:00.0): amdgpu temp sensor on it8628 Super I/O fan controller

# --- Hwmon scan function ---
# Use: sudo ./gpu-fan-control.sh --scan  (or run hw_scan.sh for more detail)
scan_hwmon() {
  echo "=== Hardware Monitor Devices ==="
  echo
  for h in /sys/class/hwmon/hwmon*; do
    name=$(cat "$h/name" 2>/dev/null)
    [ -z "$name" ] && continue
    real_path=$(readlink -f "$h" 2>/dev/null)
    pci=$(echo "$real_path" | grep -oP '0000:[0-9a-f]{4}:[0-9a-f]{2}\.[0-9a-f]' | head -1)
    temp=$(cat "$h/temp1_input" 2>/dev/null)
    fan=$(cat "$h/fan1_input" 2>/dev/null)
    case "$name" in
      amdgpu|nvidia*|radeon*)
        temp_c=$((temp / 1000))
        echo "[GPU]  $h  ($name)"
        [ -n "$pci" ] && echo "       PCI: $pci"
        [ -n "$temp" ] && echo "       Temp: ${temp_c}°C"
        [ -n "$fan" ] && echo "       Fan1: ${fan} RPM"
        ;;
      it8628|it87*|nct677*|w8362*)
        echo "[I/O]  $h  ($name)"
        for i in 1 2 3 4 5; do
          fi_val=$(cat "$h/fan${i}_input" 2>/dev/null)
          pi_val=$(cat "$h/pwm${i}" 2>/dev/null)
          pie_val=$(cat "$h/pwm${i}_enable" 2>/dev/null)
          [ -n "$fi_val" ] || [ -n "$pi_val" ] && echo "       Fan${i}: ${fi_val:-N/A} RPM | PWM${i}: ${pi_val:-N/A} (mode: ${pie_val:-auto})"
        done
        ;;
      nvme*)
        temp_c=$((temp / 1000))
        echo "[NVMe] $h  ($name)"
        [ -n "$pci" ] && echo "       PCI: $pci"
        [ -n "$temp" ] && echo "       Temp: ${temp_c}°C"
        ;;
      k10temp|zenpower*)
        temp_c=$((temp / 1000))
        echo "[CPU]  $h  ($name)"
        [ -n "$temp" ] && echo "       Temp: ${temp_c}°C"
        ;;
      *)
        echo "[      ] $h  ($name)"
        ;;
    esac
    echo
  done
}

# CLI: scan mode
if [ "${1}" = "--scan" ] || [ "${1}" = "-s" ]; then
  scan_hwmon
  exit 0
fi

# Device configuration
# amdgpu temp is at hwmon5, fan controlled via it8628 Super I/O at hwmon3/pwm3
GPU_TEMP_SENSOR="/sys/class/hwmon/hwmon5/temp1_input"
GPU_FAN_PWM="/sys/class/hwmon/hwmon3/pwm3"
PWM_ENABLE="/sys/class/hwmon/hwmon3/pwm3_enable"

# Fan control settings
MIN_PWM=90
MAX_PWM=210
TEMP_THRESHOLD_HIGH=65
TEMP_THRESHOLD_LOW=35

# Function to set PWM to manual mode
set_manual_mode() {
    if [ -w "$PWM_ENABLE" ]; then
        echo 1 > "$PWM_ENABLE"
        echo "Set PWM to manual mode"
    else
        echo "ERROR: Cannot write to PWM enable file: $PWM_ENABLE"
        exit 1
    fi
}

# Function to get GPU temperature
get_gpu_temp() {
    if [ -f "$GPU_TEMP_SENSOR" ]; then
        temp=$(cat "$GPU_TEMP_SENSOR")
        # Convert from millidegrees to degrees Celsius
        echo $((temp / 1000))
    else
        echo 0
    fi
}

# Function to set fan speed
set_fan_speed() {
    local speed=$1
    if [ -w "$GPU_FAN_PWM" ]; then
        echo $speed > "$GPU_FAN_PWM"
        echo "Set fan speed to $speed"
    else
        echo "ERROR: Cannot write to PWM file: $GPU_FAN_PWM"
        exit 1
    fi
}

# Initialize system
echo "Initializing GPU fan control..."
set_manual_mode
set_fan_speed $MIN_PWM

# Main control loop
echo "Starting fan control loop..."
echo "High temp threshold: ${TEMP_THRESHOLD_HIGH}°C"
echo "Low temp threshold: ${TEMP_THRESHOLD_LOW}°C"
echo "Monitoring: $GPU_TEMP_SENSOR"

# State tracking
fan_state="low"  # "low" or "high"

while true; do
    current_temp=$(get_gpu_temp)
    
    if [ $current_temp -gt 0 ]; then
        echo "$(date): GPU Temp: ${current_temp}°C"
        
        # If temperature is above high threshold and fan is not already at high speed
        if [ $current_temp -ge $TEMP_THRESHOLD_HIGH ] && [ "$fan_state" = "low" ]; then
            echo "Temperature above ${TEMP_THRESHOLD_HIGH}°C - setting fan to max speed"
            set_fan_speed $MAX_PWM
            fan_state="high"
        # If temperature is below low threshold and fan is at high speed
        elif [ $current_temp -le $TEMP_THRESHOLD_LOW ] && [ "$fan_state" = "high" ]; then
            echo "Temperature below ${TEMP_THRESHOLD_LOW}°C - setting fan to minimum speed"
            set_fan_speed $MIN_PWM
            fan_state="low"
        # If temperature is below low threshold but fan is already at low speed
        elif [ $current_temp -le $TEMP_THRESHOLD_LOW ] && [ "$fan_state" = "low" ]; then
            echo "Temperature below ${TEMP_THRESHOLD_LOW}°C - setting fan to 0 (off)"
            set_fan_speed 0
        else
            # Temperature is between thresholds
            if [ "$fan_state" = "high" ]; then
                echo "Temperature between thresholds - fan still at max speed"
            else
                echo "Temperature between thresholds - maintaining minimum speed"
            fi
        fi
    else
        echo "$(date): Error reading GPU temperature"
    fi
    
    sleep 10
done
