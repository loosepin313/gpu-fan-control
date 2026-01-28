#!/bin/bash
# CPU to System Fan Control Script
# This script controls system fans based on CPU temperature
# It uses direct PWM control instead of fancontrol which has sensor issues

# Configuration
CPU_TEMP_SENSOR="/sys/class/hwmon/hwmon4/temp1_input"
GPU0_TEMP_SENSOR="/sys/class/hwmon/hwmon2/temp1_input"
CPU_FAN1_PWM="/sys/class/hwmon/hwmon6/pwm1"
SYSTEM_FAN1_PWM="/sys/class/hwmon/hwmon6/pwm2"
CPU_FAN1_MIN_TEMP=40
CPU_FAN1_MAX_TEMP=70
GPU0_MIN_TEMP=40
GPU0_MAX_TEMP=85
MIN_TEMP=40
MAX_TEMP=80
MIN_PWM=30
MAX_PWM=255

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

# Function to get CPU temperature in Celsius
get_cpu_temp() {
    if [ -f "$CPU_TEMP_SENSOR" ]; then
        temp=$(cat "$CPU_TEMP_SENSOR")
        # Convert from millidegrees to degrees Celsius
        echo $((temp / 1000))
    else
        echo 0
    fi
}

# Function to get GPU0 temperature in Celsius
get_gpu0_temp() {
    if [ -f "$GPU0_TEMP_SENSOR" ]; then
        temp=$(cat "$GPU0_TEMP_SENSOR")
        # Convert from millidegrees to degrees Celsius
        echo $((temp / 1000))
    else
        echo 0
    fi
}

# Initialize PWM control to manual mode
echo "Initializing PWM control to manual mode..."
set_pwm_manual_mode "/sys/class/hwmon/hwmon6/pwm1_enable" "CPU_FAN1_PWM"
set_pwm_manual_mode "/sys/class/hwmon/hwmon6/pwm2_enable" "SYSTEM_FAN1_PWM"

# Function to check if the system is ready
check_system() {
    if [ ! -f "$CPU_TEMP_SENSOR" ]; then
        echo "Error: CPU temperature sensor not found at $CPU_TEMP_SENSOR"
        return 1
    fi
    
    if [ ! -f "$GPU0_TEMP_SENSOR" ]; then
        echo "Error: GPU0 temperature sensor not found at $GPU0_TEMP_SENSOR"
        return 1
    fi
    
    if [ ! -w "$CPU_FAN1_PWM" ]; then
        echo "Error: CPU fan 1 PWM not writable at $CPU_FAN1_PWM"
        return 1
    fi
    
    if [ ! -w "$SYSTEM_FAN1_PWM" ]; then
        echo "Error: System fan 1 PWM not writable at $SYSTEM_FAN1_PWM"
        return 1
    fi
    
    return 0
}

# Main loop
echo "Starting CPU and GPU to System Fan Control..."
echo "Monitoring CPU temperature and controlling CPU fan"
echo "Monitoring GPU0 temperature and controlling system fan"

# Check if system is ready
if ! check_system; then
    echo "System check failed, exiting."
    exit 1
fi

while true; do
    cpu_temp=$(get_cpu_temp)
    gpu0_temp=$(get_gpu0_temp)
    
    # Control CPU fan based on CPU temperature
    if [ $cpu_temp -gt 0 ]; then
        if [ $cpu_temp -ge $CPU_FAN1_MIN_TEMP ]; then
            # Calculate PWM value based on temperature for CPU_FAN1
            # Linear mapping from CPU_FAN1_MIN_TEMP to CPU_FAN1_MAX_TEMP
            if [ $cpu_temp -ge $CPU_FAN1_MAX_TEMP ]; then
                cpu_pwm_value=$MAX_PWM
            else
                cpu_pwm_value=$((MIN_PWM + (MAX_PWM - MIN_PWM) * (cpu_temp - CPU_FAN1_MIN_TEMP) / (CPU_FAN1_MAX_TEMP - CPU_FAN1_MIN_TEMP)))
            fi
            # Ensure value is in valid range
            if [ $cpu_pwm_value -lt $MIN_PWM ]; then
                cpu_pwm_value=$MIN_PWM
            fi
            if [ $cpu_pwm_value -gt $MAX_PWM ]; then
                cpu_pwm_value=$MAX_PWM
            fi
        else
            # Set minimum PWM when temperature is below threshold
            cpu_pwm_value=$MIN_PWM
        fi
        echo "$(date): CPU Temp: ${cpu_temp}°C, CPU Fan PWM: $cpu_pwm_value"
    else
        echo "$(date): Error reading CPU temperature"
    fi
    
    # Control system fan based on GPU0 temperature
    if [ $gpu0_temp -gt 0 ]; then
        if [ $gpu0_temp -ge $GPU0_MIN_TEMP ]; then
            # Calculate PWM value based on temperature for SYSTEM_FAN1
            # Linear mapping from GPU0_MIN_TEMP to GPU0_MAX_TEMP
            if [ $gpu0_temp -ge $GPU0_MAX_TEMP ]; then
                system_pwm_value=$MAX_PWM
            else
                system_pwm_value=$((MIN_PWM + (MAX_PWM - MIN_PWM) * (gpu0_temp - GPU0_MIN_TEMP) / (GPU0_MAX_TEMP - GPU0_MIN_TEMP)))
            fi
            # Ensure value is in valid range
            if [ $system_pwm_value -lt $MIN_PWM ]; then
                system_pwm_value=$MIN_PWM
            fi
            if [ $system_pwm_value -gt $MAX_PWM ]; then
                system_pwm_value=$MAX_PWM
            fi
        else
            # Set minimum PWM when temperature is below threshold
            system_pwm_value=$MIN_PWM
        fi
        echo "$(date): GPU0 Temp: ${gpu0_temp}°C, System Fan PWM: $system_pwm_value"
    else
        echo "$(date): Error reading GPU0 temperature"
    fi
    
    # Set both fans
    if [ -w "$CPU_FAN1_PWM" ]; then
        echo $cpu_pwm_value > "$CPU_FAN1_PWM"
    fi
    if [ -w "$SYSTEM_FAN1_PWM" ]; then
        echo $system_pwm_value > "$SYSTEM_FAN1_PWM"
    fi
    
    sleep 10
done
