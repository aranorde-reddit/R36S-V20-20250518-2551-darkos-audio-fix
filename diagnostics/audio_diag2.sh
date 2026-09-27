#!/bin/bash
# audio_diag2.sh  -  R36S clone / dArkOS audio test, round 2
# Max volume, loud tone.  START WITH HEADPHONES UNPLUGGED.  Plug them in only when told.
# Writes to  audio_diag2_out  next to this script.  Restores mixer state at the end.

OUT="$(cd "$(dirname "$(realpath "$0")")" && pwd)/audio_diag2_out"
mkdir -p "$OUT"; LOG="$OUT/report2.txt"; : > "$LOG"
say() { echo "$*" | tee -a "$LOG"; }
run() { echo "\$ $*" >> "$LOG"; (eval "$*") >> "$LOG" 2>&1 || echo "(exit $?)" >> "$LOG"; }
S() { command -v sudo >/dev/null 2>&1 && sudo -n "$@" 2>/dev/null || "$@"; }

say "R36S audio test round 2  -  $(date)"
say "HEADPHONES MUST BE UNPLUGGED NOW."
sleep 3

# ---- tone generation (1 s, 440 Hz, loud, stereo 16-bit 44.1k)
TONE="$OUT/tone.wav"
python3 - "$TONE" <<'PY' 2>>"$LOG"
import sys, wave, struct, math
f = wave.open(sys.argv[1], 'w'); f.setnchannels(2); f.setsampwidth(2); f.setframerate(44100)
n = 44100
frames = b''.join(struct.pack('<hh', *(2*[int(28000*math.sin(2*math.pi*440*i/44100))])) for i in range(n))
f.writeframes(frames); f.close()
PY
if [ ! -s "$TONE" ]; then TONE=/usr/share/sounds/alsa/Front_Center.wav; say "python tone failed, using $TONE"; fi
say "tone file: $TONE ($(stat -c %s "$TONE" 2>/dev/null) bytes)"

beep() { local i; for i in $(seq 1 "$1"); do aplay -q -D plughw:0,0 "$TONE" >>"$LOG" 2>&1 || echo "(aplay exit $?)" >>"$LOG"; sleep 0.35; done; }
regs() { # codec register snapshot
  echo "--- regmap snapshot: $1" >> "$LOG"
  for r in /sys/kernel/debug/regmap/0-0020/registers /sys/kernel/debug/regmap/*0020*/registers; do
    [ -r "$r" ] || S test -r "$r" || continue
    S awk '{ v=strtonum("0x"$1); if (v>=0x49 && v<=0x6f) printf "%s ", $0 } END {print ""}' "$r" >> "$LOG" 2>&1; break
  done
  if command -v i2cget >/dev/null 2>&1; then
    echo -n "i2c raw 0x49-0x6f: " >> "$LOG"
    for a in $(seq 73 111); do printf "%02x=%s " "$a" "$(S i2cget -f -y 0 0x20 $a 2>/dev/null)" >> "$LOG"; done; echo >> "$LOG"
  fi
}
path() { amixer -c 0 sset 'Playback Path' "$1" >/dev/null 2>&1; sleep 0.3; echo "Playback Path now: $(amixer -c 0 sget 'Playback Path' | grep -oE "Item0: '[^']+'")" >> "$LOG"; }

S mount -t debugfs none /sys/kernel/debug 2>/dev/null
run "ls /sys/kernel/debug/regmap/"
run "command -v i2cget i2cset python3 aplay speaker-test"

ORIG_PATH=$(amixer -c 0 sget 'Playback Path' 2>/dev/null | grep -oE "Item0: '[^']+'" | cut -d"'" -f2)
ORIG_VOL=$(amixer -c 0 sget 'Playback' 2>/dev/null | grep -oE 'Front Left: [0-9]+' | grep -oE '[0-9]+$')
say "saved state: path=$ORIG_PATH vol=$ORIG_VOL"
amixer -c 0 sset 'Playback' 255 >/dev/null 2>&1
run "amixer -c 0 sget 'Playback'"

SPK=103
echo $SPK | S tee /sys/class/gpio/export >/dev/null 2>&1; sleep 0.3
echo out | S tee /sys/class/gpio/gpio$SPK/direction >/dev/null 2>&1
amp() { echo "$1" | S tee /sys/class/gpio/gpio$SPK/value >/dev/null 2>&1; sleep 0.3; echo "amp pin: $(S grep -E "gpio-$SPK " /sys/kernel/debug/gpio)" >> "$LOG"; }

regs "idle before tests"

say ""
say "SPEAKER TESTS - count the beeps you hear from the SPEAKER:"
say "  1 beep : amp LOW,  path SPK      (today's behaviour)"
say "  2 beeps: amp HIGH, path SPK"
say "  3 beeps: amp HIGH, path HP"
say "  4 beeps: amp HIGH, path SPK_HP"
say "  5 beeps: amp LOW,  path HP"
say "  6 beeps: amp LOW,  path SPK_HP"
sleep 3

t() { # n amp path
  say "$(date +%T) test $1: amp=$2 path=$3"
  amp "$2"; path "$3"
  ( sleep 0.6; regs "during test $1"; cat /proc/asound/card0/pcm0p/sub0/hw_params >> "$LOG" 2>&1 ) &
  beep "$1"; wait; sleep 3
}
t 1 0 SPK
t 2 1 SPK
t 3 1 HP
t 4 1 SPK_HP
t 5 0 HP
t 6 0 SPK_HP

say ""
say ">>> NOW PLUG IN HEADPHONES.  You have 15 seconds. <<<"
sleep 15
run "S grep -E 'gpio-86 ' /sys/kernel/debug/gpio"
run "amixer -c 0 contents | grep -A2 -i jack"
say "headphone test: 2 beeps, path HP, amp LOW  - listen in the HEADPHONES"
amp 0; path HP; beep 2; sleep 2
say "headphone test: 3 beeps, path SPK, amp LOW - listen in the HEADPHONES and speaker"
path SPK; beep 3; sleep 2
say ">>> You can unplug headphones now."

# restore
[ -n "$ORIG_PATH" ] && amixer -c 0 sset 'Playback Path' "$ORIG_PATH" >/dev/null 2>&1
[ -n "$ORIG_VOL" ]  && amixer -c 0 sset 'Playback' "$ORIG_VOL" >/dev/null 2>&1
amp 0; echo $SPK | S tee /sys/class/gpio/unexport >/dev/null 2>&1
say ""
say "DONE. Send audio_diag2_out/report2.txt and tell me: which beep-counts you heard from the SPEAKER, and whether the HEADPHONES played."
sleep 4
