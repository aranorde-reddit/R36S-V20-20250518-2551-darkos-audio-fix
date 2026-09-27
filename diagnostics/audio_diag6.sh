#!/bin/bash
# audio_diag6.sh  -  DarkOS card only.  HEADPHONES UNPLUGGED.  ~1 minute.
# Applies the codec register write the working kernel does ("restart class-D") while the
# voice clip plays, and tells us whether the speaker comes alive.  Nothing is persistent.

OUT="$(cd "$(dirname "$(realpath "$0")")" && pwd)/audio_diag6_out"
mkdir -p "$OUT"; LOG="$OUT/report6.txt"; : > "$LOG"
say() { echo "$*" | tee -a "$LOG"; }
S() { sudo -n "$@" 2>/dev/null || "$@"; }
run() { echo "\$ $*" >> "$LOG"; (eval "$*") >> "$LOG" 2>&1 || echo "(exit $?)" >> "$LOG"; }
CLIP=/usr/share/sounds/alsa/Front_Center.wav

say "R36S diag 6 (class-D restart experiment) - $(date)"
S modprobe i2c-dev 2>/dev/null
run "ls -la /dev/i2c-*"

# i2c helper: reg <addr>            -> read one codec register
#             reg <addr> <value>    -> write one codec register, then read back
reg() { S python3 - "$@" <<'PY'
import sys, os, fcntl
bus = os.open('/dev/i2c-0', os.O_RDWR)
fcntl.ioctl(bus, 0x0706, 0x20)          # I2C_SLAVE_FORCE, RK817 at 0x20
a = int(sys.argv[1], 16)
if len(sys.argv) > 2:
    os.write(bus, bytes([a, int(sys.argv[2], 16)]))
os.write(bus, bytes([a])); v = os.read(bus, 1)[0]
print("reg 0x%02x = 0x%02x" % (a, v))
PY
}
say "i2c sanity: chip id regs (expect 0x81 / 0x7a)"; reg ed >> "$LOG"; reg ee >> "$LOG"
dump() { echo "--- regs $1: $(for a in 2f 30 38 3d 3f 40 41; do reg $a | sed 's/reg //'; done | tr '\n' ' ')" >> "$LOG"; }

OP=$(amixer -c 0 sget 'Playback Path' | grep -oE "Item0: '[^']+'" | cut -d"'" -f2)
OV=$(amixer -c 0 sget 'Playback' | grep -oE 'Front Left: [0-9]+' | grep -oE '[0-9]+$')
amixer -c 0 sset 'Playback' 255 >/dev/null 2>&1
amixer -c 0 sset 'Playback Path' SPK >/dev/null 2>&1

SPK=103
echo $SPK | S tee /sys/class/gpio/export >/dev/null 2>&1; sleep 0.2
echo out | S tee /sys/class/gpio/gpio$SPK/direction >/dev/null 2>&1
pin() { echo "$1" | S tee /sys/class/gpio/gpio$SPK/value >/dev/null 2>&1; }

dump idle
play8() { local i; for i in $(seq 1 8); do aplay -q -D plughw:0,0 "$CLIP" >>"$LOG" 2>&1; sleep 0.2; done; }

say ""
say "Each test plays 'Front Center' 8 times (~12 s). Listen for the SPEAKER starting mid-way."
say "TEST A: pin HIGH, then class-D restart write 2 s in"
pin 1; ( play8 ) & sleep 2; dump "A-before-write"; reg 41 f7 >> "$LOG"; dump "A-after-write"; wait; sleep 2

say "TEST B: pin LOW, restart write 2 s in"
pin 0; ( play8 ) & sleep 2; reg 41 f7 >> "$LOG"; dump "B-after-write"; wait; sleep 2

say "TEST C: pin HIGH, restart write + DAC power reg (2f=03) 2 s in"
pin 1; ( play8 ) & sleep 2; reg 2f 03 >> "$LOG"; reg 41 f7 >> "$LOG"; dump "C-after-write"; wait; sleep 2

say "TEST D: pin HIGH, full vendor speaker sequence 2 s in (40=a5, 41=f7, 38=10, 2f=03, 30=02, 3e=1f)"
pin 1; ( play8 ) & sleep 2; for kv in "40 a5" "41 f7" "38 10" "2f 03" "30 02" "3e 1f"; do reg $kv >> "$LOG"; done; dump "D-after-write"; wait; sleep 1

pin 0; echo $SPK | S tee /sys/class/gpio/unexport >/dev/null 2>&1
[ -n "$OP" ] && amixer -c 0 sset 'Playback Path' "$OP" >/dev/null 2>&1
[ -n "$OV" ] && amixer -c 0 sset 'Playback' "$OV" >/dev/null 2>&1
say ""
say "DONE. Tell me for A, B, C, D: silent / started mid-way / played from the start. Send report6.txt."
sleep 4
