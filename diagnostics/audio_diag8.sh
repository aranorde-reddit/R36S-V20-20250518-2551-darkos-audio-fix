#!/bin/bash
# audio_diag8.sh  -  DarkOS card.  HEADPHONES UNPLUGGED.  ~1.5 minutes.  REBOOT afterwards.
# Replays the working kernel's codec "kick" sequences over I2C while the clip plays.
# Test N = N plays.  Tell me which tests you hear from the speaker.

OUT="$(cd "$(dirname "$(realpath "$0")")" && pwd)/audio_diag8_out"
mkdir -p "$OUT"; LOG="$OUT/report8.txt"; : > "$LOG"
say() { echo "$*" | tee -a "$LOG"; }
S() { sudo -n "$@" 2>/dev/null || "$@"; }
CLIP=/usr/share/sounds/alsa/Front_Center.wav
S modprobe i2c-dev 2>/dev/null

# w "aa=vv aa=vv ..."  writes codec regs in order (with 1 ms gaps); r "aa aa" reads
w() { S python3 - "$@" <<'PY'
import sys, os, fcntl, time
b = os.open('/dev/i2c-0', os.O_RDWR); fcntl.ioctl(b, 0x0706, 0x20)
for kv in sys.argv[1].split():
    a, v = kv.split('='); os.write(b, bytes([int(a,16), int(v,16)])); time.sleep(0.001)
PY
}
r() { S python3 - "$@" <<'PY'
import sys, os, fcntl
b = os.open('/dev/i2c-0', os.O_RDWR); fcntl.ioctl(b, 0x0706, 0x20)
out=[]
for a in sys.argv[1].split():
    os.write(b, bytes([int(a,16)])); out.append("%s=%02x" % (a, os.read(b,1)[0]))
print(" ".join(out))
PY
}
snap() { echo "   [$1] $(r '12 13 14 15 17 2f 30 31 32 38 39 3a 3d 3f 40 41 42 45 46 47 48 4a 4b 4c')" >> "$LOG"; }
ms() { python3 -c "import time; time.sleep($1/1000)"; }

say "R36S diag 8 (codec kick/reset replay) - $(date)   HEADPHONES UNPLUGGED"
OP=$(amixer -c 0 sget 'Playback Path' | grep -oE "Item0: '[^']+'" | cut -d"'" -f2)
OV=$(amixer -c 0 sget 'Playback' | grep -oE 'Front Left: [0-9]+' | grep -oE '[0-9]+$')
amixer -c 0 sset 'Playback' 255 >/dev/null 2>&1; amixer -c 0 sset 'Playback Path' SPK >/dev/null 2>&1
echo 103 | S tee /sys/class/gpio/export >/dev/null 2>&1; sleep 0.2
echo out | S tee /sys/class/gpio/gpio103/direction >/dev/null 2>&1; echo 1 | S tee /sys/class/gpio/gpio103/value >/dev/null 2>&1
snap idle

play() { local i; for i in $(seq 1 "$1"); do aplay -q -D plughw:0,0 "$CLIP" >>"$LOG" 2>&1; sleep 0.25; done; }
dac_restart() {   # rk817_restart_dac_digital_clk
  w "2f=08"; ms 1; w "15=07"; ms 1; w "15=0f"; ms 1; w "2f=03"
}
pll_cycle() {     # PLL power down / up
  w "47=01"; ms 1; w "47=00"; ms 1
}
full_reset() {    # rk817_reset + playback power-up list + SPK path (working-kernel sequence)
  w "14=40 30=02 48=00 15=ff 43=58 44=2d 45=0c 47=00 42=04 46=a5 15=00"
  ms 2
  w "17=40 30=02 43=58 44=2d 47=00 4c=00 49=00 4a=00 4c=20 13=f4 38=00 31=00 32=00 4b=0f 4e=0f 35=02"
  w "15=0f"; ms 1
  dac_restart; pll_cycle
  w "38=10 40=a5 41=f7 31=00 32=00"
}

say "TEST 1 (1 play): baseline"
( sleep 1.5; snap "t1 during" ) & play 1; wait; sleep 2

say "TEST 2 (2 plays): DAC digital-clock restart 1.5 s in"
( sleep 1.5; dac_restart; ms 5; snap "t2 after kick" ) & play 2; wait; sleep 2

say "TEST 3 (3 plays): DAC restart + PLL power-cycle 1.5 s in"
( sleep 1.5; dac_restart; pll_cycle; ms 5; snap "t3 after kick" ) & play 3; wait; sleep 2

say "TEST 4 (4 plays): FULL codec reset + working-kernel bring-up 1.5 s in"
( sleep 1.5; full_reset; ms 5; snap "t4 after reset" ) & play 4; wait; sleep 2

say "TEST 5 (5 plays): full reset again BEFORE playing (codec re-initialised, then stream starts)"
full_reset; snap "t5 before play"; ( sleep 1.5; snap "t5 during" ) & play 5; wait; sleep 2

say "TEST 6 (6 plays): write applied-volume regs 39/3a directly to 00 while playing"
( sleep 1.5; w "39=00 3a=00"; ms 5; snap "t6 after write" ) & play 6; wait; sleep 1

echo 0 | S tee /sys/class/gpio/gpio103/value >/dev/null 2>&1; echo 103 | S tee /sys/class/gpio/unexport >/dev/null 2>&1
[ -n "$OP" ] && amixer -c 0 sset 'Playback Path' "$OP" >/dev/null 2>&1
[ -n "$OV" ] && amixer -c 0 sset 'Playback' "$OV" >/dev/null 2>&1
say ""
say "DONE. Which of tests 1-6 did the speaker play?  Send report8.txt.  Reboot the device afterwards."
sleep 4
