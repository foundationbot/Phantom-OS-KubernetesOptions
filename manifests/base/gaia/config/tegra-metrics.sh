#!/bin/sh
# =============================================================================
# gaia — Tegra/Jetson textfile metrics collector (lightweight)
# =============================================================================
# Reads only the FAST Tegra sysfs sensors and writes a node-exporter textfile
# (atomic rename). node-exporter serves that static .prom instantly, so a slow
# sensor read stalls only THIS writer, never the Prometheus scrape.
#
# Why this exists: node-exporter's thermal_zone/hwmon collectors block on this
# Jetson — reading `gpu-thermal` hangs >3s when the GPU is power-gated, and the
# collector reads every zone. Here gpu-thermal is read behind `timeout` so it
# degrades to a missing sample instead of hanging.
#
# Emits (namespace tegra_):
#   tegra_thermal_temp_celsius{zone}          tj/cpu/soc/gpu temps
#   tegra_rail_voltage_volts{chip,rail}       INA3221/INA238 bus voltage
#   tegra_rail_current_amps{chip,rail}        INA current
#   tegra_rail_power_watts{chip,rail}         INA power (where exposed)
#   tegra_gpu_freq_hertz{device}              GPU devfreq current freq
#   tegra_collector_gpu_thermal_ok            1 if gpu-thermal read succeeded
# =============================================================================
set -u
SYS="${SYS_PATH:-/host/sys}"
OUT_DIR="${OUT_DIR:-/textfile}"
OUT="$OUT_DIR/tegra.prom"
INTERVAL="${INTERVAL:-10}"
GPU_TIMEOUT="${GPU_TIMEOUT:-1}"   # bounded read for the blocking gpu-thermal

# read a sysfs file with a timeout; echoes value or nothing
rd() { timeout "$1" cat "$2" 2>/dev/null; }
# integer-millis -> unit (divide by $2) as a float
div() { awk "BEGIN{printf \"%.3f\", $1/$2}" 2>/dev/null; }

collect() {
  tmp="$(mktemp "$OUT.XXXXXX")" || return   # same fs as OUT -> atomic mv; not *.prom -> ignored mid-write
  {
    echo "# TYPE tegra_thermal_temp_celsius gauge"
    gpu_ok=1
    for z in "$SYS"/class/thermal/thermal_zone*; do
      [ -e "$z/temp" ] || continue
      ty="$(cat "$z/type" 2>/dev/null)"; [ -n "$ty" ] || continue
      case "$ty" in
        *gpu*) raw="$(rd "$GPU_TIMEOUT" "$z/temp")"; [ -n "$raw" ] || gpu_ok=0 ;;
        *)     raw="$(rd 2 "$z/temp")" ;;
      esac
      [ -n "$raw" ] && printf 'tegra_thermal_temp_celsius{zone="%s"} %s\n' "$ty" "$(div "$raw" 1000)"
    done
    echo "# TYPE tegra_collector_gpu_thermal_ok gauge"
    echo "tegra_collector_gpu_thermal_ok $gpu_ok"

    echo "# TYPE tegra_rail_voltage_volts gauge"
    echo "# TYPE tegra_rail_current_amps gauge"
    echo "# TYPE tegra_rail_power_watts gauge"
    for h in "$SYS"/class/hwmon/hwmon*; do
      chip="$(cat "$h/name" 2>/dev/null)"
      case "$chip" in ina*) : ;; *) continue ;; esac
      for f in "$h"/in*_input; do
        [ -e "$f" ] || continue
        n="$(basename "$f" | tr -cd '0-9')"
        lbl="$(cat "$h/in${n}_label" 2>/dev/null)"; [ -n "$lbl" ] || lbl="in$n"
        mv="$(rd 1 "$f")";              [ -n "$mv" ] && printf 'tegra_rail_voltage_volts{chip="%s",rail="%s"} %s\n' "$chip" "$lbl" "$(div "$mv" 1000)"
        ca="$(rd 1 "$h/curr${n}_input")";  [ -n "$ca" ] && printf 'tegra_rail_current_amps{chip="%s",rail="%s"} %s\n' "$chip" "$lbl" "$(div "$ca" 1000)"
        pw="$(rd 1 "$h/power${n}_input")"; [ -n "$pw" ] && printf 'tegra_rail_power_watts{chip="%s",rail="%s"} %s\n' "$chip" "$lbl" "$(div "$pw" 1000000)"
      done
    done

    echo "# TYPE tegra_fan_pwm gauge"        # 0-255 duty
    echo "# TYPE tegra_fan_rpm gauge"        # tachometer
    for h in "$SYS"/class/hwmon/hwmon*; do
      nm="$(cat "$h/name" 2>/dev/null)"
      case "$nm" in
        pwmfan)   p="$(rd 1 "$h/pwm1")"; [ -n "$p" ] && printf 'tegra_fan_pwm{fan="%s"} %s\n' "$nm" "$p" ;;
        pwm_tach) r="$(rd 1 "$h/rpm")";  [ -n "$r" ] && printf 'tegra_fan_rpm{fan="%s"} %s\n' "$nm" "$r" ;;
      esac
    done

    echo "# TYPE tegra_gpu_freq_hertz gauge"
    for d in "$SYS"/class/devfreq/gpu-*; do
      [ -e "$d/cur_freq" ] || continue
      f="$(rd 1 "$d/cur_freq")"; [ -n "$f" ] && printf 'tegra_gpu_freq_hertz{device="%s"} %s\n' "$(basename "$d")" "$f"
    done
  } > "$tmp" 2>/dev/null
  chmod 644 "$tmp"          # mktemp makes 0600; node-exporter runs as nobody
  mv -f "$tmp" "$OUT"
}

while :; do collect; sleep "$INTERVAL"; done
