#!/usr/bin/env bash
# fan_probe.sh - find which Super I/O PWM channel your fan is actually on
#
# THE PROBLEM THIS SOLVES: the number printed on the motherboard (FAN1, FAN3...)
# does NOT reliably match the channel number in the Super I/O chip (pwm1, pwm3...).
# On a MACHINIST X99 G7 the physical FAN3 header is chip channel pwm1. Picking
# the wrong channel means you write to a dead header, the fan ignores you, and
# the fan control loop looks healthy while doing nothing.
#
# HOW: put each candidate channel into software manual mode, drive it 0 -> 255,
# and watch every tach input for a response. The channel that moves a tach is
# the one your fan is on.
#
#   usage: sudo ./fan_probe.sh [hwmon_name] [--no-zero]
#
#   hwmon_name  Super I/O chip name (default: auto-detect).
#               e.g. nct6779, it8628, it87, nct6796, f71882fg
#   --no-zero   never drive a channel to 0. Use this if a channel might be
#               your CPU cooler - a CPU fan stopping for a few seconds is
#               usually survivable, but you may prefer not to risk it.
#
# Every channel's original enable/pwm values are restored on exit, including on
# Ctrl-C and on abort.

set -u

HW_NAME=""
DO_ZERO=1
for a in "$@"; do
    case "$a" in
        --no-zero) DO_ZERO=0 ;;
        -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
        *) HW_NAME="$a" ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    echo "must run as root (writes to sysfs)" >&2
    exit 1
fi

# --- locate the Super I/O hwmon --------------------------------------------
KNOWN="it8628 it8625 it8655 it8665 it8689 it87 it8822 nct6775 nct6776 nct6779 nct6791 nct6792 nct6793 nct6795 nct6796 f71882fg w83627dhg"

HWMONS=()
for h in /sys/class/hwmon/hwmon*; do
    n=$(cat "$h/name" 2>/dev/null)
    for k in $KNOWN; do
        [ "$n" = "$k" ] && HWMONS+=("$h:$n")
    done
done

if [ ${#HWMONS[@]} -eq 0 ]; then
    echo "no recognised Super I/O fan controller found." >&2
    echo "check: for h in /sys/class/hwmon/hwmon*; do echo \$h \$(cat \$h/name); done" >&2
    exit 1
fi

H=""
if [ -n "$HW_NAME" ]; then
    for e in "${HWMONS[@]}"; do
        [ "${e#*:}" = "$HW_NAME" ] && H="${e%:*}"
    done
    [ -z "$H" ] && { echo "no hwmon named '$HW_NAME'. found: $(printf '%s ' "${HWMONS[@]}")" >&2; exit 1; }
else
    if [ ${#HWMONS[@]} -gt 1 ]; then
        echo "more than one fan controller found, pick one:"
        printf '  %s\n' "${HWMONS[@]}"
        exit 1
    fi
    H="${HWMONS[0]%:*}"
    HW_NAME="${HWMONS[0]#*:}"
fi

echo "fan controller : $H ($HW_NAME)"

# --- what to watch ----------------------------------------------------------
TACHES=()
for f in "$H"/fan*_input; do
    [ -e "$f" ] && TACHES+=("$f")
done
if [ ${#TACHES[@]} -eq 0 ]; then
    echo "no tach inputs under $H" >&2
    exit 1
fi

tachs() {
    for f in "${TACHES[@]}"; do
        printf "%s=%-5s " "$(basename "$f" _input)" "$(cat "$f" 2>/dev/null || echo '?')"
    done
}

# CPU temperature guard: if we accidentally grab the CPU fan channel we want to
# notice fast. k10temp/zenpower is AMD; CPUTIN/SYSIN is the Super I/O's own probe.
cpu_temp() {
    local v
    for cand in /sys/class/hwmon/hwmon*/temp1_input; do
        if grep -qiE 'k10temp|zenpower' "$(dirname "$cand")/name" 2>/dev/null; then
            v=$(cat "$cand" 2>/dev/null); [ -n "$v" ] && { echo $(( v / 1000 )); return; }
        fi
    done
    # fall back to the Super I/O's CPU probe (label CPUTIN on many boards)
    for f in "$H"/temp*_label; do
        [ -f "$f" ] || continue
        if [ "$(cat "$f" 2>/dev/null)" = "CPUTIN" ]; then
            v=$(cat "${f%_label}_input" 2>/dev/null)
            [ -n "$v" ] && { echo $(( v / 1000 )); return; }
        fi
    done
    echo "?"
}

CPU_LIMIT=${CPU_LIMIT:-75}

# --- restore everything on exit --------------------------------------------
declare -A SAVE_EN SAVE_PWM
restore() {
    local ch
    for ch in "${!SAVE_PWM[@]}"; do
        [ -n "${SAVE_PWM[$ch]:-}" ] && echo "${SAVE_PWM[$ch]}" > "$H/pwm${ch}" 2>/dev/null
        [ -n "${SAVE_EN[$ch]:-}" ]  && echo "${SAVE_EN[$ch]}"  > "$H/pwm${ch}_enable" 2>/dev/null
    done
    echo "restored all channels to their original values"
}
trap restore EXIT INT TERM

echo "tach inputs    : $(printf '%s ' "${TACHES[@]##*/}")"
echo "baseline       : $(tachs) cpu=$(cpu_temp)C"
echo
[ "$DO_ZERO" -eq 0 ] && echo "(--no-zero: skipping the 0%% step)"
echo

RESPONSIVE=()
for f in "$H"/pwm*; do
    case "$f" in *_enable|*_period|*_temp|*_auto_temp*) continue ;; esac
    [ -f "$f" ] || continue
    ch=$(basename "$f" | sed 's/^pwm//')

    SAVE_EN[$ch]=$(cat "$H/pwm${ch}_enable" 2>/dev/null)
    SAVE_PWM[$ch]=$(cat "$f" 2>/dev/null)

    echo "--- channel $ch (enable=${SAVE_EN[$ch]} pwm=${SAVE_PWM[$ch]}) ---"
    if [ ! -w "$H/pwm${ch}_enable" ]; then
        echo "    not writable, skipping"
        echo
        continue
    fi
    echo 1 > "$H/pwm${ch}_enable"

    before=$(tachs)
    echo 255 > "$f"; sleep 4
    up=$(tachs)
    if [ "$DO_ZERO" -eq 1 ]; then
        echo 0 > "$f"; sleep 4
        down=$(tachs)
        echo "    pwm=255 -> $up"
        echo "    pwm=0   -> $down"
        if [ "$up" != "$down" ]; then
            echo "    ==> RESPONSIVE: channel $ch controls a fan"
            RESPONSIVE+=("$ch")
        else
            echo "    no tach change - dead header or hardware-controlled"
        fi
    else
        echo "    pwm=255 -> $up"
        if [ "$up" != "$before" ]; then
            echo "    ==> RESPONSIVE: channel $ch controls a fan"
            RESPONSIVE+=("$ch")
        else
            echo "    no tach change"
        fi
    fi

    echo "${SAVE_PWM[$ch]}" > "$f"
    echo "${SAVE_EN[$ch]}"  > "$H/pwm${ch}_enable"
    echo "    restored enable=${SAVE_EN[$ch]} pwm=${SAVE_PWM[$ch]}"
    echo

    ct=$(cpu_temp)
    if [ "$ct" != "?" ] && [ "$ct" -gt "$CPU_LIMIT" ]; then
        echo "CPU at ${ct}C (limit $CPU_LIMIT) - aborting sweep, restoring channels"
        break
    fi
done

echo "final          : $(tachs) cpu=$(cpu_temp)C"
echo
if [ ${#RESPONSIVE[@]} -gt 0 ]; then
    echo "channels that moved a tach: ${RESPONSIVE[*]}"
    echo "use the one matching your fan header in the config:"
    echo "    PWM_CHANNEL=<n>"
else
    echo "no channel changed a tach reading."
    echo "possible causes: fan on a hardware-controlled header (SmartFan still"
    echo "active), fan tach not connected, or the fan is not on this chip."
fi
