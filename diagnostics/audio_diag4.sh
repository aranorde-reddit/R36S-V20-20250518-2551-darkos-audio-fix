#!/bin/bash
# audio_diag4.sh - SPEAKER test.  HEADPHONES UNPLUGGED.  ~1 minute.
# Plays the "Front Center" voice clip N times per test at 100% volume.
# For each test, note how loud the SPEAKER was: silent / faint / clear / loud.

OUT="$(cd "$(dirname "$(realpath "$0")")" && pwd)/audio_diag4_out"
mkdir -p "$OUT"; LOG="$OUT/report4.txt"; : > "$LOG"
say() { echo "$*" | tee -a "$LOG"; }
S() { sudo -n "$@" 2>/dev/null || "$@"; }
run() { echo "\$ $*" >> "$LOG"; (eval "$*") >> "$LOG" 2>&1 || echo "(exit $?)" >> "$LOG"; }

CLIP=/usr/share/sounds/alsa/Front_Center.wav
[ -f "$CLIP" ] || { say "clip missing: $CLIP"; exit 1; }
S mount -t debugfs none /sys/kernel/debug 2>/dev/null

say "R36S speaker test 4 - $(date)   HEADPHONES UNPLUGGED"
run "amixer -c 0 sget 'Playback Path'"
run "S grep -E 'gpio-86 ' /sys/kernel/debug/gpio"
run "amixer -c 0 contents | grep -A2 -i jack"

OP=$(amixer -c 0 sget 'Playback Path' | grep -oE "Item0: '[^']+'" | cut -d"'" -f2)
OV=$(amixer -c 0 sget 'Playback' | grep -oE 'Front Left: [0-9]+' | grep -oE '[0-9]+$')
amixer -c 0 sset 'Playback' 255 >/dev/null 2>&1

CREG=/sys/kernel/debug/regmap/0-0020-rk817-codec/registers
PREG=/sys/kernel/debug/regmap/0-0020/registers
snap() {
  echo "--- snapshot $1" >> "$LOG"
  echo -n "codec regs (2e-45): " >> "$LOG"; S cat $CREG 2>/dev/null | awk '$1 >= "2e" && $1 <= "45" {printf "%s ", $0} END {print ""}' >> "$LOG"
  echo -n "codec regs (14-1b): " >> "$LOG"; S cat $CREG 2>/dev/null | awk '$1 >= "14" && $1 <= "1b" {printf "%s ", $0} END {print ""}' >> "$LOG"
  S cat $CREG > "$OUT/codec_regs_$1.txt" 2>/dev/null
  S cat /sys/kernel/debug/clk/clk_summary 2>/dev/null | grep -E 'i2s1' >> "$LOG"
  S cat /sys/kernel/debug/pinctrl/pinctrl/pinmux-pins 2>/dev/null | grep -E 'pin (8[1-5]|103) ' >> "$LOG"
  S grep -E 'gpio-103 ' /sys/kernel/debug/gpio >> "$LOG" 2>&1
}
play() { local i; for i in $(seq 1 "$1"); do aplay -q -D plughw:0,0 "$CLIP" >>"$LOG" 2>&1 || echo "(aplay exit $?)" >>"$LOG"; sleep 0.3; done; }
path() { amixer -c 0 sset 'Playback Path' "$1" >/dev/null 2>&1; sleep 0.3; echo "path=$(amixer -c 0 sget 'Playback Path' | grep -oE "Item0: '[^']+'")" >> "$LOG"; }

# GPIO3_A7 = gpio 103: first read it as an INPUT to learn its natural level
SPK=103
echo $SPK | S tee /sys/class/gpio/export >/dev/null 2>&1; sleep 0.3
echo in | S tee /sys/class/gpio/gpio$SPK/direction >/dev/null 2>&1; sleep 0.2
say "GPIO3_A7 natural level (as input): $(cat /sys/class/gpio/gpio$SPK/value 2>/dev/null)"
pin() { case "$1" in in) echo in | S tee /sys/class/gpio/gpio$SPK/direction >/dev/null;; *) echo out | S tee /sys/class/gpio/gpio$SPK/direction >/dev/null; echo "$1" | S tee /sys/class/gpio/gpio$SPK/value >/dev/null;; esac 2>/dev/null; sleep 0.3; echo "pin: $(S grep -E "gpio-$SPK " /sys/kernel/debug/gpio)" >> "$LOG"; }

snap idle
# --- how menus/games reach the codec: the ALSA "default" device
run "cat /home/ark/.asoundrc"
run "cat /etc/asound.conf"
run "cat /var/lib/alsa/asound.state | grep -A3 -E \"'Playback Path'|'Playback Volume'\""
say ""
say "Rate the SPEAKER for each test: silent / faint / clear / loud"
say "  0 : TWO plays through the 'default' device (the route menus/games use), path SPK"
pin in; path SPK
say "$(date +%T) test 0: default device"
aplay -q -D default "$CLIP" >>"$LOG" 2>&1 || echo "(aplay default exit $?)" >>"$LOG"; sleep 0.3
aplay -q -D default "$CLIP" >>"$LOG" 2>&1 || echo "(aplay default exit $?)" >>"$LOG"; sleep 3
say "  1 play : pin untouched, path SPK   (what worked for you)"
say "  2 plays: pin HIGH,      path SPK"
say "  3 plays: pin LOW,       path SPK"
say "  4 plays: pin HIGH,      path SPK_HP"
say "  5 plays: pin HIGH,      path HP"
say "  6 plays: pin LOW,       path HP"
sleep 3
t() { say "$(date +%T) test $1: pin=$2 path=$3"; pin "$2"; path "$3"; ( sleep 0.8; snap "test$1" ) & play "$1"; wait; sleep 3; }
t 1 in SPK
t 2 1  SPK
t 3 0  SPK
t 4 1  SPK_HP
t 5 1  HP
t 6 0  HP

pin in; echo $SPK | S tee /sys/class/gpio/unexport >/dev/null 2>&1
[ -n "$OP" ] && amixer -c 0 sset 'Playback Path' "$OP" >/dev/null 2>&1
[ -n "$OV" ] && amixer -c 0 sset 'Playback' "$OV" >/dev/null 2>&1
say ""
say "DONE. Send audio_diag4_out/report4.txt and your loudness rating for tests 0-6."
sleep 4
