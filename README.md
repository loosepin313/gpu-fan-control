# GPU Fan Control

Chassis fan control for **passively cooled GPU cards** — AMD Instinct MI25 / MI50 / MI60 and other headless cards that ship without a fan and rely on case airflow.

Reads a GPU temperature sensor and drives a motherboard fan header over PWM, with a proportional control law, a hard temperature ceiling that overrides everything, and the calibration tooling needed to size the curve properly.

## Why this exists

A passively cooled MI50 has no fan of its own. Whatever cooling it gets comes from a case fan, and nothing on the board knows the GPU exists — the BIOS fan curve is watching CPU and chipset probes. Left alone, the card sits at 90 °C+ junction under load and throttles.

The naive fix — "read the GPU temp, set the fan high above 65 °C" — works, but gets three things wrong in practice, all of which are documented below because they cost real debugging time:

1. **The fan header label does not match the chip channel.**
2. **`temp1` is not the sensor that matters.**
3. **A two-speed fan law cannot hold a temperature target.**

## Quick start

```bash
sudo ./install.sh
sudo fan_probe.sh          # find which PWM channel your fan is actually on
sudo nano /etc/gpu-fan-control.conf
sudo systemctl restart gpu-fan-control.service
journalctl -u gpu-fan-control.service -f
```

`install.sh` copies the script, the service unit, a config file (never overwriting an existing one) and the helper tools. The shipped config is a **worked example** tuned for one specific board/GPU pair — treat it as a starting point, not a default.

## How the control law works

```
duty = MIN_PWM                                   junction <= TEMP_THRESHOLD_LOW
duty = MIN_PWM + (T - LOW) * (MAX-MIN) / span    inside the band
duty = MAX_PWM                                   junction >= TEMP_THRESHOLD_HIGH

override: junction >= CEILING_TEMP  ->  duty 255, latched until
          junction <= CEILING_TEMP - CEILING_HYSTERESIS
```

Three modes, selected with `CONTROL_MODE`:

| mode | behaviour |
|---|---|
| `proportional` | ramps linearly across the temperature band. Default, and the only one that can hold a target. |
| `step` | the original v1 two-position hysteresis. |
| `mirror` | rescales the GPU driver's own fan demand onto your fan (see below). |

The ceiling override is separate from the mode and always wins. It is **latched**: once the ceiling trips, the fan stays at full blast until the sensor falls back by `CEILING_HYSTERESIS`, so a reading hovering on the limit cannot flap the fan between extremes every poll.

Set `CEILING_TEMP` as an emergency brake, not the operating target — see [backing off for noise](#backing-off-for-noise). If the band's `TEMP_THRESHOLD_HIGH` sits at or near the ceiling, the override fires in normal operation and you get sudden full-blast bursts instead of a smooth ramp.

## Configuration

`/etc/gpu-fan-control.conf`. Every option has a default in the script; the config overrides them.

| option | meaning |
|---|---|
| `GPU_PCI` | PCI address of the GPU to read (disambiguates multi-GPU boxes) |
| `GPU_HWMON_NAME` | hwmon name of the GPU, usually `amdgpu` |
| `FAN_HWMON_NAME` | Super I/O chip name: `nct6779`, `it8628`, `it87`, … |
| `PWM_CHANNEL` | **chip** channel number — see *Finding your fan header* |
| `GPU_TEMP_LABEL` | which labelled sensor to control on: `junction`, `edge`, `mem` |
| `CONTROL_MODE` | `proportional` \| `step` \| `mirror` |
| `TEMP_THRESHOLD_LOW` / `_HIGH` | band edges in °C; fan is at `MIN_PWM` / `MAX_PWM` there |
| `MIN_PWM` / `MAX_PWM` | duty range, 0–255 |
| `CEILING_TEMP` / `CEILING_HYSTERESIS` | hard ceiling and its release margin (0 disables) |
| `TEMP_AVG_N` | temperature samples averaged before the law sees them |
| `PWM_STEP` | minimum duty change that triggers a sysfs write |
| `POLL_INTERVAL` | seconds between polls |
| `GPU_PWM_LOW` / `GPU_PWM_HIGH` | driver demand window, for `mirror` mode |
| `FAN_OFF_BELOW_C` | stop the fan below this temp — leave empty for passive cards |
| `GPU_POWER_LIMIT_W` | optional power cap applied at startup via `power1_cap` |
| `FAILSAFE_AFTER` | consecutive failed reads before forcing `MAX_PWM` |
| `DISCOVERY_RETRY_SECONDS` | startup retry interval when a device is missing (default 30) |

Devices are found by hwmon **name** and PCI address, never by `hwmonN` index — the kernel reassigns those between boots and kernel updates, which is what broke the original hardcoded variant.

## Finding your fan header

This is the trap. The number printed on the motherboard (`FAN1`, `FAN3`, …) does **not** reliably match the channel number in the Super I/O chip (`pwm1`, `pwm3`, …).

On a MACHINIST X99 G7, the header printed **FAN3** is chip channel **pwm1**. Point the script at `pwm3` and it writes to a dead header: the loop runs, logs happily, and the fan does exactly nothing.

```bash
sudo fan_probe.sh
```

It puts each candidate channel into manual mode, drives it 0 → 255, and watches every tach input for a response. The channel that moves a tach is your fan. Original `enable`/`pwm` values are restored on exit, including on Ctrl-C. It also watches CPU temperature and aborts if you happen to grab the CPU cooler channel.

```
fan controller : /sys/class/hwmon/hwmon2 (nct6779)
baseline       : fan1=3300 fan2=812  cpu=31C
--- channel 1 (enable=0 pwm=255) ---
    pwm=255 -> fan1=5212 fan2=812
    pwm=0   -> fan1=934  fan2=812
    ==> RESPONSIVE: channel 1 controls a fan
--- channel 3 (enable=0 pwm=0) ---
    pwm=255 -> fan1=3300 fan2=812
    pwm=0   -> fan1=3300 fan2=812
    no tach change - dead header or hardware-controlled
```

`hw_scan.sh` lists all hwmon devices, every labelled GPU temperature, and all fan headers with their PWM values.

## Which temperature to control on

Do not assume `temp1_input` is "the GPU temperature". On MI50/MI60 the sensors are:

| label | what it is |
|---|---|
| `edge` | board edge / inlet temperature — slow, and flattering |
| `junction` | die hotspot — the one that runs away first |
| `mem` | HBM |

Measured on a real box at 35% fan duty: **edge 60 °C while junction was 91 °C**. Controlling on edge means the fan thinks everything is fine while the die is cooking. Set `GPU_TEMP_LABEL="junction"`.

## Calibrating

`tools/calibrate_fan.sh` measures both halves of the curve:

```bash
sudo tools/calibrate_fan.sh --duty "90 120 160 200 255" \
     --load-cmd "tools/loadgen.sh 130 3"
```

It stops the service, sweeps duty → RPM, then holds each duty under load and records steady-state temperatures and power. It restores the channel and restarts the service afterwards.

From the output you get a thermal resistance per duty:

```
R = (peak junction - idle junction) / average watts
P_max = (ceiling - idle) / R          # the most heat your fan can remove
```

**Use a load that reproduces your real workload power.** A synthetic compute burn (matrix multiply, hash loop) under-reports power badly on inference cards — it saturates ALUs without touching HBM bandwidth. A hand-written HIP burn on an MI50 topped out around 140–165 W while the real inference workload ran 175–225 W. Calibrating against the synthetic number gives a curve that is too quiet for the real load. `tools/loadgen.sh` drives any OpenAI-compatible endpoint instead, at configurable concurrency.

## Worked example: MI50 in a X99 G7

One 120 mm case fan on the header printed FAN3 (= chip `pwm1`), 225 W power cap, real LLM inference load at 3 concurrent streams.

Duty → RPM, and duty → peak junction under real load:

| duty | % | RPM | avg W | peak junction | R (°C/W) |
|---|---|---|---|---|---|
| 90 | 35 | 2350 | 170 | **84 → 92 soak** | 0.365 |
| 120 | 47 | 2990 | 146 | 78 | 0.329 |
| 160 | 62 | 3729 | 203 | 91 | 0.300 |
| 200 | 78 | 4397 | 164 | 78 | 0.293 |
| 255 | 100 | 5212 | 168 | 74 | 0.262 |

Three things fall out of this table.

**The old `MIN_PWM=90` was letting junction sit at 84–92 °C.** The two-step law was undersized for a 175–225 W workload.

**Diminishing returns above duty 200.** Duty 200 and duty 255 land within 4 °C of each other, so `MAX_PWM=220` — the last 35 units of duty are noise, not cooling.

**Airflow was not the only constraint.** With an 80 °C ceiling configured, the override did fire (duty → 255, latched) — and junction *still* held 80–86 °C at 5200 RPM. At duty 255, R = 0.262 °C/W, so from a 30 °C idle junction the fan can only ever remove about `(80 − 30) / 0.262 ≈ 190 W`. Past that, the fan is no longer the problem; heat input is.

Setting `GPU_POWER_LIMIT_W=180` closes the gap. Re-measured under the same 3-stream load:

```
peak junction = 76 C   (ceiling 80 C)
samples over 80 C: 0 / 40
fan at full blast: 0 / 40 samples
idle: duty 60 = 1660 RPM, junction 36 C
```

That is the honest lesson: **a fan curve has a power ceiling.** Below it you get silence; above it you need a power cap, better airflow, or a bigger fan.

### Backing off for noise

An 80 °C junction ceiling was over-engineering. AMD's guidance for the MI50 puts **ideal junction under load at 85–100 °C** (edge 60–80 °C), with junction critical around 100 °C and throttling above that. Holding 76 °C was spending a lot of acoustic budget for no reliability gain.

Re-deriving the band from the same table, with the ceiling demoted to an emergency brake at 95 °C:

| | v2.0 tuning | quiet tuning |
|---|---|---|
| band | 55 → 74 °C | 58 → 86 °C |
| duty range | 60 – 220 | 50 – 180 |
| **loop gain** | **8.4 duty/°C** | **4.6 duty/°C** |
| idle | 1664 RPM | 1386 RPM |
| ceiling | 80 °C (frequently tripping) | 95 °C (never tripped) |

Measured under the same 3-stream load:

| metric | v2.0 | quiet |
|---|---|---|
| avg fan | 4209 RPM | **2802 RPM** |
| peak fan | 4687 RPM | 3391 RPM |
| avg duty | 199 | 113 |
| avg junction | 73.3 °C | 77.1 °C |
| peak junction | 76 °C | 84 °C |
| peak mem | 58 °C | 64 °C |

**A third quieter in fan speed for 4 °C of junction.** Two things made it work:

- The narrow 19 °C band was the actual cause of "ramps up too fast". Widening it to 28 °C nearly halves the loop gain, so the fan creeps up instead of lunging.
- Duty 180 holds junction ~87 °C at the 192 W peaks while duty 220 holds ~84 °C. Six hundred RPM for three degrees is a bad trade.

The controller peaked at duty 142 and never reached `MAX_PWM=180`, so there is still headroom — the ceiling at 95 °C stayed 11 °C away from ever firing.

The power cap is what makes this possible. Uncapped at 225 W, holding junction under 95 °C needs duty ~255 (5200 RPM). Capped at 180 W, duty 180 is enough. **The cap is not protecting the card here — it is what keeps the fan off its top end.**

## Can I just use the GPU's own fan percentage?

Yes, and it is implemented as `CONTROL_MODE="mirror"` — but it is not the primary law, and the reason is instructive.

A passively cooled MI50 exposes no `fan*_input` under the amdgpu hwmon, but the driver *does* compute a fan demand anyway: `pwm1`, labelled `GPU Fan`. It genuinely tracks temperature — it moved 37 → 63 as junction went 29 → 80 °C.

The problem is the range. The driver only ever asks for **37–63 out of 255 (14–24%)**, a window sized for the small fan this card does not have. Mirrored raw, it settles around 83–85 °C — the gain is too low to arrest the junction rise. Mirror mode rescales that window onto `MIN_PWM..MAX_PWM`, which fixes the range but not the low gain. Proportional-on-junction is what actually hits a target.

## Troubleshooting

**Fan ignores the script, loop looks healthy.** Wrong `PWM_CHANNEL`. Run `fan_probe.sh`. The startup log warns explicitly: `WARNING: fanN reads 0 RPM. If the fan is spinning, this header is the wrong one`.

**Fan at full speed and won't come down.** The ceiling latch is engaged — check the actual sensor, not the fan. It releases at `CEILING_TEMP - CEILING_HYSTERESIS`.

**Fan flaps between two speeds.** Raise `TEMP_AVG_N` and `PWM_STEP`, and widen the band. Also check you are not controlling on a laggy sensor (`edge`).

**Fan lunges up suddenly under load.** The band is too narrow — `MAX_PWM` is being reached only a few degrees above `MIN_PWM`, so the loop gain is high. Widen `TEMP_THRESHOLD_HIGH` toward the top of the card's safe junction range and lower `MAX_PWM` to the smallest duty that holds your target. See the worked example: gain 8.4 → 4.6 duty/°C was the whole fix.

**Service fails after reboot.** Usually the Super I/O driver registering late. The unit has `Wants=lm_sensors.service` and a 15 s `ExecStartPre` sleep for this. If your board needs longer, increase the sleep.

**Service restart-looping.** If the GPU it points at has been moved to another machine, or the PCI address changed, the old versions exited immediately and systemd restarted them forever — one deployment reached **9,796 restarts**. The script now retries discovery in-process and logs what it can actually see:

```
ERROR: device discovery failed
  no hwmon named 'amdgpu' for PCI 0000:03:00.0
  present hwmon devices: acpitz it8628 jc42 nvme amdgpu k10temp ...
  retrying every 30s (Ctrl-C to stop)
```

Fix the `GPU_PCI` in the config. Hard configuration errors (a `PWM_CHANNEL` that does not exist) still exit, and the unit's `StartLimitBurst=10` stops the loop so the unit lands in a visible `failed` state instead of spinning silently.

**"no temp label 'junction'".** Not every GPU exposes junction/edge/mem — a Cezanne iGPU reports only `edge`. The script warns, lists the labels that do exist, and falls back to `temp1_input` rather than refusing to start. Set `GPU_TEMP_LABEL` to one of the listed labels.

**`power1_cap` not writable.** Needs root; the service runs as root. If the write fails the script logs it and carries on.

## Files

| file | purpose |
|---|---|
| `gpu-fan-control.sh` | the control loop |
| `gpu-fan-control.conf` | configuration (worked example, MI50 + nct6779) |
| `gpu-fan-control.service` | systemd unit |
| `fan_probe.sh` | find which PWM channel your fan is on |
| `hw_scan.sh` | list hwmon devices, GPU temps, fan headers |
| `tools/calibrate_fan.sh` | duty → RPM and duty → temperature calibration |
| `tools/loadgen.sh` | real GPU load via an OpenAI-compatible endpoint |
| `install.sh` / `uninstall.sh` | install / remove |

## Requirements

Linux with a hardware monitoring driver for your Super I/O chip (`nct6779`, `it87`, … — `sensors-detect` will find it), root, systemd. No dependencies beyond coreutils and `curl` for the load generator.

## Tests

```bash
./tests/test_control_law.sh
```

20 assertions on the control maths — band clamping, monotonicity across a 20–100 °C sweep, degenerate zero-width bands (no divide-by-zero), the mirror rescaling, write throttling, and the ceiling latch release point. Pure arithmetic, so it runs on any machine with no hardware attached.

## Hardware notes

The shipped config is a worked example for a **passively cooled MI50 on a MACHINIST X99 G7** (`amdgpu` at `0000:04:00.0`, `nct6779`, header printed FAN3 = chip `pwm1`). It is not a sensible default for anything else.

Check what your machine actually has before configuring — PCI addresses move between machines and kernels, and not every GPU exposes the same sensors:

```bash
hw_scan.sh
lspci -d 1002:
for f in /sys/class/hwmon/hwmon*/temp*_label; do echo "$f = $(cat $f)"; done
```

## What changed in v2

Against v1 (the two hardcoded/dynamic hysteresis scripts):

- **One script, not two.** The hardcoded variant was a footgun (hwmon indices shift between boots); the dynamic variant is now the only one, and it is config-driven.
- **Config moved out of the code** into `/etc/gpu-fan-control.conf`. v1 required editing the script to change a threshold.
- **Proportional control** replaces two-position hysteresis, plus a latched hard-ceiling override.
- **Sensor selection by label** (`junction`/`edge`/`mem`) instead of assuming `temp1`.
- **v1 could stop the fan entirely** below the low threshold — actively wrong for a passively cooled card. `FAN_OFF_BELOW_C` is now empty by default and documented as dangerous.
- **Sensor-read failsafe** (`FAILSAFE_AFTER`) — v1 logged "Error reading GPU temperature" and carried on at whatever speed it happened to be at.
- **Optional power cap** via `power1_cap`, because airflow alone has a limit.
- **New tooling**: `fan_probe.sh` (header↔channel mapping) and `tools/calibrate_fan.sh` + `tools/loadgen.sh` (measured fan curve).
- **Robust startup**: in-process discovery retry, label fallback, actionable diagnostics, and a systemd start limit so hard config errors stop looping.
- **Tests** for the control maths.

## License

MIT License — see [LICENSE](LICENSE)

Copyright (c) 2026 Chris Harris
