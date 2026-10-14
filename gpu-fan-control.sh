#!/bin/bash
# gpu-fan-control.sh - tie a chassis fan to GPU temperature
#
# Designed for passively cooled GPU cards (AMD Instinct MI25/MI50/MI60, and
# any headless card with no fan of its own) that rely on a case fan plugged
# into a motherboard header.
#
# Devices are discovered by hwmon *name* and PCI address rather than by
# hwmonN index, because the kernel reassigns those indices between boots and
# kernel updates.
#
# Control modes (CONTROL_MODE in the config file):
#   proportional - fan ramps linearly across a temperature band (default)
#   step         - two-position hysteresis, the original v1 behaviour
#   mirror       - rescale the GPU driver's own fan demand onto the fan
#
# In every mode a hard ceiling overrides the law: if the control sensor reaches
# CEILING_TEMP the fan goes to full blast and stays there until it falls back
# below CEILING_TEMP - CEILING_HYSTERESIS.
#
# Config file: /etc/gpu-fan-control.conf
# Calibration/probe helpers: fan_probe.sh, tools/calibrate_fan.sh

CONFIG_FILE="${CONFIG_FILE:-/etc/gpu-fan-control.conf}"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
fi

# --- defaults (override these in the config file) --------------------------
GPU_PCI="${GPU_PCI:-0000:03:00.0}"      # the GPU whose temperature we read
GPU_HWMON_NAME="${GPU_HWMON_NAME:-amdgpu}"
FAN_HWMON_NAME="${FAN_HWMON_NAME:-it8628}"   # Super I/O: it8628, nct6779, it87...

# Which GPU temperature to control on. On MI50/MI60 the labels are
# edge / junction / mem. Use "junction" - it is the hotspot and it runs away
# first. Controlling on "edge" hides the real problem.
GPU_TEMP_LABEL="${GPU_TEMP_LABEL:-junction}"

PWM_CHANNEL="${PWM_CHANNEL:-3}"         # chip channel, NOT the silkscreen label
CONTROL_MODE="${CONTROL_MODE:-proportional}"

MIN_PWM="${MIN_PWM:-90}"
MAX_PWM="${MAX_PWM:-210}"
TEMP_THRESHOLD_HIGH="${TEMP_THRESHOLD_HIGH:-65}"
TEMP_THRESHOLD_LOW="${TEMP_THRESHOLD_LOW:-35}"
POLL_INTERVAL="${POLL_INTERVAL:-10}"

# Hard ceiling override. 0 disables it.
CEILING_TEMP="${CEILING_TEMP:-80}"
CEILING_HYSTERESIS="${CEILING_HYSTERESIS:-6}"

# Number of temperature samples averaged before the proportional law sees them.
# Damps transient spikes without adding much lag (unlike PWM_STEP alone).
TEMP_AVG_N="${TEMP_AVG_N:-3}"

# Only rewrite the PWM file when the duty changes by at least this much.
PWM_STEP="${PWM_STEP:-5}"

# mirror mode: the amdgpu driver's own demand window for this card, measured
# as (min..max) of /sys/class/hwmon/<gpu>/pwm1 under load.
GPU_PWM_LOW="${GPU_PWM_LOW:-37}"
GPU_PWM_HIGH="${GPU_PWM_HIGH:-63}"

# Stop the fan entirely below this temperature; empty = never (recommended for
# passively cooled cards, which need airflow even when cool).
FAN_OFF_BELOW_C="${FAN_OFF_BELOW_C:-}"

# Optional GPU power cap in watts, applied at startup via power1_cap. Empty =
# leave the card's own cap alone.
GPU_POWER_LIMIT_W="${GPU_POWER_LIMIT_W:-}"

# Consecutive failed temperature reads before forcing the fan to MAX_PWM.
FAILSAFE_AFTER="${FAILSAFE_AFTER:-3}"

# How long to keep retrying device discovery at startup. 0 = retry forever.
# A missing GPU (card moved to another machine, driver slow to load) must not
# turn into an endless systemd restart loop, and must not give up on cooling
# either - so retry in-process instead of exiting.
DISCOVERY_RETRY_SECONDS="${DISCOVERY_RETRY_SECONDS:-30}"

# --- helpers ---------------------------------------------------------------
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

find_hwmon_by_name() {
    local want="$1" pci_filter="$2" h name
    for h in /sys/class/hwmon/hwmon*; do
        name=$(cat "$h/name" 2>/dev/null)
        [ "$name" = "$want" ] || continue
        if [ -n "$pci_filter" ]; then
            readlink -f "$h" 2>/dev/null | grep -q "$pci_filter" || continue
        fi
        echo "$h"
        return 0
    done
    return 1
}

# Locate the tempN_input whose tempN_label matches GPU_TEMP_LABEL.
# Falls back to temp1_input if the label is not present - many GPUs expose only
# one temperature (a Cezanne iGPU reports just "edge"), and refusing to start
# would leave the card with no fan control at all.
find_gpu_temp_input() {
    local f label
    for f in "$GPU_HWMON"/temp*_label; do
        [ -f "$f" ] || continue
        label=$(cat "$f" 2>/dev/null)
        if [ "$label" = "$GPU_TEMP_LABEL" ]; then
            echo "${f%_label}_input"
            return 0
        fi
    done
    return 1
}

list_temp_labels() {
    local f
    for f in "$GPU_HWMON"/temp*_label; do
        [ -f "$f" ] || continue
        printf '%s ' "$(cat "$f" 2>/dev/null)"
    done
}

# Locate the GPU's own fan-demand file.
# Some kernels label it "GPU Fan"; others (seen on ROCm 7 / MI50) expose pwm1
# with no _label file at all. Fall back to the first plain pwmN under the GPU
# hwmon - that is the driver's fan demand for the card. Note this is a
# different directory from the Super I/O's pwmN, so the two never collide.
find_gpu_pwm() {
    local f label first=""
    for f in "$GPU_HWMON"/pwm*; do
        [ -f "$f" ] || continue
        case "$f" in *_enable|*_max|*_min|*_period|*_auto_*) continue ;; esac
        label=$(cat "${f}_label" 2>/dev/null)
        if [ "$label" = "GPU Fan" ]; then
            echo "$f"
            return 0
        fi
        [ -z "$first" ] && first="$f"
    done
    [ -n "$first" ] && { echo "$first"; return 0; }
    return 1
}

# --- device discovery, retried in-process ----------------------------------
# Exiting on a missing device is the wrong behaviour for a cooling service: it
# turns into an endless systemd restart loop (one real deployment logged 9796
# restarts after the GPU was moved to another machine) while providing no
# cooling. Retry instead, and say why.
attempt=0
while : ; do
    GPU_HWMON=$(find_hwmon_by_name "$GPU_HWMON_NAME" "$GPU_PCI")
    FAN_HWMON=$(find_hwmon_by_name "$FAN_HWMON_NAME" "")
    [ -n "$GPU_HWMON" ] && [ -n "$FAN_HWMON" ] && break

    attempt=$(( attempt + 1 ))
    if [ "$attempt" -eq 1 ]; then
        log "ERROR: device discovery failed"
        [ -z "$GPU_HWMON" ] && log "  no hwmon named '$GPU_HWMON_NAME' for PCI $GPU_PCI"
        [ -z "$FAN_HWMON" ] && log "  no hwmon named '$FAN_HWMON_NAME'"
        log "  present hwmon devices: $(for h in /sys/class/hwmon/hwmon*; do printf '%s ' "$(cat "$h"/name 2>/dev/null)"; done)"
        log "  retrying every ${DISCOVERY_RETRY_SECONDS}s (Ctrl-C to stop)"
    fi
    sleep "$DISCOVERY_RETRY_SECONDS"
done

GPU_TEMP=$(find_gpu_temp_input)
if [ -z "$GPU_TEMP" ]; then
    log "WARNING: no temp label '$GPU_TEMP_LABEL' under $GPU_HWMON"
    log "         available labels: $(list_temp_labels)"
    GPU_TEMP="$GPU_HWMON/temp1_input"
    log "         falling back to temp1_input - set GPU_TEMP_LABEL to one of the labels above"
    if [ ! -r "$GPU_TEMP" ]; then
        log "ERROR: $GPU_TEMP is not readable, cannot control anything"
        exit 1
    fi
fi

GPU_PWM=$(find_gpu_pwm)
PWM_FILE="$FAN_HWMON/pwm${PWM_CHANNEL}"
PWM_ENABLE="$FAN_HWMON/pwm${PWM_CHANNEL}_enable"
FAN_INPUT="$FAN_HWMON/fan${PWM_CHANNEL}_input"

if [ ! -w "$PWM_FILE" ]; then
    log "ERROR: cannot write $PWM_FILE"
    log "  available outputs: $(for p in "$FAN_HWMON"/pwm*; do case "$p" in *_enable|*_period|*_auto_*) continue;; esac; printf '%s ' "$(basename "$p")"; done)"
    log "  check PWM_CHANNEL in the config, and run fan_probe.sh to find the header your fan is on"
    exit 1
fi

log "GPU fan control starting on $(hostname)"
log "  temp source : $GPU_HWMON ($GPU_HWMON_NAME @ $GPU_PCI) label=$GPU_TEMP_LABEL"
log "  fan output  : $FAN_HWMON ($FAN_HWMON_NAME) pwm${PWM_CHANNEL}"
log "  mode        : $CONTROL_MODE"
log "  thresholds  : low=${TEMP_THRESHOLD_LOW}C high=${TEMP_THRESHOLD_HIGH}C  duty=${MIN_PWM}..${MAX_PWM}"
if [ "$CEILING_TEMP" -gt 0 ]; then
    log "  ceiling     : $GPU_TEMP_LABEL >= ${CEILING_TEMP}C forces duty 255 (latched until $((CEILING_TEMP - CEILING_HYSTERESIS))C)"
fi
log "  poll        : ${POLL_INTERVAL}s"
log "  tachometer  : fan${PWM_CHANNEL} = $(cat "$FAN_INPUT" 2>/dev/null || echo n/a) RPM (0 usually means nothing is plugged in)"
[ -n "$GPU_PWM" ] && log "  gpu demand  : $GPU_PWM (driver asks $(cat "$GPU_PWM" 2>/dev/null)/255)"
[ -z "$GPU_PWM" ] && log "  note        : $GPU_HWMON_NAME exposes no GPU fan demand - mirror mode unavailable"
[ "$(cat "$FAN_INPUT" 2>/dev/null)" = "0" ] && \
    log "  WARNING     : fan${PWM_CHANNEL} reads 0 RPM. If the fan is spinning, this header is the wrong one - run fan_probe.sh"

# Set the power cap before any load is applied.
if [ -n "$GPU_POWER_LIMIT_W" ]; then
    # power1_cap is in microwatts.
    cap_file="$GPU_HWMON/power1_cap"
    if [ -w "$cap_file" ]; then
        echo $(( GPU_POWER_LIMIT_W * 1000000 )) > "$cap_file" \
            && log "  power cap   : set to ${GPU_POWER_LIMIT_W}W via $cap_file" \
            || log "  power cap   : FAILED to write $cap_file"
    else
        log "  power cap   : $cap_file not writable (need root) - cap not applied"
    fi
fi

# Put the channel into software manual mode. Mode 1 = manual; mode 2 = the
# chip's own hardware curve; mode 0 = full speed / no control (chip dependent).
if [ -w "$PWM_ENABLE" ]; then
    current_mode=$(cat "$PWM_ENABLE" 2>/dev/null)
    if [ -n "$PWM_MODE" ] && [ "$current_mode" != "$PWM_MODE" ]; then
        echo "$PWM_MODE" > "$PWM_ENABLE"
        log "pwm${PWM_CHANNEL} mode set to $PWM_MODE"
    elif [ "$current_mode" != "1" ]; then
        echo 1 > "$PWM_ENABLE"
        log "pwm${PWM_CHANNEL} set to manual mode"
    fi
fi

get_temp() {
    local raw
    raw=$(cat "$GPU_TEMP" 2>/dev/null) || return 1
    [ -z "$raw" ] && return 1
    echo $(( raw / 1000 ))
}

get_gpu_pwm() {
    [ -n "$GPU_PWM" ] || return 1
    cat "$GPU_PWM" 2>/dev/null
}

# proportional law: MIN_PWM at TEMP_THRESHOLD_LOW, MAX_PWM at TEMP_THRESHOLD_HIGH
want_pwm_proportional() {
    local t="$1" span out
    span=$(( TEMP_THRESHOLD_HIGH - TEMP_THRESHOLD_LOW ))
    [ "$span" -le 0 ] && { echo "$MAX_PWM"; return; }
    if [ "$t" -le "$TEMP_THRESHOLD_LOW" ]; then
        echo "$MIN_PWM"
    elif [ "$t" -ge "$TEMP_THRESHOLD_HIGH" ]; then
        echo "$MAX_PWM"
    else
        out=$(( MIN_PWM + (t - TEMP_THRESHOLD_LOW) * (MAX_PWM - MIN_PWM) / span ))
        # never dip below MIN_PWM or above MAX_PWM
        [ "$out" -lt "$MIN_PWM" ] && out=$MIN_PWM
        [ "$out" -gt "$MAX_PWM" ] && out=$MAX_PWM
        echo "$out"
    fi
}

# mirror law: rescale the driver's own demand window onto MIN_PWM..MAX_PWM
want_pwm_mirror() {
    local gp="$1" gspan out
    gspan=$(( GPU_PWM_HIGH - GPU_PWM_LOW ))
    [ "$gspan" -le 0 ] && { echo "$MAX_PWM"; return; }
    [ "$gp" -le "$GPU_PWM_LOW" ]  && { echo "$MIN_PWM"; return; }
    [ "$gp" -ge "$GPU_PWM_HIGH" ] && { echo "$MAX_PWM"; return; }
    out=$(( MIN_PWM + (gp - GPU_PWM_LOW) * (MAX_PWM - MIN_PWM) / gspan ))
    echo "$out"
}

# Only rewrite the sysfs file when the duty actually moves by PWM_STEP or more.
moved_enough() {
    local want="$1" cur="$2" d
    d=$(( want - cur )); [ "$d" -lt 0 ] && d=$(( -d ))
    [ "$d" -ge "$PWM_STEP" ]
}

# --- state -----------------------------------------------------------------
applied_pwm=""
ceiling_latched=0
step_state="low"
fail_count=0
declare -a temp_ring=()

# start conservatively at MIN_PWM (or off, if configured)
if [ -n "$FAN_OFF_BELOW_C" ]; then
    applied_pwm=0
else
    applied_pwm=$MIN_PWM
fi
echo "$applied_pwm" > "$PWM_FILE"
log "pwm${PWM_CHANNEL} duty set to $applied_pwm"

while true; do
    t=$(get_temp)
    if [ -z "$t" ]; then
        fail_count=$(( fail_count + 1 ))
        log "WARN: cannot read $GPU_TEMP (attempt $fail_count)"
        if [ "$fail_count" -ge "$FAILSAFE_AFTER" ] && [ "$applied_pwm" != "$MAX_PWM" ]; then
            log "FAILSAFE: sensor unreadable ${fail_count}x - forcing pwm${PWM_CHANNEL} to $MAX_PWM"
            echo "$MAX_PWM" > "$PWM_FILE"
            applied_pwm=$MAX_PWM
        fi
        sleep "$POLL_INTERVAL"
        continue
    fi
    fail_count=0

    # running average for the control law (ceiling check uses the raw reading)
    temp_ring+=("$t")
    while [ "${#temp_ring[@]}" -gt "$TEMP_AVG_N" ]; do
        temp_ring=("${temp_ring[@]:1}")
    done
    sum=0
    for v in "${temp_ring[@]}"; do sum=$(( sum + v )); done
    smooth=$(( sum / ${#temp_ring[@]} ))

    # --- hard ceiling override, latched -----------------------------------
    # The ceiling is a promise, not a suggestion, so once it trips the fan
    # stays at full blast until the sensor falls back by CEILING_HYSTERESIS.
    # Without the latch a reading hovering on the limit would flap the fan
    # between 255 and MAX_PWM every poll.
    if [ "$CEILING_TEMP" -gt 0 ]; then
        if [ "$t" -ge "$CEILING_TEMP" ]; then
            ceiling_latched=1
        elif [ "$t" -le $(( CEILING_TEMP - CEILING_HYSTERESIS )) ]; then
            ceiling_latched=0
        fi
    fi

    if [ "$ceiling_latched" -eq 1 ]; then
        want=255
        reason="CEILING >= ${CEILING_TEMP}C"
    elif [ -n "$FAN_OFF_BELOW_C" ] && [ "$t" -lt "$FAN_OFF_BELOW_C" ]; then
        want=0
        reason="below ${FAN_OFF_BELOW_C}C"
    else
        case "$CONTROL_MODE" in
            proportional)
                want=$(want_pwm_proportional "$smooth")
                reason="${GPU_TEMP_LABEL} ${smooth}C (n=${#temp_ring[@]}, raw ${t}C)"
                ;;
            mirror)
                gp=$(get_gpu_pwm)
                if [ -z "$gp" ]; then
                    log "WARN: mirror mode but no GPU pwm file - holding $applied_pwm"
                    want=$applied_pwm
                    reason="mirror unavailable"
                else
                    want=$(want_pwm_mirror "$gp")
                    reason="gpu demand $gp/255 -> duty $want"
                fi
                ;;
            step|*)
                # original two-position hysteresis
                if [ "$smooth" -ge "$TEMP_THRESHOLD_HIGH" ]; then
                    step_state="high"
                elif [ "$smooth" -le "$TEMP_THRESHOLD_LOW" ]; then
                    step_state="low"
                fi
                if [ "$step_state" = "high" ]; then want=$MAX_PWM; else want=$MIN_PWM; fi
                reason="${GPU_TEMP_LABEL} ${smooth}C state=$step_state"
                ;;
        esac
    fi

    if moved_enough "$want" "$applied_pwm"; then
        echo "$want" > "$PWM_FILE"
        log "$reason -> duty $want (was $applied_pwm)"
        applied_pwm=$want
    else
        log "$reason -> duty $applied_pwm (want $want)"
    fi

    sleep "$POLL_INTERVAL"
done
