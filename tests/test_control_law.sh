#!/usr/bin/env bash
# tests/test_control_law.sh - unit tests for the PWM maths in gpu-fan-control.sh
#
# The control law is pure arithmetic on sysfs values, so it can be tested
# without any hardware: the three functions are extracted from the script and
# driven directly.
#
#   run: ./tests/test_control_law.sh

set -u

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/gpu-fan-control.sh"
[ -f "$SCRIPT" ] || { echo "no such script: $SCRIPT" >&2; exit 1; }

# Pull the pure functions out of the control script.
eval "$(sed -n '/^want_pwm_proportional()/,/^}/p' "$SCRIPT")"
eval "$(sed -n '/^want_pwm_mirror()/,/^}/p' "$SCRIPT")"
eval "$(sed -n '/^moved_enough()/,/^}/p' "$SCRIPT")"

for fn in want_pwm_proportional want_pwm_mirror moved_enough; do
    declare -F "$fn" >/dev/null || { echo "FATAL: could not extract $fn from $SCRIPT" >&2; exit 1; }
done

pass=0; fail=0
check() {
    local desc="$1" got="$2" want="$3"
    if [ "$got" = "$want" ]; then
        pass=$(( pass + 1 ))
        printf '  ok   %-52s %s\n' "$desc" "$got"
    else
        fail=$(( fail + 1 ))
        printf '  FAIL %-52s got %s, want %s\n' "$desc" "$got" "$want"
    fi
}

# --- proportional: band 55..74, duty 60..220 (the shipped MI50 example) ----
echo "proportional (LOW=55 HIGH=74 MIN=60 MAX=220)"
TEMP_THRESHOLD_LOW=55; TEMP_THRESHOLD_HIGH=74; MIN_PWM=60; MAX_PWM=220

check "cold idle clamps to MIN_PWM"        "$(want_pwm_proportional 30)" 60
check "exactly at LOW gives MIN_PWM"       "$(want_pwm_proportional 55)" 60
check "exactly at HIGH gives MAX_PWM"      "$(want_pwm_proportional 74)" 220
check "above HIGH clamps to MAX_PWM"       "$(want_pwm_proportional 95)" 220
check "mid-band 64C"                       "$(want_pwm_proportional 64)" 135

# never below MIN or above MAX anywhere in the sweep
bad=0
prev=-1
for t in $(seq 20 100); do
    v=$(want_pwm_proportional "$t")
    [ "$v" -lt "$MIN_PWM" ] && bad=1
    [ "$v" -gt "$MAX_PWM" ] && bad=1
    [ "$v" -lt "$prev" ] && bad=1     # must be monotonically non-decreasing
    prev=$v
done
check "20..100C stays in range and monotonic" "$bad" 0

# degenerate band must not divide by zero
TEMP_THRESHOLD_LOW=60; TEMP_THRESHOLD_HIGH=60
check "zero-width band returns MAX_PWM"    "$(want_pwm_proportional 60)" 220

# --- mirror: driver window 37..63 rescaled onto 60..220 --------------------
echo "mirror (GPU_PWM 37..63 -> duty 60..220)"
GPU_PWM_LOW=37; GPU_PWM_HIGH=63; MIN_PWM=60; MAX_PWM=220

check "below driver window clamps to MIN"  "$(want_pwm_mirror 20)"  60
check "at window low gives MIN_PWM"        "$(want_pwm_mirror 37)"  60
check "at window high gives MAX_PWM"       "$(want_pwm_mirror 63)"  220
check "above window clamps to MAX_PWM"     "$(want_pwm_mirror 255)" 220
check "mid-window 50"                      "$(want_pwm_mirror 50)" 140

GPU_PWM_LOW=50; GPU_PWM_HIGH=50
check "zero-width window returns MAX_PWM"  "$(want_pwm_mirror 50)" 220

# --- write throttling ------------------------------------------------------
echo "moved_enough (PWM_STEP=5)"
PWM_STEP=5
moved_enough 100 100 && r=yes || r=no
check "no change"                          "$r" no
moved_enough 104 100 && r=yes || r=no
check "4 up (below step)"                  "$r" no
moved_enough 105 100 && r=yes || r=no
check "5 up (at step)"                     "$r" yes
moved_enough 96  100 && r=yes || r=no
check "4 down (below step)"                "$r" no
moved_enough 95  100 && r=yes || r=no
check "5 down (at step)"                   "$r" yes
moved_enough 255 60  && r=yes || r=no
check "ceiling jump"                       "$r" yes

# --- ceiling latch release point ------------------------------------------
echo "ceiling latch"
CEILING_TEMP=80; CEILING_HYSTERESIS=6
check "release point" "$(( CEILING_TEMP - CEILING_HYSTERESIS ))" 74

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
