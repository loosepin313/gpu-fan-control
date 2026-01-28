#!/bin/bash
# Video Card Fan Control Script
# This script controls system fans based on video card temperature
# It uses direct PWM control to drive the system fan from video card temperature
# Author: Chris Harris
# License: MIT

# Configuration
# Generic video card sensor and fan controller
GPU_TEMP_SENSOR="/sys/class/hwmon/hwmon2/temp1_input"
GPU_FAN_PWM="/sys/class/hwmon/hwmon6/pwm2"
MIN_TEMP=40
MAX_TEMP=85
MIN_PWM=30
MAX_PWM=255

# Function to display help
show_help() {
    echo "Video Card Fan Control Script"
    echo ""
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --detect-sensors    Detect and display available sensors"
    echo "  --test-fans         Test fan operation with PWM values"
    echo "  --help              Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                  Run normal fan control"
    echo "  $0 --detect-sensors Run sensor detection"
    echo "  $0 --test-fans      Run fan testing mode"
    echo ""
    echo "Configuration variables:"
    echo "  GPU_TEMP_SENSOR    GPU temperature sensor path"
    echo "  GPU_FAN_PWM        GPU fan PWM control path"
    echo "  MIN_TEMP           Minimum temperature to start fan control"
    echo "  MAX_TEMP           Maximum temperature for full fan speed"
    echo "  MIN_PWM            Minimum PWM value"
    echo "  MAX_PWM            Maximum PWM value"
}

# Function to set PWM control to manual mode
set_pwm_manual_mode() {
    local pwm_enable_file=$1
    local pwm_name=$2
    
    if [ -w "$pwm_enable_file" ]; then
        # Check current mode
        current_mode=$(cat "$pwm_enable_file" 2>/dev/null || echo -1)
        if [ "$current_mode" != "1" ]; then
            echo "Setting $pwm_name to manual mode (1)"
            echo 1 > "$pwm_enable_file" 2>/dev/null
            if [ $? -eq 0 ]; then
                echo "$pwm_name set to manual mode successfully"
            else
                echo "Warning: Failed to set $pwm_name to manual mode"
            fi
        else
            echo "$pwm_name already in manual mode"
        fi
    else
        echo "Warning: Cannot write to $pwm_enable_file for $pwm_name"
    fi
}

# Function to get GPU temperature in Celsius
get_gpu_temp() {
    if [ -f "$GPU_TEMP_SENSOR" ]; then
        temp=$(cat "$GPU_TEMP_SENSOR")
        # Convert from millidegrees to degrees Celsius
        echo $((temp / 1000))
    else
        echo 0
    fi
}

# Function to detect available sensors
detect_sensors() {
    echo "=== Sensor Detection ==="
    echo "Searching for GPU sensors..."
    
    for i in /sys/class/hwmon/hwmon*; do
        if [ -d "$i" ]; then
            if [ -f "$i/name" ]; then
                name=$(cat $i/name)
                if [[ "$name" == *"amdgpu"* ]] || [[ "$name" == *"nvidia"* ]] || [[ "$name" == *"radeon"* ]]; then
                    echo "Found GPU sensor at $i"
                    echo "  Name: $name"
                    if [ -f "$i/temp1_input" ]; then
                        temp=$(cat $i/temp1_input)
                        echo "  Temp1: $temp m°C"
                    fi
                fi
            fi
        fi
    done
    
    echo ""
    echo "Searching for motherboard PWM controllers..."
    
    for i in /sys/class/hwmon/hwmon*; do
        if [ -d "$i" ]; then
            if [ -f "$i/name" ]; then
                name=$(cat $i/name)
                if [[ "$name" == *"it8628"* ]] || [[ "$name" == *"pwm"* ]]; then
                    echo "Found PWM controller at $i"
                    echo "  Name: $name"
                    if [ -f "$i/pwm1" ]; then
                        echo "  PWM1: $(cat $i/pwm1)"
                    fi
                    if [ -f "$i/pwm2" ]; then
                        echo "  PWM2: $(cat $i/pwm2)"
                    fi
                fi
            fi
        fi
    done
    
    echo ""
    echo "All available sensors listed above."
}

# Function to test fans manually
test_fans() {
    echo "=== Fan Testing Mode ==="
    echo "This will test fan operation at various PWM values."
    echo "Press Ctrl+C to stop testing."
    echo ""
    
    # Test from minimum to maximum PWM values
    echo "Testing PWM values from $MIN_PWM to $MAX_PWM..."
    
    for pwm_val in $(seq $MIN_PWM $((MAX_PWM/10)) $MAX_PWM); do
        echo "Setting PWM to: $pwm_val"
        if [ -w "$GPU_FAN_PWM" ]; then
            echo $pwm_val > "$GPU_FAN_PWM"
            sleep 3
        else
            echo "Error: Cannot write to $GPU_FAN_PWM"
        fi
    done
    
    # Test maximum value
    echo "Setting PWM to maximum: $MAX_PWM"
    if [ -w "$GPU_FAN_PWM" ]; then
        echo $MAX_PWM > "$GPU_FAN_PWM"
        sleep 3
    fi
    
    # Return to minimum
    echo "Setting PWM to minimum: $MIN_PWM"
    if [ -w "$GPU_FAN_PWM" ]; then
        echo $MIN_PWM > "$GPU_FAN_PWM"
    fi
    
    echo "Fan testing completed."
}

# Initialize PWM control to manual mode
echo "Initializing PWM control to manual mode..."
set_pwm_manual_mode "/sys/class/hwmon/hwmon6/pwm2_enable" "GPU_FAN_PWM"

# Function to check if the system is ready
check_system() {
    if [ ! -f "$GPU_TEMP_SENSOR" ]; then
        echo "Error: GPU temperature sensor not found at $GPU_TEMP_SENSOR"
        return 1
    fi
    
    if [ ! -w "$GPU_FAN_PWM" ]; then
        echo "Error: GPU fan PWM controller not writable at $GPU_FAN_PWM"
        return 1
    fi
    
    return 0
}

# Parse command line arguments
case "$1" in
    --detect-sensors)
        detect_sensors
        exit 0
        ;;
    --test-fans)
        test_fans
        exit 0
        ;;
    --help|-h)
        show_help
        exit 0
        ;;
    *)
        # No arguments, run normal operation
        ;;
esac

# Check if system is ready
if ! check_system; then
    echo "System check failed, exiting."
    exit 1
fi

# Main loop
echo "Starting GPU Fan Control..."
echo "Monitoring GPU temperature and controlling GPU fan"

while true; do
    gpu_temp=$(get_gpu_temp)
    
    # Control fan based on GPU temperature
    if [ $gpu_temp -gt 0 ]; then
        if [ $gpu_temp -ge $MIN_TEMP ]; then
            # Calculate PWM value based on temperature for GPU_FAN
            # Linear mapping from MIN_TEMP to MAX_TEMP
            if [ $gpu_temp -ge $MAX_TEMP ]; then
                gpu_fan_pwm_value=$MAX_PWM
            else
                gpu_fan_pwm_value=$((MIN_PWM + (MAX_PWM - MIN_PWM) * (gpu_temp - MIN_TEMP) / (MAX_TEMP - MIN_TEMP)))
            fi
            # Ensure value is in valid range
            if [ $gpu_fan_pwm_value -lt $MIN_PWM ]; then
                gpu_fan_pwm_value=$MIN_PWM
            fi
            if [ $gpu_fan_pwm_value -gt $MAX_PWM ]; then
                gpu_fan_pwm_value=$MAX_PWM
            fi
        else
            # Set minimum PWM when temperature is below threshold
            gpu_fan_pwm_value=$MIN_PWM
        fi
        echo "$(date): GPU Temp: ${gpu_temp}°C, GPU Fan PWM: $gpu_fan_pwm_value"
    else
        echo "$(date): Error reading GPU temperature"
    fi
    
    # Set fan
    if [ -w "$GPU_FAN_PWM" ]; then
        echo $gpu_fan_pwm_value > "$GPU_FAN_PWM"
    fi
    
    sleep 10
done
