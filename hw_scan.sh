#!/bin/bash
# hw_scan.sh — Scan all hwmon devices and display GPU info
# Use: hw_scan.sh  (or  hw_scan.sh --pci 0000:03:00  to filter by GPU)

echo "=== Hardware Monitor Devices ==="
echo
for h in /sys/class/hwmon/hwmon*; do
  name=$(cat "$h/name" 2>/dev/null)
  [ -z "$name" ] && continue

  # Resolve the real path to find PCI address for GPUs
  real_path=$(readlink -f "$h" 2>/dev/null)
  pci=$(echo "$real_path" | grep -oP '0000:[0-9a-f]{4}:[0-9a-f]{2}\.[0-9a-f]' | head -1)

  # Filter: if --pci argument given, only show matching GPUs
  if [ -n "$1" ] && [ "$1" = "--pci" ]; then
    target_pci="$2"
    if [ -z "$target_pci" ]; then
      echo "Usage: $0 --pci <PCI_ADDRESS>"
      echo "Example: $0 --pci 0000:03:00"
      exit 1
    fi
    if [ "$name" != "amdgpu" ] && [ "$name" != "nvidia" ] && [ "$name" != "radeon" ] && [ "$name" != "nvme" ]; then
      continue
    fi
    if [ -n "$pci" ]; then
      [[ "$pci" != "$target_pci"* ]] && continue
    else
      continue
    fi
  fi

  # Extract key sensor values
  temp=$(cat "$h/temp1_input" 2>/dev/null)
  fan=$(cat "$h/fan1_input" 2>/dev/null)
  pwm=$(cat "$h/pwm1" 2>/dev/null)
  pwm_en=$(cat "$h/pwm1_enable" 2>/dev/null)

  case "$name" in
    amdgpu|nvidia*|radeon*)
      echo "[GPU]  $h  ($name)"
      [ -n "$pci" ] && echo "       PCI: $pci"
      # Show every labelled temperature sensor. On MI50/MI60 these are
      # edge / junction / mem, and junction is the one that runs away first -
      # temp1 is NOT necessarily the sensor you want to control on.
      i=1
      while [ $i -le 10 ]; do
        lab=$(cat "$h/temp${i}_label" 2>/dev/null)
        val=$(cat "$h/temp${i}_input" 2>/dev/null)
        if [ -n "$val" ]; then
          printf '       Temp: %-9s %s C\n' "${lab:-temp$i}" "$(( val / 1000 ))"
        fi
        i=$((i + 1))
      done
      [ -n "$fan" ] && echo "       Fan1: ${fan} RPM"
      [ -n "$pwm" ] && echo "       GpuFanDemand: ${pwm}/255"
      echo
      ;;
    it8628|it87*|nct677*|w8362*)
      echo "[I/O]  $h  ($name)"
      i=1
      while [ $i -le 10 ]; do
        fi_val=$(cat "$h/fan${i}_input" 2>/dev/null)
        pi_val=$(cat "$h/pwm${i}" 2>/dev/null)
        pie_val=$(cat "$h/pwm${i}_enable" 2>/dev/null)
        if [ -n "$fi_val" ] || [ -n "$pi_val" ]; then
          echo "       Fan${i}: ${fi_val:-N/A} RPM | PWM${i}: ${pi_val:-N/A} (mode: ${pie_val:-auto})"
        fi
        i=$((i + 1))
      done
      echo
      ;;
    nvme|nvme*)
      temp_c=$((temp / 1000))
      echo "[NVMe] $h  ($name)"
      [ -n "$pci" ] && echo "       PCI: $pci"
      [ -n "$temp" ] && echo "       Temp: ${temp_c}°C"
      echo
      ;;
    k10temp|zenpower*)
      temp_c=$((temp / 1000))
      echo "[CPU]  $h  ($name)"
      [ -n "$temp" ] && echo "       Temp: ${temp_c}°C"
      echo
      ;;
    *)
      echo "[      ] $h  ($name)"
      echo
      ;;
  esac
done

# If filtered by PCI, also show how to configure the dynamic script
if [ "$1" = "--pci" ] && [ -n "$2" ]; then
  echo "=== PCI: $2 ==="
  echo "Use this PCI address in /etc/gpu-fan-control.conf:"
  echo "  GPU_PCI=\"$2\""
  echo
  echo "Then find which fan header you are actually on:"
  echo "  sudo fan_probe.sh"
fi
