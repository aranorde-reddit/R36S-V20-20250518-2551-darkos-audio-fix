#!/bin/bash
# audio_diag.sh  -  R36S clone / dArkOS audio diagnostic
#
# Run from EmulationStation (Tools) or over SSH.  Writes everything into a folder
# called  audio_diag_out  next to this script.  Unplug headphones before running.
# Nothing here is persistent: mixer state is restored at the end.

OUT="$(cd "$(dirname "$(realpath "$0")")" && pwd)/audio_diag_out"
mkdir -p "$OUT"
LOG="$OUT/report.txt"
: > "$LOG"

say() { echo "$*" | tee -a "$LOG"; }
sec() { echo "" | tee -a "$LOG"; echo "===== $* =====" | tee -a "$LOG"; }
run() { echo "\$ $*" >> "$LOG"; (eval "$*") >> "$LOG" 2>&1 || echo "(exit $?)" >> "$LOG"; }

S() { command -v sudo >/dev/null 2>&1 && sudo -n "$@" 2>/dev/null || "$@"; }

say "R36S audio diagnostic  -  $(date)"
say "Output folder: $OUT"
say "IMPORTANT: run with NO headphones plugged in."

# ---------------------------------------------------------------- system
sec "System"
run uname -a
run cat /etc/os-release
run cat /proc/cmdline
run cat /proc/device-tree/model
run cat /proc/device-tree/compatible
run "cat /proc/version"
run uptime

# ---------------------------------------------------------------- boot files
sec "Boot partition"
BOOTDIR=""
for d in /boot /media/boot /mnt/boot; do [ -f "$d/boot.ini" ] && BOOTDIR="$d" && break; done
[ -z "$BOOTDIR" ] && BOOTDIR=/boot
say "boot dir: $BOOTDIR"
run mount
run "ls -la $BOOTDIR"
run "cat $BOOTDIR/boot.ini"
cp "$BOOTDIR/boot.ini" "$OUT/boot.ini" 2>/dev/null
run "md5sum $BOOTDIR/*.dtb $BOOTDIR/dtb/*/*.dtb 2>/dev/null"
run "ls -la $BOOTDIR/dtb 2>/dev/null"

# the DTB the kernel is ACTUALLY running with
sec "Live device tree"
if [ -r /sys/firmware/fdt ]; then
  S cp /sys/firmware/fdt "$OUT/running.dtb" && S chmod 644 "$OUT/running.dtb"
  run "md5sum $OUT/running.dtb"
  say "copied /sys/firmware/fdt -> running.dtb"
else
  say "/sys/firmware/fdt not readable"
fi
run "ls /proc/device-tree/ | tr '\n' ' '"
run "ls /proc/device-tree/rk817-sound 2>/dev/null | tr '\n' ' '"
run "ls /proc/device-tree/i2c@ff180000/pmic@20/codec 2>/dev/null | tr '\n' ' '"

# ---------------------------------------------------------------- audio state
sec "ALSA"
run cat /proc/asound/cards
run aplay -l
run "amixer -c 0 contents"
run "amixer -c 0"
run "S alsactl -f - dump 2>/dev/null | head -200"
run "cat /var/lib/alsa/asound.state 2>/dev/null"
run "cat /etc/asound.conf 2>/dev/null"
run "cat /proc/bus/input/devices"
run "ps aux | grep -iE 'pulse|pipewire|headphone|audio' | grep -v grep"
run "systemctl list-units --type=service --no-pager 2>/dev/null | grep -iE 'audio|sound|headphone|alsa'"

# ---------------------------------------------------------------- kernel logs
sec "dmesg (full copy in dmesg.txt)"
S dmesg > "$OUT/dmesg.txt" 2>/dev/null || dmesg > "$OUT/dmesg.txt" 2>/dev/null
run "grep -iE 'rk817|codec|asoc|simple-audio|i2s|jack|spk|sound|dapm|widget|route' $OUT/dmesg.txt"

# ---------------------------------------------------------------- GPIO / pinctrl
sec "GPIO state"
S mount -t debugfs none /sys/kernel/debug 2>/dev/null
run "S cat /sys/kernel/debug/gpio"
run "S grep -iE 'pin 103 |pin 86 |gpio3-7|gpio2-22|spk|hp' /sys/kernel/debug/pinctrl/*/pinmux-pins 2>/dev/null"
run "for c in /sys/class/gpio/gpiochip*; do echo \"\$c label=\$(cat \$c/label) base=\$(cat \$c/base) ngpio=\$(cat \$c/ngpio)\"; done"

# work out linux gpio number for GPIO3_A7 (bank 3, pin 7)
BASE3=""
for c in /sys/class/gpio/gpiochip*; do
  l=$(cat "$c/label" 2>/dev/null)
  if [ "$l" = "gpio3" ] || [ "$l" = "/pinctrl/gpio3@ff270000" ]; then BASE3=$(cat "$c/base"); fi
done
[ -z "$BASE3" ] && BASE3=96
SPK=$((BASE3 + 7))
say "GPIO3_A7 (speaker amp enable) = gpio-$SPK   (bank base $BASE3)"

# ---------------------------------------------------------------- live amp test
sec "LIVE SPEAKER AMP TEST"
TEST=""
for f in /usr/share/sounds/alsa/Front_Center.wav /usr/share/sounds/alsa/Noise.wav; do [ -f "$f" ] && TEST="$f" && break; done
play() {  # play $1 times
  local n=$1 i
  for i in $(seq 1 "$n"); do
    if [ -n "$TEST" ]; then aplay -q "$TEST" >>"$LOG" 2>&1
    else timeout 2 speaker-test -t sine -f 440 -c 2 -l 1 >>"$LOG" 2>&1; fi
    sleep 0.4
  done
}

ORIG_PATH=$(amixer -c 0 sget 'Playback Path' 2>/dev/null | grep -oE "Item0: '[^']+'" | cut -d"'" -f2)
ORIG_VOL=$(amixer -c 0 sget 'Playback' 2>/dev/null | grep -oE 'Front Left: [0-9]+' | grep -oE '[0-9]+$')
say "current Playback Path='$ORIG_PATH'  Playback volume='$ORIG_VOL'"
amixer -c 0 sset 'Playback' 200 >/dev/null 2>&1

GPIO_OK=0
if [ -d /sys/class/gpio ]; then
  echo "$SPK" | S tee /sys/class/gpio/export >/dev/null 2>&1
  sleep 0.3
  if [ -d "/sys/class/gpio/gpio$SPK" ]; then
    echo out | S tee "/sys/class/gpio/gpio$SPK/direction" >/dev/null 2>&1 && GPIO_OK=1
  fi
fi
if [ $GPIO_OK -eq 1 ]; then say "sysfs export of gpio-$SPK OK"; else say "could not export gpio-$SPK via sysfs (busy or no sysfs gpio) - tests will still run without it"; fi
setspk() { [ $GPIO_OK -eq 1 ] && echo "$1" | S tee "/sys/class/gpio/gpio$SPK/value" >/dev/null 2>&1; }

say ""
say "Listen to the SPEAKER.  Sequence (each test = the sound played N times):"
say "  TEST A  x1 :  amp pin HIGH, Playback Path SPK"
say "  TEST B  x2 :  amp pin HIGH, Playback Path HP"
say "  TEST C  x3 :  amp pin LOW,  Playback Path SPK   (= how it is today)"
say "  TEST D  x4 :  amp pin LOW,  Playback Path HP"
say "Note which tests you HEARD from the speaker."
sleep 2

setspk 1; amixer -c 0 sset 'Playback Path' SPK >/dev/null 2>&1; sleep 0.5
say "$(date +%T) TEST A running"; run "S grep -E 'gpio-$SPK ' /sys/kernel/debug/gpio"; play 1; sleep 3

setspk 1; amixer -c 0 sset 'Playback Path' HP  >/dev/null 2>&1; sleep 0.5
say "$(date +%T) TEST B running"; play 2; sleep 3

setspk 0; amixer -c 0 sset 'Playback Path' SPK >/dev/null 2>&1; sleep 0.5
say "$(date +%T) TEST C running"; run "S grep -E 'gpio-$SPK ' /sys/kernel/debug/gpio"; play 3; sleep 3

setspk 0; amixer -c 0 sset 'Playback Path' HP  >/dev/null 2>&1; sleep 0.5
say "$(date +%T) TEST D running"; play 4; sleep 2

# restore
[ -n "$ORIG_PATH" ] && amixer -c 0 sset 'Playback Path' "$ORIG_PATH" >/dev/null 2>&1
[ -n "$ORIG_VOL" ]  && amixer -c 0 sset 'Playback' "$ORIG_VOL" >/dev/null 2>&1
if [ $GPIO_OK -eq 1 ]; then echo "$SPK" | S tee /sys/class/gpio/unexport >/dev/null 2>&1; fi

sec "Headphone-detect level (headphones UNPLUGGED)"
run "S grep -iE 'gpio-86 |headphone|hp' /sys/kernel/debug/gpio"
run "amixer -c 0 contents | grep -A2 -i jack"

say ""
say "DONE.  Copy the whole folder  audio_diag_out  (report.txt, running.dtb, dmesg.txt, boot.ini) and send it."
sleep 4
