#!/bin/bash
# Simple GPU Fan Control Script with Hysteresis
# Uses hardcoded device paths as specified

# Device configuration
GPU_TEMP_SENSOR="/sys/class/hwmon/hwmon3/temp1_input"
GPU_FAN_PWM="/sys/class/hwmon/hwmon1/pwm3"
PWM_ENABLE="/sys/class/hwmon/hwmon1/pwm3_enable"

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
