#!/usr/bin/env bash
# calibrate_fan.sh - measure duty -> RPM and duty -> GPU temperature
#
# Answers the only two questions that matter when sizing a fan curve:
#   1. what RPM does each PWM duty actually give this fan?
#   2. what steady-state GPU temperature does each duty hold under real load?
#
# From (2) you get a thermal resistance per duty, R = (T_junction - T_idle) / W,
# and from that the maximum GPU power your cooling can hold under a temperature
# ceiling:  P_max = (ceiling - T_idle) / R.
#
#   usage: sudo ./tools/calibrate_fan.sh [options]
#
#     --duty "90 120 160 200 255"   duties to test (default shown)
#     --load-cmd "..."              command that generates sustained GPU load
#     --load-dur 130                seconds to hold each duty under load
#     --cool-dur 60                 seconds of cooldown between steps
#     --label junction              GPU temp label to record
#
# The gpu-fan-control service is stopped for the run and its original channel
# values are restored afterwards, including on Ctrl-C.
#
# IMPORTANT: use a load that reproduces your real workload power. A synthetic
# ALU burn (matrix multiply, mining-style) routinely under-reports power by
# 30-50% on inference cards because it never touches memory bandwidth. If the
# card is a GPU inference box, drive the real inference endpoint - see
# tools/loadgen.sh.

set -u

CONFIG_FILE="${CONFIG_FILE:-/etc/gpu-fan-control.conf}"
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

GPU_PCI="${GPU_PCI:-0000:03:00.0}"
GPU_HWMON_NAME="${GPU_HWMON_NAME:-amdgpu}"
FAN_HWMON_NAME="${FAN_HWMON_NAME:-it8628}"
PWM_CHANNEL="${PWM_CHANNEL:-3}"
LABEL="${GPU_TEMP_LABEL:-junction}"
DUTIES="${DUTIES:-90 120 160 200 255}"
LOAD_CMD="${LOAD_CMD:-}"
LOAD_DUR=130
COOL_DUR=60

while [ $# -gt 0 ]; do
    case "$1" in
        --duty)     DUTIES="$2"; shift 2 ;;
        --load-cmd) LOAD_CMD="$2"; shift 2 ;;
        --load-dur) LOAD_DUR="$2"; shift 2 ;;
        --cool-dur) COOL_DUR="$2"; shift 2 ;;
        --label)    LABEL="$2"; shift 2 ;;
        -h|--help)  sed -n '2,26p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then echo "must run as root" >&2; exit 1; fi

find_hwmon_by_name() {
    local want="$1" pci="$2" h n
    for h in /sys/class/hwmon/hwmon*; do
        n=$(cat "$h/name" 2>/dev/null); [ "$n" = "$want" ] || continue
        if [ -n "$pci" ]; then
            readlink -f "$h" 2>/dev/null | grep -q "$pci" || continue
        fi
        echo "$h"; return
    done
}

G=$(find_hwmon_by_name "$GPU_HWMON_NAME" "$GPU_PCI")
H=$(find_hwmon_by_name "$FAN_HWMON_NAME" "")
[ -n "$G" ] || { echo "no $GPU_HWMON_NAME hwmon for $GPU_PCI" >&2; exit 1; }
[ -n "$H" ] || { echo "no $FAN_HWMON_NAME hwmon" >&2; exit 1; }

# resolve the temp label
TEMP_F=""
for f in "$G"/temp*_label; do
    [ -f "$f" ] || continue
    [ "$(cat "$f" 2>/dev/null)" = "$LABEL" ] && TEMP_F="${f%_label}_input"
done
[ -n "$TEMP_F" ] || { echo "no label '$LABEL'. available: $(cat "$G"/temp*_label 2>/dev/null | tr '\n' ' ')" >&2; exit 1; }

PWM="$H/pwm${PWM_CHANNEL}"; EN="$H/pwm${PWM_CHANNEL}_enable"; FAN="$H/fan${PWM_CHANNEL}_input"
[ -w "$PWM" ] || { echo "cannot write $PWM" >&2; exit 1; }

t() { echo $(( $(cat "$1") / 1000 )); }
w() { echo $(( $(cat "$G/power1_input" 2>/dev/null || echo 0) / 1000000 )); }

OLD_EN=$(cat "$EN" 2>/dev/null); OLD_PWM=$(cat "$PWM" 2>/dev/null)
restore() {
    echo "$OLD_PWM" > "$PWM" 2>/dev/null
    echo "$OLD_EN"  > "$EN"  2>/dev/null
    echo "restored $PWM=$OLD_PWM enable=$OLD_EN"
    [ "${STOPPED:-0}" = "1" ] && systemctl start gpu-fan-control.service 2>/dev/null
}
trap restore EXIT INT TERM

echo "gpu: $G  label=$LABEL ($TEMP_F)"
echo "fan: $H pwm$PWM_CHANNEL"
echo
if systemctl is-active --quiet gpu-fan-control.service 2>/dev/null; then
    echo "stopping gpu-fan-control.service for the duration of the run"
    systemctl stop gpu-fan-control.service
    STOPPED=1
fi
echo 1 > "$EN"

IDLE=$(t "$TEMP_F")
echo "idle junction = ${IDLE}C"
echo

printf '%6s %5s %8s %8s %8s %8s\n' duty pct rpm edge junc mem
for d in $DUTIES; do
    echo "$d" > "$PWM"; sleep 3
    printf '%6s %4d%% %8s %8s %8s %8s\n' "$d" "$(( d * 100 / 255 ))" \
        "$(cat "$FAN" 2>/dev/null)" "$(t "$G/temp1_input")" "$(t "$TEMP_F")" "$(t "$G/temp3_input")"
done

if [ -z "$LOAD_CMD" ]; then
    echo
    echo "no --load-cmd given: stopped after the duty/RPM sweep."
    echo "re-run with --load-cmd to get the temperature half of the calibration."
    exit 0
fi

for d in $DUTIES; do
    echo
    echo "=== duty $d ($(( d * 100 / 255 ))%) fan=$(cat "$FAN" 2>/dev/null) RPM ==="
    echo "$d" > "$PWM"
    eval "$LOAD_CMD" >/dev/null 2>&1 &
    LOADPID=$!
    peakw=0; sumw=0; n=0; peakj=0
    for ((s = 1; s <= LOAD_DUR / 10; s++)); do
        sleep 10
        cw=$(w); cj=$(t "$TEMP_F")
        printf '  t=%3ds edge=%3s junc=%3s mem=%3s W=%3s fan=%s\n' \
            $(( s * 10 )) "$(t "$G/temp1_input")" "$cj" "$(t "$G/temp3_input")" "$cw" "$(cat "$FAN" 2>/dev/null)"
        [ "$cw" -gt "$peakw" ] && peakw=$cw
        [ "$cj" -gt "$peakj" ] && peakj=$cj
        sumw=$(( sumw + cw )); n=$(( n + 1 ))
    done
    kill "$LOADPID" 2>/dev/null; wait "$LOADPID" 2>/dev/null
    avgw=$(( sumw / (n > 0 ? n : 1) ))
    r=$(awk -v p="$peakj" -v i="$IDLE" -v w="$avgw" 'BEGIN{printf "%.3f",(p-i)/(w>0?w:1)}')
    echo "  SUMMARY duty=$d peakW=${peakw}W avgW=${avgw}W peakJunc=${peakj}C  R=${r} C/W"
    echo "  cooling ${COOL_DUR}s ..."
    for ((s = 1; s <= COOL_DUR / 10; s++)); do
        sleep 10
        echo "  cool t=$(( s * 10 ))s junc=$(t "$TEMP_F")"
    done
done

echo
echo "Thermal resistance R = (peakJunc - idle) / avgW, per duty."
echo "Max power holdable under a ceiling T:  P_max = (T - ${IDLE}C) / R"
