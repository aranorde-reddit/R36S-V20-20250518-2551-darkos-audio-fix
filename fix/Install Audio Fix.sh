#!/bin/bash
# Install Audio Fix.sh  -  dArkOS on R36S clone V20 2025-05-18 2551
# Installs a small background service that "kicks" the RK817 codec audio PLL
# (DAC bias down -> DAC digital clock off/on -> PLL power-cycle -> bias on),
# which is what the stock kernel does at every playback start and the dArkOS 4.4
# kernel does not.  Runs at boot, after every headphone plug/unplug, and after resume.
# Also holds the speaker-enable line GPIO3_A7 high and verifies each kick.  Fully event-driven (no polling):
# boot, headphone jack events, ALSA "Playback Path" changes, resume.  v1.2.  Run once from Tools, then reboot.

S() { sudo -n "$@"; }
echo "Installing RK817 audio fix..."

S tee /usr/local/bin/rk817-audio-kick.py >/dev/null <<'PY'
#!/usr/bin/env python3
# RK817 codec audio-PLL kick daemon for dArkOS (R36S clone V20 2551).
import os, fcntl, time, struct, subprocess, glob, sys

LOG = '/tmp/rk817-audio-kick.log'
def log(m):
    try:
        with open(LOG, 'a') as f: f.write(time.strftime('%H:%M:%S ') + m + '\n')
    except Exception: pass

def gpio_high(n=103):
    try:
        if not os.path.isdir('/sys/class/gpio/gpio%d' % n):
            open('/sys/class/gpio/export', 'w').write(str(n))
            time.sleep(0.1)
        open('/sys/class/gpio/gpio%d/direction' % n, 'w').write('out')
        open('/sys/class/gpio/gpio%d/value' % n, 'w').write('1')
    except Exception as e:
        log('gpio: %s' % e)

def kick():
    """Replays rk817_restart_dac_digital_clk_and_apll from the Rockchip driver."""
    try:
        b = os.open('/dev/i2c-0', os.O_RDWR)
        fcntl.ioctl(b, 0x0706, 0x20)                       # I2C_SLAVE_FORCE, RK817 @0x20
        def r(a):
            os.write(b, bytes([a])); return os.read(b, 1)[0]
        def w(a, v):
            os.write(b, bytes([a, v & 0xff])); time.sleep(0.001)
        w(0x2f, r(0x2f) | 0x08)                            # DAC bias power down
        w(0x15, r(0x15) & ~0x08)                           # DAC digital clock off
        w(0x15, r(0x15) | 0x08)                            # DAC digital clock on
        w(0x47, r(0x47) | 0x01)                            # PLL power down
        time.sleep(0.0002)
        w(0x47, r(0x47) & ~0x01)                           # PLL power up
        w(0x2f, r(0x2f) & ~0x08)                           # DAC bias on
        rv = (r(0x39), r(0x3a))
        os.close(b)
        log('kick done, applied-volume readback = %02x/%02x' % rv)
        return rv
    except Exception as e:
        log('kick failed: %s' % e)
        return None

def codec_state():
    """(set_vol, applied_vol, muted) read straight from the codec, or None."""
    try:
        b = os.open('/dev/i2c-0', os.O_RDWR)
        fcntl.ioctl(b, 0x0706, 0x20)
        def r(a):
            os.write(b, bytes([a])); return os.read(b, 1)[0]
        st = (r(0x31), r(0x39), r(0x38) & 0x01)
        os.close(b); return st
    except Exception:
        return None


def kick_with_stream():
    # open a silent stream so the codec is in its playback state while we kick
    p = None
    try:
        p = subprocess.Popen(['aplay', '-q', '-D', 'default', '-t', 'raw', '-f', 'S16_LE',
                              '-r', '48000', '-c', '2', '/dev/zero'],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(0.8)
    except Exception as e:
        log('stream: %s' % e)
    for attempt in range(3):
        rv = kick()
        time.sleep(0.4)
        st = codec_state()
        if rv and st and st[1] != 0xff:
            break
        log('kick verify failed (attempt %d), retrying' % (attempt + 1))
        time.sleep(1.0)
    if p:
        try: p.terminate(); p.wait(timeout=2)
        except Exception: pass

def jack_device():
    for d in glob.glob('/sys/class/input/event*'):
        try:
            if 'Headphone' in open(d + '/device/name').read():
                return '/dev/input/' + os.path.basename(d)
        except Exception: pass
    return None

os.system('modprobe i2c-dev 2>/dev/null')
gpio_high()
kick_with_stream()
log('startup kick complete')

# re-kick after every headphone plug/unplug (the OS switches the audio path then)
dev = jack_device()
if not dev:
    log('no headphone jack input device found; jack watch disabled')
import select
fds = []
fmt = 'llHHi'; sz = struct.calcsize(fmt)
jfd = os.open(dev, os.O_RDONLY) if dev else None
if jfd is not None: fds.append(jfd)
# ALSA control listener: fires when anything changes 'Playback Path' (dArkOS audio scripts, Control Centre)
mon = None
try:
    mon = subprocess.Popen(['alsactl', 'monitor', 'hw:0'], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    fds.append(mon.stdout.fileno())
except Exception as e:
    log('alsactl monitor unavailable: %s' % e)
log('listening: jack=%s alsa-monitor=%s' % (dev, mon is not None))
if not fds:
    while True: time.sleep(3600)
last_kick = 0
while True:
    ready, _, _ = select.select(fds, [], [])              # blocks, no CPU until an event
    for r in ready:
        if r == jfd:
            ev = os.read(jfd, sz)
            if len(ev) < sz: continue
            _, _, etype, code, value = struct.unpack(fmt, ev)
            if etype != 5: continue                       # only EV_SW (jack)
            log('jack event code=%d value=%d' % (code, value))
        else:
            line = os.read(r, 4096).decode(errors='ignore')
            if 'Playback Path' not in line: continue
            log('Playback Path changed')
        if time.time() - last_kick < 2:                   # our own kick also toggles controls; ignore echoes
            continue
        time.sleep(0.8)                                   # let the OS finish changing the path first
        gpio_high()
        kick_with_stream()
        last_kick = time.time()
PY

S tee /etc/systemd/system/rk817-audio-kick.service >/dev/null <<'EOF'
[Unit]
Description=RK817 codec audio PLL kick (R36S clone audio fix)
After=sound.target alsa-restore.service audiostate.service audiopath.service r36_config.service
Wants=sound.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/rk817-audio-kick.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

S mkdir -p /lib/systemd/system-sleep
S tee /lib/systemd/system-sleep/rk817-audio-kick >/dev/null <<'EOF'
#!/bin/sh
# re-kick the codec PLL after resume
case "$1" in
  post) sleep 1; systemctl restart rk817-audio-kick.service ;;
esac
EOF

S chmod 755 /usr/local/bin/rk817-audio-kick.py /lib/systemd/system-sleep/rk817-audio-kick
S systemctl daemon-reload
S systemctl enable rk817-audio-kick.service >/dev/null 2>&1
S systemctl restart rk817-audio-kick.service
sleep 3
echo "Service status:"; S systemctl is-active rk817-audio-kick.service
echo "Log:"; cat /tmp/rk817-audio-kick.log 2>/dev/null
echo ""
echo "Installed. Reboot the device now, then test menus, games, headphone plug/unplug and sleep/wake."
sleep 6
