#!/bin/bash
# audio_diag7.sh  -  DarkOS card.  HEADPHONES UNPLUGGED.  ~1.5 minutes.
# Tests two candidates found by comparing the two cards:
#   (a) GPIO0_A0 / GPIO0_B3 / GPIO0_B4 driven like the working kernel does (possible amp power/enable)
#   (b) DAC volume re-applied while playing (codec applied-volume readback 0x39/0x3a)
# Nothing is persistent.

OUT="$(cd "$(dirname "$(realpath "$0")")" && pwd)/audio_diag7_out"
mkdir -p "$OUT"; LOG="$OUT/report7.txt"; : > "$LOG"
say() { echo "$*" | tee -a "$LOG"; }
S() { sudo -n "$@" 2>/dev/null || "$@"; }
CLIP=/usr/share/sounds/alsa/Front_Center.wav
S modprobe i2c-dev 2>/dev/null

reg() { S python3 - "$@" <<'PY'
import sys, os, fcntl
b = os.open('/dev/i2c-0', os.O_RDWR); fcntl.ioctl(b, 0x0706, 0x20)
a = int(sys.argv[1], 16)
if len(sys.argv) > 2: os.write(b, bytes([a, int(sys.argv[2], 16)]))
os.write(b, bytes([a])); print("%02x=%02x" % (a, os.read(b, 1)[0]))
PY
}
vol() { echo "   codec VOL set 31/32=$(reg 31 | cut -d= -f2)/$(reg 32 | cut -d= -f2)  applied 39/3a=$(reg 39 | cut -d= -f2)/$(reg 3a | cut -d= -f2)  38=$(reg 38 | cut -d= -f2)" >> "$LOG"; }

gexp() { echo "$1" | S tee /sys/class/gpio/export >/dev/null 2>&1; sleep 0.15; }
gset() { echo out | S tee /sys/class/gpio/gpio$1/direction >/dev/null 2>&1; echo "$2" | S tee /sys/class/gpio/gpio$1/value >/dev/null 2>&1; }
gin()  { echo in | S tee /sys/class/gpio/gpio$1/direction >/dev/null 2>&1; }
gunexp() { echo "$1" | S tee /sys/class/gpio/unexport >/dev/null 2>&1; }
gstate() { echo "   pins: $(for n in 0 11 12 103; do echo -n "gpio-$n=$(cat /sys/class/gpio/gpio$n/direction 2>/dev/null)/$(cat /sys/class/gpio/gpio$n/value 2>/dev/null) "; done)" >> "$LOG"; }

say "R36S diag 7 - $(date)   HEADPHONES UNPLUGGED"
OP=$(amixer -c 0 sget 'Playback Path' | grep -oE "Item0: '[^']+'" | cut -d"'" -f2)
OV=$(amixer -c 0 sget 'Playback' | grep -oE 'Front Left: [0-9]+' | grep -oE '[0-9]+$')
amixer -c 0 sset 'Playback' 255 >/dev/null 2>&1; amixer -c 0 sset 'Playback Path' SPK >/dev/null 2>&1

for n in 0 11 12 103; do gexp $n; done
say "natural levels: gpio0_A0=$(cat /sys/class/gpio/gpio0/value) gpio0_B3=$(cat /sys/class/gpio/gpio11/value) gpio0_B4=$(cat /sys/class/gpio/gpio12/value) gpio3_A7=$(cat /sys/class/gpio/gpio103/value)"
echo "idle:" >> "$LOG"; vol

play() { local i; for i in $(seq 1 "$1"); do aplay -q -D plughw:0,0 "$CLIP" >>"$LOG" 2>&1; sleep 0.25; done; }
t() { say "$(date +%T) TEST $1 ($2 plays): $3"; gstate; ( sleep 1.5; echo "   during test $1:" >> "$LOG"; vol ) & play "$2"; wait; sleep 3; }

say "Count the plays you hear from the SPEAKER for each test:"
gin 0; gin 11; gin 12; gset 103 1
t 1 1 "baseline (LED pins untouched, spk pin HIGH)"

gset 0 1
t 2 2 "gpio0_A0 HIGH (as working kernel), spk pin HIGH"

gset 0 1; gset 11 0; gset 12 1
t 3 3 "gpio0_A0 HIGH, B3 LOW, B4 HIGH (full working-kernel LED state), spk pin HIGH"

gset 103 0
t 4 4 "same LED state, spk pin LOW"

gin 0; gin 11; gin 12; gset 103 1
say "$(date +%T) TEST 5 (5 plays): LED pins untouched, spk HIGH, DAC volume re-written 1.5 s in"
gstate; ( sleep 1.5; reg 31 00 >/dev/null; reg 32 00 >/dev/null; echo "   after rewrite (test 5):" >> "$LOG"; vol ) & play 5; wait; sleep 3

gset 0 1; gset 11 0; gset 12 1; gset 103 1
say "$(date +%T) TEST 6 (6 plays): LED state + spk HIGH + DAC volume re-written 1.5 s in"
gstate; ( sleep 1.5; reg 31 00 >/dev/null; reg 32 00 >/dev/null; echo "   after rewrite (test 6):" >> "$LOG"; vol ) & play 6; wait; sleep 2

# restore
gin 0; gin 11; gin 12; gin 103
for n in 0 11 12 103; do gunexp $n; done
[ -n "$OP" ] && amixer -c 0 sset 'Playback Path' "$OP" >/dev/null 2>&1
[ -n "$OV" ] && amixer -c 0 sset 'Playback' "$OV" >/dev/null 2>&1
say ""
say "DONE. Tell me which tests (1-6) you heard from the speaker. Send report7.txt."
sleep 4
