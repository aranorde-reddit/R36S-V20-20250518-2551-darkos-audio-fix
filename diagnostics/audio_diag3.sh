#!/bin/bash
# audio_diag3.sh - codec register / clock check during playback.
# PLUG HEADPHONES IN BEFORE RUNNING and listen in them.  Takes ~30 s.

OUT="$(cd "$(dirname "$(realpath "$0")")" && pwd)/audio_diag3_out"
mkdir -p "$OUT"; LOG="$OUT/report3.txt"; : > "$LOG"
say() { echo "$*" | tee -a "$LOG"; }
S() { sudo -n "$@" 2>/dev/null || "$@"; }
run() { echo "\$ $*" >> "$LOG"; (eval "$*") >> "$LOG" 2>&1 || echo "(exit $?)" >> "$LOG"; }

say "R36S audio diag 3 - $(date)   (headphones should be plugged in)"
S mount -t debugfs none /sys/kernel/debug 2>/dev/null

run "S ls -la /sys/kernel/debug/regmap/"
REG=""
for r in $(S ls -d /sys/kernel/debug/regmap/*0020* 2>/dev/null); do [ -n "$r" ] && REG="$r/registers" && break; done
say "regmap file: ${REG:-none found}"
run "S ls /sys/kernel/debug/pinctrl/"
PMX=$(S ls -d /sys/kernel/debug/pinctrl/*/ 2>/dev/null | head -1)

snap() {   # $1 = label
  echo "" >> "$LOG"; echo "---------- SNAPSHOT: $1 ----------" >> "$LOG"
  if [ -n "$REG" ]; then
    echo "codec regs 0x49-0x6f:" >> "$LOG"
    S cat "$REG" 2>/dev/null | awk '$1 >= "49" && $1 <= "6f" {printf "%s ", $0} END {print ""}' >> "$LOG"
    S cat "$REG" > "$OUT/regmap_$1.txt" 2>/dev/null
  fi
  echo "clocks:" >> "$LOG"
  S cat /sys/kernel/debug/clk/clk_summary 2>/dev/null | grep -iE 'i2s|mclk|clk_summary|enable' | head -20 >> "$LOG"
  echo "pinmux (GPIO2_C1..C5 = pins 81-85, GPIO3_A7 = 103):" >> "$LOG"
  [ -n "$PMX" ] && S cat "$PMX/pinmux-pins" 2>/dev/null | grep -E 'pin (8[1-5]|103) ' >> "$LOG"
  cat /proc/asound/card0/pcm0p/sub0/status 2>/dev/null >> "$LOG"
}

# save + max volume
OP=$(amixer -c 0 sget 'Playback Path' | grep -oE "Item0: '[^']+'" | cut -d"'" -f2)
OV=$(amixer -c 0 sget 'Playback' | grep -oE 'Front Left: [0-9]+' | grep -oE '[0-9]+$')
amixer -c 0 sset 'Playback' 255 >/dev/null 2>&1

TONE="$OUT/tone.wav"
python3 - "$TONE" <<'PY' 2>>"$LOG"
import sys, wave, struct, math
f = wave.open(sys.argv[1], 'w'); f.setnchannels(2); f.setsampwidth(2); f.setframerate(44100)
f.writeframes(b''.join(struct.pack('<hh', *(2*[int(28000*math.sin(2*math.pi*440*i/44100))])) for i in range(44100*3))); f.close()
PY
[ -s "$TONE" ] || TONE=/usr/share/sounds/alsa/Front_Center.wav

run "S grep -E 'gpio-86 ' /sys/kernel/debug/gpio"
run "amixer -c 0 contents | grep -A2 -i jack"
snap "idle"

say "playing 3 s tone, Playback Path = HP  (listen in headphones)"
amixer -c 0 sset 'Playback Path' HP >/dev/null 2>&1; sleep 0.3
( sleep 1.2; snap "playing_HP" ) &
aplay -q -D plughw:0,0 "$TONE" >>"$LOG" 2>&1; wait; sleep 1

say "playing 3 s tone, Playback Path = SPK_HP"
amixer -c 0 sset 'Playback Path' SPK_HP >/dev/null 2>&1; sleep 0.3
( sleep 1.2; snap "playing_SPK_HP" ) &
aplay -q -D plughw:0,0 "$TONE" >>"$LOG" 2>&1; wait; sleep 1

snap "after"
[ -n "$OP" ] && amixer -c 0 sset 'Playback Path' "$OP" >/dev/null 2>&1
[ -n "$OV" ] && amixer -c 0 sset 'Playback' "$OV" >/dev/null 2>&1
say "DONE - send audio_diag3_out (report3.txt + regmap_*.txt)."
sleep 3
