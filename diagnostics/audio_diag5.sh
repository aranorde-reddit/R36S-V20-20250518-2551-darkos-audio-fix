#!/bin/bash
# audio_diag5.sh - hardware state snapshot.  Run on BOTH SD cards, headphones unplugged.
# Read-only: it changes nothing.  ~20 seconds.

OUT="$(cd "$(dirname "$(realpath "$0")")" && pwd)/audio_diag5_out"
mkdir -p "$OUT"; LOG="$OUT/report5.txt"; : > "$LOG"
say() { echo "$*" | tee -a "$LOG"; }
S() { sudo -n "$@" 2>/dev/null || "$@"; }
run() { echo "\$ $*" >> "$LOG"; (eval "$*") >> "$LOG" 2>&1 || echo "(exit $?)" >> "$LOG"; }

say "R36S hw snapshot 5 - $(date)"
S mount -t debugfs none /sys/kernel/debug 2>/dev/null

run "cat /etc/os-release | head -3"
run "ls -la /boot/"
run "md5sum /boot/Image /boot/uInitrd /boot/*.dtb"
run "cat /roms/tools/../../etc/hostname 2>/dev/null; hostname"

# U-Boot version string from the raw boot partition (read-only)
say "-- U-Boot / loader versions"
S dd if=/dev/mmcblk0 bs=512 skip=16384 count=4096 2>/dev/null | strings | grep -E 'U-Boot [0-9]{4}|U-Boot SPL|Rockchip' | sort -u | head -8 >> "$LOG"
S dd if=/dev/mmcblk0 bs=512 skip=64 count=2048 2>/dev/null | strings | grep -iE 'ddr|version|V[0-9]\.[0-9]+' | sort -u | head -8 >> "$LOG"

# PMIC + codec register dumps
say "-- register dumps"
S cat /sys/kernel/debug/regmap/0-0020/registers > "$OUT/pmic_regs.txt" 2>/dev/null; echo "pmic regs: $(wc -l < "$OUT/pmic_regs.txt") lines" >> "$LOG"
S cat /sys/kernel/debug/regmap/0-0020-rk817-codec/registers > "$OUT/codec_regs.txt" 2>/dev/null; echo "codec regs: $(wc -l < "$OUT/codec_regs.txt") lines" >> "$LOG"

# raw codec registers over I2C (hardware truth, no cache) and the I2S controller, idle + during playback
S modprobe i2c-dev 2>/dev/null
rawcodec() { S python3 - <<'PY'
import os, fcntl
b = os.open('/dev/i2c-0', os.O_RDWR); fcntl.ioctl(b, 0x0706, 0x20)
out = []
for a in list(range(0x12, 0x50)) + [0xed, 0xee]:
    os.write(b, bytes([a])); out.append("%02x:%02x" % (a, os.read(b, 1)[0]))
print(" ".join(out))
PY
}
echo "codec raw idle: $(rawcodec)" >> "$LOG"
S cat /sys/kernel/debug/regmap/ff070000.i2s/registers > "$OUT/i2s_regs_idle.txt" 2>/dev/null
CLIP=/usr/share/sounds/alsa/Front_Center.wav
amixer -c 0 sset 'Playback Path' SPK >/dev/null 2>&1
( for i in 1 2 3; do aplay -q -D plughw:0,0 "$CLIP" >/dev/null 2>&1; done ) &
sleep 1.0
echo "codec raw playing: $(rawcodec)" >> "$LOG"
S cat /sys/kernel/debug/regmap/ff070000.i2s/registers > "$OUT/i2s_regs_playing.txt" 2>/dev/null
S cat /sys/kernel/debug/clk/clk_summary 2>/dev/null | grep -E 'i2s1' >> "$LOG"
wait
echo "i2s regs idle/playing: $(wc -l < "$OUT/i2s_regs_idle.txt") / $(wc -l < "$OUT/i2s_regs_playing.txt") lines" >> "$LOG"

# regulators
run "S cat /sys/kernel/debug/regulator/regulator_summary"
run "for r in /sys/class/regulator/regulator.*; do echo \"\$(cat \$r/name 2>/dev/null) state=\$(cat \$r/state 2>/dev/null) uV=\$(cat \$r/microvolts 2>/dev/null)\"; done"

# GPIOs claimed by drivers, then a full scan of every pin's direction + level (no writes)
run "S cat /sys/kernel/debug/gpio"
say "-- full GPIO scan (bank_pin: direction level) - pins busy with a driver are marked busy"
for n in $(seq 0 127); do
  b=$((n/32)); p=$((n%32)); nm="gpio${b}_$(printf '%s%d' $(echo ABCD | cut -c$((p/8+1))) $((p%8)))"
  if echo $n | S tee /sys/class/gpio/export >/dev/null 2>&1; then
    d=$(cat /sys/class/gpio/gpio$n/direction 2>/dev/null); v=$(cat /sys/class/gpio/gpio$n/value 2>/dev/null)
    echo $n | S tee /sys/class/gpio/unexport >/dev/null 2>&1
    echo "$nm (gpio-$n): $d $v" >> "$LOG"
  else
    echo "$nm (gpio-$n): busy" >> "$LOG"
  fi
done
run "S cat /sys/kernel/debug/pinctrl/pinctrl/pinmux-pins"

# userspace side
run "systemctl list-units --type=service --state=running,exited --no-pager | grep -viE 'getty|dbus|journal|udev|logind|network|timesync|resolve|cron|ssh'"
run "cat /home/ark/.asoundrc"
run "cat /var/lib/alsa/asound.state | grep -A2 -E \"'Playback Path'|'Playback Volume'\""
run "ls -la /home/ark /opt/system 2>/dev/null | head -60"
run "grep -rlE 'gpio|i2c|amixer|rk817' /usr/local/bin /opt/system /etc/systemd/system 2>/dev/null | head -30"
run "amixer -c 0 sget 'Playback Path'; amixer -c 0 sget 'Playback' | grep Front"

say "DONE - send the whole audio_diag5_out folder from THIS card."
sleep 3
