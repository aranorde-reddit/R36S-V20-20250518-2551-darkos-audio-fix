#!/bin/bash
# Install Audio Fix.sh  v2.2  -  dArkOS on the R36S clone V20 2025-05-18 (2551 batch)
# Fixes "no sound at all" on this board and makes the audio behave. Run once from Options > Tools, then reboot.
# Works as a first install and as an upgrade over any earlier version of this fix (replaced in place; nothing of the
# old version is left behind).
#
# What it installs - one small background service (a bash script, about 1 MB of RAM, no CPU while idle, no polling):
#   - Kicks the RK817 codec's audio PLL (DAC bias down -> DAC digital clock off/on -> PLL power-cycle -> bias on), which
#     the stock kernel does at every playback start and the dArkOS 4.4 kernel does not. At boot, after every headphone
#     plug/unplug, whenever something else changes the audio path, and after resume. Every kick is verified.
#   - Switches speaker/headphones itself the moment the jack changes (dArkOS's hotkey daemon has the jack polarity
#     backwards on this board; its wrong switch is undone within milliseconds) and drives the speaker-enable line
#     GPIO3_A7.
#   - Sets the headphone amplifier level (HP_ATT below) - less idle hiss.
#   - Volume scale: EmulationStation and the volume keys use a 0-100% control called "Master": 0% = mute,
#     1% = -49.5 dB ... 100% = 0 dB, the hardware maximum. The service turns every change of Master into the codec's
#     own volume, so the codec stays the one real volume control (games that talk to the hardware directly follow it
#     too). The volume can never go up by itself - only by a key press. 2 dB per press.
#   - Links the menu-music folder (EASYROMS/bgmusic).
# Codec registers are accessed with atomic SMBus transactions only (the kernel talks to this chip constantly - it is
# also the CPU voltage regulator and battery gauge - so split reads could return the wrong register).
#
# Safety: the installer tests register access on the chip before changing anything, backs up whatever is installed,
# installs, verifies, and then either deletes the backup or puts everything back exactly as it was by itself.
# The screen is also saved as tools/audio_fix_install.txt. "Uninstall Audio Fix.sh" removes everything.

HP_ATT=15  # headphone level: 15 = quietest, least hiss (default) ... 0 = loudest, most hiss (dArkOS's own setting).
           # Each 3 lower = 3 dB louder headphones AND 3 dB more hiss. The speaker is not affected.
VOL_RANGE=50   # on-screen volume range in dB: 1% = -(VOL_RANGE - VOL_RANGE/100) dB ... 100% = 0 dB. 40-60 sensible.

S() { sudo -n "$@"; }
printf '\033c'
TOOLS="$(cd "$(dirname "$(realpath "$0")")" && pwd)"
REPORT="$TOOLS/audio_fix_install.txt"
exec > >(tee "$REPORT") 2>&1                                    # everything below is shown AND saved to tools/audio_fix_install.txt
echo "Installing RK817 audio fix v2.2...   $(date)"
stop() { echo "$1"; echo; echo "(This screen is also saved as tools/audio_fix_install.txt)"; sleep 12; exit 1; }

# ---------------------------------------------------------------- pre-flight (nothing is changed before this passes)
MISSING=""
for t in bash python3 aplay amixer alsactl od stdbuf modprobe systemctl md5sum; do command -v "$t" >/dev/null 2>&1 || MISSING="$MISSING $t"; done
[ -n "$MISSING" ] && stop "Missing tools:$MISSING - nothing installed."
stdbuf -oL true 2>/dev/null || stop "stdbuf does not work on this system - nothing installed."
[ "${BASH_VERSINFO[0]}" -ge 5 ] || stop "bash 5 or newer needed - nothing installed."
case "$HP_ATT" in [0-9]|1[0-5]) ;; *) stop "HP_ATT must be a number from 0 to 15 (it is '$HP_ATT') - nothing installed." ;; esac
case "$VOL_RANGE" in [3-8][0-9]|9[0-5]) ;; *) stop "VOL_RANGE must be a number from 30 to 95 (it is '$VOL_RANGE') - nothing installed." ;; esac
[ -n "$(cat /proc/asound/card0/id 2>/dev/null)" ] || stop "sound card 0 not found - nothing installed."
S true 2>/dev/null || stop "sudo does not work here - nothing installed."
S modprobe i2c-dev 2>/dev/null; [ -e /dev/i2c-0 ] || stop "/dev/i2c-0 not available - nothing installed."

# ---------------------------------------------------------------- the one-shot register helper (Python, runs only for a moment)
NEWH=$(mktemp /tmp/rk817-codec.XXXXXX) || stop "cannot create a temp file - nothing installed."
trap 'rm -f "$NEWH"' EXIT
cat > "$NEWH" <<'PY'
#!/usr/bin/python3 -SI
# rk817-codec v2.2: one-shot register helper for the audio fix.   kick | hp <0-15> | state | selftest | master-remove
# Every register access is ONE SMBus transaction: the kernel does the "set register + read value" as a single combined
# transfer under the bus lock. (Two separate transfers are not safe: the kernel talks to this chip many times a second
# - it is also the CPU's voltage regulator and the battery gauge - and could slip in between.)
import os, sys, time, fcntl, signal, stat, struct, array
for _s in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT): signal.signal(_s, signal.SIG_IGN)   # finish the sequence; it lasts < 0.5 s
I2C_SLAVE_FORCE, I2C_SMBUS, BYTE_DATA = 0x0706, 0x0720, 2
ARGS = '=BBxxI' + ('Q' if struct.calcsize('P') == 8 else 'I')   # struct i2c_smbus_ioctl_data {u8 rw; u8 cmd; u32 size; data*}
fd, chip = None, True

def _open():
    global fd, chip
    fd = os.open(os.environ.get('RK817_I2C', '/dev/i2c-0'), os.O_RDWR)
    chip = stat.S_ISCHR(os.fstat(fd).st_mode)                     # a plain file = a test image of the registers
    if chip: fcntl.ioctl(fd, I2C_SLAVE_FORCE, 0x20)                 # RK817 @0x20

def _smbus(rw, reg, val=0):
    data = array.array('B', [val & 0xff] + [0] * 33)                # union i2c_smbus_data (34 bytes); kernel fills byte 0
    fcntl.ioctl(fd, I2C_SMBUS, struct.pack(ARGS, rw, reg, BYTE_DATA, data.buffer_info()[0]))
    return data[0]

def r(a):
    if not chip: os.lseek(fd, a, 0); return os.read(fd, 1)[0]
    return _smbus(1, a)

def w(a, v):
    if not chip: os.lseek(fd, a, 0); os.write(fd, bytes([v & 0xff]))
    else: _smbus(0, a, v)
    time.sleep(0.001)

def settle():
    # the bits the kick owns must end in their working state: 2f bit3 = 0 (DAC bias on), 15 bit3 = 1 (DAC clock on),
    # 47 bit0 = 0 (PLL on). Only those bits are touched, always from a fresh read.
    fixed, bad = [], []
    for a, m, on in ((0x2f, 0x08, 0), (0x15, 0x08, 0x08), (0x47, 0x01, 0)):
        try:
            g = r(a)
            if g & m != on:
                w(a, (g & ~m) | on); fixed.append('%02x was %02x' % (a, g))
                if r(a) & m != on: bad.append('%02x' % a)
        except OSError:
            bad.append('%02x' % a)
    return fixed, bad

def kick():
    # replays rk817_restart_dac_digital_clk_and_apll from the Rockchip driver
    s2f, s15, s47 = r(0x2f), r(0x15), r(0x47)
    try:
        w(0x2f, s2f | 0x08)                                         # DAC bias power down
        w(0x15, s15 & ~0x08)                                        # DAC digital clock off
        w(0x15, s15 | 0x08)                                         # DAC digital clock on
        w(0x47, s47 | 0x01)                                         # PLL power down
        time.sleep(0.0002)
        w(0x47, s47 & ~0x01)                                        # PLL power up
        w(0x2f, s2f & ~0x08)                                        # DAC bias on
    finally:
        fixed, bad = settle()                                       # runs even if a write failed half-way
    rv = (r(0x39), r(0x3a))
    time.sleep(0.4)
    applied = r(0x39)
    note = 'registers ok' if not (fixed or bad) else 'fixed: %s%s' % (', '.join(fixed) or '-', ('; STILL WRONG: ' + ', '.join(bad)) if bad else '')
    print('kick done, applied-volume readback = %02x/%02x, %s' % (rv[0], rv[1], note))
    return 0 if applied != 0xff and not bad else 1                  # non-zero = kick did not take, caller retries

def hp(att):
    # 0x3e: bit 4 = anti-pop stage on, bits 3:0 = its attenuation in dB (0 = loudest ... 15 = quietest)
    v = 0x10 | att
    for _ in (1, 2):
        w(0x3e, v)
        if r(0x3e) == v: return 0
    print('hp: 3e reads %02x, wanted %02x' % (r(0x3e), v)); return 1

cmd = sys.argv[1] if len(sys.argv) > 1 else 'kick'
if cmd == 'master-remove':
    # delete the audio fix's own "Master" volume control (only user-made controls can be deleted; hardware ones refuse)
    try:
        cfd = os.open('/dev/snd/controlC0', os.O_RDWR)
    except OSError as e:
        print('master-remove failed: %s' % e); sys.exit(2)
    try:
        fcntl.ioctl(cfd, 0xC0405519, struct.pack('=IiII44sI', 0, 2, 0, 0, b'Master Playback Volume', 0))   # ELEM_REMOVE
        print('master removed'); sys.exit(0)
    except OSError as e:
        if e.errno == 2: print('master not present'); sys.exit(0)  # ENOENT from the ioctl: no such control
        print('master-remove failed: %s' % e); sys.exit(2)
try:
    _open()
    if cmd == 'hp':
        att = int(sys.argv[2]) if len(sys.argv) > 2 else -1
        if not 0 <= att <= 15: print('hp: level must be 0..15'); sys.exit(2)
        sys.exit(hp(att))
    if cmd == 'state':
        print(' '.join('%02x=%02x' % (a, r(a)) for a in (0x15, 0x2f, 0x31, 0x38, 0x39, 0x3d, 0x3e, 0x47))); sys.exit(0)
    if cmd == 'selftest':
        ids = [(r(0xed) << 8) | r(0xee) for _ in range(5)]
        v = r(0x3e); w(0x3e, v)                                     # harmless write: same value back
        ok = all(i & 0xfff0 == 0x8170 for i in ids) and r(0x3e) == v
        print('selftest %s: chip id %s' % ('ok' if ok else 'FAILED', ' '.join('%04x' % i for i in ids))); sys.exit(0 if ok else 1)
    sys.exit(kick())
except SystemExit:
    raise
except Exception as e:
    print('%s failed: %s' % (cmd, e)); sys.exit(2)
PY
ST=$(S python3 -SI "$NEWH" selftest 2>&1)
echo "New register access, tested on the chip: $ST"
case "$ST" in *"selftest ok: chip id"*) ;; *) stop "The new register access does not work on this device - nothing installed, the current fix is untouched." ;; esac

# ---------------------------------------------------------------- back up whatever is installed now
BK=/usr/local/lib/rk817-audio-fix.backup
MUSIC=/home/ark/.emulationstation/music
FILES="/usr/local/bin/rk817-codec /usr/local/bin/rk817-audio-kick.sh /usr/local/bin/rk817-audio-kick.py /etc/systemd/system/rk817-audio-kick.service /lib/systemd/system-sleep/rk817-audio-kick /usr/local/bin/amixer"
PREV="none"                                                     # anything of this fix already installed? (any version)
for f in $FILES; do [ "$f" = /usr/local/bin/amixer ] && continue; [ -e "$f" ] && PREV="an earlier version"; done
[ -e "$BK" ] && stop "A backup from an earlier, unfinished run is still in $BK - nothing touched. Send me this screen."
WAS_ENABLED=$(systemctl is-enabled rk817-audio-kick.service 2>/dev/null)
WAS_ACTIVE=$(systemctl is-active rk817-audio-kick.service 2>/dev/null)
MASTER_WAS=0; MO=$(amixer -c 0 cget name='Master Playback Volume' 2>/dev/null) && MASTER_WAS=1
[ "$MASTER_WAS" = 1 ] && case "$MO" in *"values=2,min=0,max=100,"*) ;; *) stop "A volume control named Master already exists and is not the audio fix's own - nothing installed. Send me this screen." ;; esac
HV0=$(amixer -c 0 cget name='Playback Volume' 2>/dev/null | sed -n 's/^ *: values=\([0-9]*\).*/\1/p')
MUSIC_WAS=0; { [ -e "$MUSIC" ] || [ -L "$MUSIC" ]; } && MUSIC_WAS=1
sum() { S md5sum "$1" 2>/dev/null | cut -d' ' -f1; }
S mkdir -p "$BK" || stop "cannot create $BK - nothing installed."
NB=0
for f in $FILES; do
  n=$(echo "$f" | tr / _)
  if [ -e "$f" ] || [ -L "$f" ]; then
    S cp -a "$f" "$BK/$n" && [ -n "$(sum "$f")" ] && [ "$(sum "$f")" = "$(sum "$BK/$n")" ] || { S rm -rf "$BK"; stop "backup of $f failed - nothing installed."; }
    echo "present $f" | S tee -a "$BK/manifest" >/dev/null; NB=$((NB + 1))
  else
    echo "absent $f" | S tee -a "$BK/manifest" >/dev/null
  fi
done
[ "$(wc -l < "$BK/manifest" 2>/dev/null)" = 6 ] || { S rm -rf "$BK"; stop "backup list incomplete - nothing installed."; }
if [ "$PREV" = none ]; then echo "First install."; else echo "Upgrade: $PREV is installed - backed up ($NB files) before replacing it."; fi

# ---------------------------------------------------------------- install v2.2 (each file written to .new, then renamed into place)
IFAIL=""
put() { S chmod "$2" "$1.new" && S mv -f "$1.new" "$1" || IFAIL="$IFAIL $1"; }
S cp "$NEWH" /usr/local/bin/rk817-codec.new || IFAIL="$IFAIL rk817-codec.new"
put /usr/local/bin/rk817-codec 755

sed -e "s/__HP_ATT__/$HP_ATT/" -e "s/__VOL_RANGE__/$VOL_RANGE/" <<'SH' | S tee /usr/local/bin/rk817-audio-kick.sh.new >/dev/null
#!/bin/bash
# rk817-audio-kick v2.2 - RK817 codec audio-PLL kick daemon for dArkOS (R36S clone V20 2551), shell edition.
# Event-driven: blocks on the headphone-jack input device and on "alsactl monitor"; no polling, no timers.
export LC_ALL=C                                                  # plain "." decimals for the sub-second timers
LOG=${LOG:-/tmp/rk817-audio-kick.log}
HELPER=${HELPER:-/usr/local/bin/rk817-codec}
AMIXER=${AMIXER:-/usr/bin/amixer}
SYSGPIO=${SYSGPIO:-/sys/class/gpio}
GPIO=103                                                        # GPIO3_A7 = speaker enable, active high
HP_ATT=__HP_ATT__                                               # headphone anti-pop attenuation, dB (0 loudest ... 15 quietest)
VOL_RANGE=__VOL_RANGE__                                         # on-screen volume: 1% = -(range) dB ... 100% = 0 dB, 0% = mute
ALSACTL=${ALSACTL:-alsactl}
log() { printf '%(%H:%M:%S)T %s\n' -1 "$*" >> "$LOG" 2>/dev/null; }
trap '' HUP                                                     # a hang-up signal never stops the service
now() { printf '%(%s)T' -1; }

gpio_set() {
  [ -d "$SYSGPIO/gpio$GPIO" ] || { echo $GPIO > "$SYSGPIO/export" 2>/dev/null; sleep 0.1; }
  echo out > "$SYSGPIO/gpio$GPIO/direction" 2>/dev/null
  echo "$1" > "$SYSGPIO/gpio$GPIO/value" 2>/dev/null || log "gpio: cannot set gpio$GPIO"
}
jack_plugged() { "$AMIXER" -c 0 cget iface=CARD,name='Headphone Jack' 2>/dev/null | grep -q 'values=on'; }
get_path()     { "$AMIXER" -c 0 sget 'Playback Path' 2>/dev/null | sed -n "s/.*Item0: '\([^']*\)'.*/\1/p" | head -1; }
set_path()     { "$AMIXER" -c 0 -q sset 'Playback Path' "$1" >/dev/null 2>&1; }
hp_tweak() {   # headphone level (the driver resets it on every switch to headphones); $1 = log it
  local out
  if out=$("$HELPER" hp "$HP_ATT" 2>&1); then [ -n "$1" ] && log "headphone level -$HP_ATT dB"
  else log "headphone level NOT applied: ${out:-helper error}"; fi
}

# ---- on-screen volume: "Master" (0-100, what EmulationStation and the volume keys use) drives the codec volume
master_get() {   # only OUR control counts: 2 values, range 0-100 (a foreign "Master" is ignored)
  local o; o=$("$AMIXER" -c 0 cget name='Master Playback Volume' 2>/dev/null)
  case "$o" in *"values=2,min=0,max=100,"*) printf '%s\n' "$o" | sed -n 's/^ *: values=\([0-9]*\).*/\1/p' ;; esac
}
hw_get()     { "$AMIXER" -c 0 cget name='Playback Volume' 2>/dev/null | sed -n 's/^ *: values=\([0-9]*\).*/\1/p'; }
m_to_raw() {   # % -> codec value (255 = 0 dB, 95/255 dB per step); 0% = 0 = mute
  if [ "$1" -le 0 ]; then echo 0; elif [ "$1" -ge 100 ]; then echo 255
  else echo $(( 255 - ((100 - $1) * VOL_RANGE * 255 + 4750) / 9500 )); fi
}
raw_to_m() {   # codec value -> % (only used once, to create Master at the current loudness)
  local m
  if [ "$1" -le 0 ]; then echo 0; return; fi
  m=$(( 100 - ((255 - $1) * 9500 + VOL_RANGE * 255 / 2) / (VOL_RANGE * 255) ))
  [ "$m" -lt 1 ] && m=1; echo "$m"
}
master_ensure() {
  [ -n "$(master_get)" ] && return 0
  local h m f id; h=$(hw_get); [ -n "$h" ] || { log "codec volume unreadable - Master not created"; return 1; }
  m=$(raw_to_m "$h"); id=$(cat /proc/asound/card0/id 2>/dev/null)
  f=$(mktemp /tmp/rk817-master.XXXXXX) || return 1
  cat > "$f" <<EOS
state.$id {
	control.1 {
		iface MIXER
		name 'Master Playback Volume'
		value.0 $m
		value.1 $m
		comment {
			access 'read write user'
			type INTEGER
			count 2
			range '0 - 100'
		}
	}
}
EOS
  "$ALSACTL" -I -U -f "$f" restore 0 >/dev/null 2>&1
  [ -n "$(master_get)" ] || "$ALSACTL" -I -f "$f" restore 0 >/dev/null 2>&1      # older alsactl without -U
  rm -f "$f"
  if [ -n "$(master_get)" ]; then log "volume control Master created at $m% (codec was $h)"; else log "could NOT create the Master volume control"; return 1; fi
}
LAST_HW=""; LAST_M=""
master_apply() {   # Master changed -> codec follows (a value the service itself set is not re-applied)
  local m r; m=$(master_get); [ -n "$m" ] || return
  [ "$m" = "$LAST_M" ] && return
  LAST_M=$m; r=$(m_to_raw "$m")
  [ "$r" = "$(hw_get)" ] || { LAST_HW=$r; "$AMIXER" -c 0 -q cset name='Playback Volume' "$r,$r" >/dev/null 2>&1; }
}
master_follow_down() {   # codec is quieter than Master says (changed by something else) -> LOWER Master to match.
  local h m; h=$(hw_get); m=$(master_get)   # Never raises anything, so the sound can only get louder by a key press.
  [ -n "$h" ] && [ -n "$m" ] || return 1
  [ "$(m_to_raw "$m")" -le "$h" ] && return 1
  m=$(raw_to_m "$h"); while [ "$m" -gt 0 ] && [ "$(m_to_raw "$m")" -gt "$h" ]; do m=$((m - 1)); done
  [ "$m" = 0 ] && [ "$h" -gt 0 ] && m=1                    # quieter than 1%: show 1%, leave the codec exactly where it is
  LAST_M=$m
  "$AMIXER" -c 0 -q cset name='Master Playback Volume' "$m,$m" >/dev/null 2>&1
  log "codec volume was lowered elsewhere - Master moved down to $m%"
}

pcm_running() { grep -qs RUNNING "${PCMSTATUS:-/proc/asound/card0/pcm0p/sub0/status}"; }

kick_with_stream() {
  # The codec must be in its playback state for the kick. If a game or menu is already playing, it is: kick at once.
  # Otherwise open a silent stream first. Verify, up to 3 attempts.
  local sp="" n out rc
  for n in 1 2 3; do
    if [ -z "$sp" ] && ! pcm_running; then
      aplay -q -D default -t raw -f S16_LE -r 48000 -c 2 /dev/zero >/dev/null 2>&1 &
      sp=$!; sleep 0.8
    fi
    out=$("$HELPER" kick 2>&1); rc=$?
    log "$out"
    [ "$rc" -eq 0 ] && { log "kick verified (attempt $n)"; break; }
    if [ "$n" -lt 3 ]; then log "kick verify failed (attempt $n), retrying"; sleep 1
    else log "kick NOT verified after 3 attempts"; fi
  done
  [ -n "$sp" ] && { kill "$sp" 2>/dev/null; wait "$sp" 2>/dev/null; }
}

REAPPLY=""; ENDED=""; FLIPPED=""
want_path() { if jack_plugged; then echo HP; else echo SPK; fi; }
on_line() {   # handle one event line. $1 = the path being held during a switch-over (empty otherwise), $2 = the line
  local hold=$1 line=$2
  case "$line" in
    JACKREADER_ENDED) ENDED=1 ;;
    *"Playback Path"*)
      if [ -n "$hold" ]; then                                       # inside a switch-over: undo a wrong flip at once
        local was; was=$(get_path)
        [ "$was" != "$hold" ] && { set_path "$hold"; FLIPPED=1; log "path was switched to $was - put back to $hold at once"; }
      elif [ "$(get_path)" != "$(want_path)" ]; then                # outside: our own echoes match the jack - ignored
        log "Playback Path changed by something else"; REAPPLY=path-change
      fi ;;
    *"Master Playback Volume"*) master_apply ;;                     # on-screen volume changed -> codec volume
    *",Playback Volume,"*) [ "$(hw_get)" = "$LAST_HW" ] || master_follow_down ;;   # codec volume changed elsewhere
    node*) ;;                                                       # any other mixer control: not ours
    *)
      set -f; set -- $line; set +f                                  # od line: 12 numbers, 9th = event type (no globbing)
      if [ $# -eq 12 ] && [ "$9" = 5 ]; then log "jack event code=${10} value=${11}"; REAPPLY=jack; fi ;;
  esac
}
hold_path() {   # for $2 microseconds keep handling events, putting the path back to $1 the moment anything flips it
  local t0=${EPOCHREALTIME//[.,]/} left line rc
  while [ -z "$ENDED" ]; do
    left=$(( $2 - (${EPOCHREALTIME//[.,]/} - t0) )); [ "$left" -le 0 ] && break
    IFS= read -r -t "$((left / 1000000)).$(printf '%06d' $((left % 1000000)))" line; rc=$?
    [ "$rc" -gt 128 ] && break                                      # time is up
    [ "$rc" -ne 0 ] && { ENDED=1; break; }                          # both listeners gone
    on_line "$1" "$line"
    [ "$REAPPLY" = jack ] && break                                  # plugged/unplugged again: start over
  done
}

apply() {
  # put the codec in the right state for the current jack position at once, then kick
  local plugged=0 want=SPK cur
  jack_plugged && { plugged=1; want=HP; }
  cur=$(get_path)
  [ "$plugged" = 1 ] && gpio_set 0                                  # headphones in: speaker off first
  [ "$cur" != "$want" ] && set_path "$want"
  if [ "$plugged" = 1 ]; then hp_tweak; else gpio_set 1; fi         # speaker out: on as soon as the path is right
  log "$1: jack=$([ "$plugged" = 1 ] && echo in || echo out) path ${cur:-?} -> $want, speaker pin $([ "$plugged" = 1 ] && echo low || echo high)"
  FLIPPED=""
  [ "$1" = jack ] && hold_path "$want" 120000                       # the hotkey daemon makes its (wrong) switch now
  [ "$REAPPLY" = jack ] && return
  kick_with_stream
  [ "$plugged" = 1 ] && hp_tweak log
  FLIPPED=""
  hold_path "$want" 2000000                                         # a late flip is put back at once...
  [ "$REAPPLY" = jack ] && return
  if [ -n "$FLIPPED" ] || [ "$(get_path)" != "$want" ]; then        # ...and gets a fresh kick
    [ "$(get_path)" != "$want" ] && set_path "$want"
    log "path was changed back, corrected - kicking again"
    kick_with_stream
  fi
  [ "$plugged" = 1 ] && hp_tweak
}
run_pending() { local r; while [ -n "$REAPPLY" ] && [ -z "$ENDED" ]; do r=$REAPPLY; REAPPLY=""; apply "$r"; done; }

jack_device() {
  local d
  for d in /sys/class/input/event*; do
    grep -q Headphone "$d/device/name" 2>/dev/null && { echo "/dev/input/${d##*/}"; return; }
  done
}

modprobe i2c-dev 2>/dev/null
DEV=${JACKDEV:-$(jack_device)}
[ -n "$DEV" ] || log "no headphone jack input device found; jack watch disabled"

# two event producers feed one pipe; the loop below blocks on it (no CPU until something happens).
#  - jack: one long-lived "od" decodes the 24-byte input events into one text line each (field 9 = event type)
#  - ALSA: "alsactl monitor" prints a line whenever a mixer control changes
# The listeners start BEFORE the start-up kick, so a plug/unplug during start-up is queued, not missed.
# lastpipe runs the loop in this shell itself and the monitor replaces its subshell (exec): fewest possible processes.
shopt -s lastpipe
{
  if [ -n "$DEV" ]; then
    { stdbuf -oL od -An -tu2 -w24 -v "$DEV" 2>/dev/null; echo JACKREADER_ENDED; } &
  fi
  exec ${MONITOR_CMD:-alsactl monitor hw:0} 2>/dev/null
} | {
  master_ensure && { master_follow_down || master_apply; }
  apply startup
  run_pending
  log "startup complete"
  log "listening: jack=${DEV:-none} alsa-monitor=yes (v2.2 shell daemon)"
  while [ -z "$ENDED" ] && IFS= read -r line; do
    on_line "" "$line"
    run_pending
  done
  [ -n "$ENDED" ] && { log "jack device read failed - restarting service"; exit 1; }
}
log "event sources ended - restarting in 60 s"                          # only if both listeners are gone; no fast restart churn
sleep 60
exit 1
SH
[ -s /usr/local/bin/rk817-audio-kick.sh.new ] || IFAIL="$IFAIL rk817-audio-kick.sh.new"
put /usr/local/bin/rk817-audio-kick.sh 755

S tee /etc/systemd/system/rk817-audio-kick.service.new >/dev/null <<'EOF'
[Unit]
Description=RK817 codec audio PLL kick (R36S clone audio fix)
After=sound.target alsa-restore.service audiostate.service audiopath.service r36_config.service
Wants=sound.target

[Service]
Type=simple
ExecStart=/bin/bash /usr/local/bin/rk817-audio-kick.sh
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
put /etc/systemd/system/rk817-audio-kick.service 644

S mkdir -p /lib/systemd/system-sleep
S tee /lib/systemd/system-sleep/rk817-audio-kick.new >/dev/null <<'EOF'
#!/bin/sh
# re-kick the codec PLL after resume
case "$1" in
  post) sleep 1; systemctl restart rk817-audio-kick.service ;;
esac
EOF
put /lib/systemd/system-sleep/rk817-audio-kick 755

sed "s/__VOL_RANGE__/$VOL_RANGE/" <<'EOF2' | S tee /usr/local/bin/amixer.new >/dev/null
#!/bin/bash
# amixer wrapper (audio fix v2.2). The volume keys (ogage) run "amixer -q sset Playback 1%+" / "1%-". While the audio
# fix's own "Master" control exists, a press steps Master (4% = 2 dB) and sets the codec to match right here, so it is
# instant even while the service is busy with a plug/unplug. Without Master the keys step the codec on a dB curve, as
# before. Everything else passes through unchanged.
VOL_RANGE=__VOL_RANGE__
pb=""; step=""
for a in "$@"; do case "$a" in Playback) pb=1 ;; [0-9]%[+-]|[0-9][0-9]%[+-]) step=$a ;; esac; done
if [ -n "$pb" ] && [ -n "$step" ]; then
  case "$(/usr/bin/amixer -c 0 cget name='Master Playback Volume' 2>/dev/null)" in
    *"values=2,min=0,max=100,"*)
      /usr/bin/amixer -q -c 0 sset Master "$(( ${step%%%*} * 4 ))%${step: -1}" || exit 1
      m=$(/usr/bin/amixer -c 0 cget name='Master Playback Volume' 2>/dev/null | sed -n 's/^ *: values=\([0-9]*\).*/\1/p')
      case "$m" in ''|*[!0-9]*) exit 0 ;; esac                       # the service will apply it
      if [ "$m" -le 0 ]; then r=0; elif [ "$m" -ge 100 ]; then r=255; else r=$(( 255 - ((100 - m) * VOL_RANGE * 255 + 4750) / 9500 )); fi
      exec /usr/bin/amixer -q -c 0 cset name='Playback Volume' "$r,$r" ;;
  esac
fi
for a in "$@"; do case "$a" in *%|*%+|*%-) exec /usr/bin/amixer -M "$@";; esac; done
exec /usr/bin/amixer "$@"
EOF2
put /usr/local/bin/amixer 755
[ "$MUSIC_WAS" = 1 ] || S ln -s /roms/bgmusic "$MUSIC"
S chown -h ark:ark "$MUSIC" 2>/dev/null
hash -r
sync
[ "$(sum /usr/local/bin/rk817-codec)" = "$(sum "$NEWH")" ] || IFAIL="$IFAIL rk817-codec(content)"
grep -q "^HP_ATT=$HP_ATT " /usr/local/bin/rk817-audio-kick.sh && grep -q "^VOL_RANGE=$VOL_RANGE " /usr/local/bin/rk817-audio-kick.sh || IFAIL="$IFAIL rk817-audio-kick.sh(content)"
grep -q 'sset Master' /usr/local/bin/amixer && grep -q "^VOL_RANGE=$VOL_RANGE$" /usr/local/bin/amixer || IFAIL="$IFAIL amixer(content)"
for f in /etc/systemd/system/rk817-audio-kick.service /lib/systemd/system-sleep/rk817-audio-kick /usr/local/bin/amixer; do [ -s "$f" ] || IFAIL="$IFAIL $f"; done

# ---------------------------------------------------------------- start and verify
S systemctl daemon-reload
S systemctl enable rk817-audio-kick.service >/dev/null 2>&1
S rm -f /tmp/rk817-audio-kick.log
S systemctl restart rk817-audio-kick.service
L=/tmp/rk817-audio-kick.log
OK=""; WHY="the service did not start, or did not finish a verified start-up kick within 20 s"
[ -n "$IFAIL" ] && echo "Install step(s) failed:$IFAIL"
for i in $(seq 1 20); do
  sleep 1
  if [ "$(systemctl is-active rk817-audio-kick.service)" = active ] && grep -q 'v2.2 shell daemon' "$L" 2>/dev/null \
     && grep -q 'kick verified' "$L" 2>/dev/null && ! grep -q 'kick NOT verified' "$L" 2>/dev/null; then OK=1; break; fi
done
if [ -n "$OK" ]; then
  sleep 6
  [ "$(systemctl is-active rk817-audio-kick.service)" = active ] && [ "$(grep -c ' startup: jack=' "$L")" = 1 ] || { OK=""; WHY="the service restarted by itself"; }
fi
JACK=out; amixer -c 0 cget iface=CARD,name='Headphone Jack' 2>/dev/null | grep -q 'values=on' && JACK=in
STATE=$(S /usr/local/bin/rk817-codec state 2>&1)
WANT3E=$(printf '3e=%02x' $(( 0x10 | HP_ATT )))
[ -n "$IFAIL" ] && { OK=""; WHY="install step(s) failed:$IFAIL"; }
MV=$(amixer -c 0 cget name='Master Playback Volume' 2>/dev/null | grep -q 'values=2,min=0,max=100,' && amixer -c 0 cget name='Master Playback Volume' | sed -n 's/^ *: values=\([0-9]*\).*/\1/p')
HV=$(amixer -c 0 cget name='Playback Volume' 2>/dev/null | sed -n 's/^ *: values=\([0-9]*\).*/\1/p')
if [ -z "$MV" ]; then WANTHV=none
elif [ "$MV" -le 0 ]; then WANTHV=0; elif [ "$MV" -ge 100 ]; then WANTHV=255
else WANTHV=$(( 255 - ((100 - MV) * VOL_RANGE * 255 + 4750) / 9500 )); fi
if [ -n "$OK" ] && { [ "$WANTHV" = none ] || [ -z "$HV" ] || [ "$HV" -gt "$WANTHV" ]; }; then OK=""; WHY="the on-screen volume control is missing, or the codec is louder than it says (Master=${MV:-none} codec=${HV:-?} allowed up to $WANTHV)"; fi
if [ -n "$OK" ]; then                                             # save it, so it exists before EmulationStation at boot
  S alsactl store 2>/dev/null; grep -q "Master Playback Volume" /var/lib/alsa/asound.state 2>/dev/null || { sleep 1; S alsactl store 2>/dev/null; }
  grep -q "Master Playback Volume" /var/lib/alsa/asound.state 2>/dev/null || { OK=""; WHY="could not save the new volume control in /var/lib/alsa/asound.state"; }
fi
if [ -n "$OK" ] && [ "$JACK" = in ]; then
  case " $STATE " in *" $WANT3E "*) ;; *) OK=""; WHY="headphones are in but the headphone level was not applied ($STATE)" ;; esac
fi
echo; echo "Log:"; cat "$L" 2>/dev/null
echo; echo "Codec now: $STATE   (headphones $JACK)"
echo "Volume: Master ${MV:-none}% -> codec $HV/255 (never above ${WANTHV:-?})"
echo
if [ -n "$OK" ]; then
  MAIN=$(systemctl show -p MainPID --value rk817-audio-kick.service)
  PIDS="$MAIN"; NEW="$MAIN"
  while [ -n "$NEW" ]; do NEXT=""; for p in $NEW; do NEXT="$NEXT $(pgrep -P "$p" | tr '\n' ' ')"; done; NEW=$(echo $NEXT); PIDS="$PIDS $NEW"; done
  echo "Service: active (bash daemon, pid $MAIN). Its processes and the memory each one uses on its own:"
  PT=0
  for p in $PIDS; do
    v=$(S awk '/^(Private_Clean|Private_Dirty):/ {s+=$2} END {print s+0}' /proc/$p/smaps 2>/dev/null); PT=$((PT + ${v:-0}))
    printf '   %-7s %-10s %6s kB\n' "$p" "$(cat /proc/$p/comm 2>/dev/null)" "${v:-?}"
  done
  echo "   total: $PT kB"
  echo
  if [ -e /usr/local/bin/rk817-audio-kick.py ]; then
    S rm -f /usr/local/bin/rk817-audio-kick.py
    [ -e /usr/local/bin/rk817-audio-kick.py ] && echo "Old Python service of an earlier version: could NOT be deleted" || echo "Old Python service of an earlier version: deleted"
  fi
  S rm -rf "$BK"
  if [ -e "$BK" ]; then echo "Backup of the previous version: could NOT be deleted ($BK)"
  elif [ "$PREV" = none ]; then echo "First install done - v2.2 is installed."
  else echo "Upgrade done - the earlier version is replaced and its backup deleted. Only v2.2 is installed."; fi
  echo "Headphone level -$HP_ATT dB. Volume scale: 1% = -$(( VOL_RANGE - VOL_RANGE / 100 )) dB ... 100% = 0 dB, 2 dB per key press."
  echo "EmulationStation picks up the new scale after the reboot."
  echo
  echo "Installed (v2.2). Reboot, then test: speaker, plug headphones (speaker off, headphones on), unplug (speaker back)."
else
  echo "VERIFICATION FAILED: $WHY"
  if [ "$PREV" = none ]; then echo "Removing everything this installer put on the device..."; else echo "Putting the earlier version back exactly as it was..."; fi
  S systemctl stop rk817-audio-kick.service 2>/dev/null
  [ "$WAS_ENABLED" = enabled ] || S systemctl disable rk817-audio-kick.service >/dev/null 2>&1
  if [ "$MASTER_WAS" != 1 ]; then echo "   on-screen volume control: $(S python3 -SI "$NEWH" master-remove 2>&1)"; S alsactl store 2>/dev/null; fi
  [ -n "$HV0" ] && amixer -c 0 -q cset name='Playback Volume' "$HV0,$HV0" >/dev/null 2>&1
  { systemctl status rk817-audio-kick.service --no-pager -l; echo; cat "$L"; echo; echo "$STATE"; echo "Master=$MV codec=$HV"; } > "$TOOLS/audio_fix_v22_fail.txt" 2>&1
  BAD=0; [ -s "$BK/manifest" ] || BAD=1
  while read -r st f; do
    n=$(echo "$f" | tr / _)
    if [ "$st" = present ]; then S cp -a "$BK/$n" "$f" && [ "$(sum "$f")" = "$(sum "$BK/$n")" ] || BAD=$((BAD + 1))
    else S rm -f "$f"; [ -e "$f" ] && BAD=$((BAD + 1)); fi
  done < "$BK/manifest"
  [ "$MUSIC_WAS" = 1 ] || S rm -f "$MUSIC"
  for f in $FILES; do S rm -f "$f.new"; done
  hash -r; sync
  S systemctl daemon-reload
  if [ -e /etc/systemd/system/rk817-audio-kick.service ]; then
    [ "$WAS_ENABLED" = enabled ] && S systemctl enable rk817-audio-kick.service >/dev/null 2>&1
    if [ "$WAS_ENABLED" = enabled ] || [ "$WAS_ACTIVE" = active ]; then S rm -f "$L"; S systemctl restart rk817-audio-kick.service; sleep 5; fi
  fi
  if [ "$BAD" = 0 ]; then S rm -rf "$BK"; echo "Device restored exactly as before ($NB files). Audio service: $(systemctl is-active rk817-audio-kick.service 2>/dev/null)"
  else echo "$BAD file(s) could not be restored - the backup is kept in $BK. Service: $(systemctl is-active rk817-audio-kick.service 2>/dev/null)"; fi
  echo "Send tools/audio_fix_v22_fail.txt"
fi
echo
echo "(This screen is also saved as tools/audio_fix_install.txt)"
sleep 20
