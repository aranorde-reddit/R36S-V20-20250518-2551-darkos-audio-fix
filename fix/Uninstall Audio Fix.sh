#!/bin/bash
# Uninstall Audio Fix.sh - removes the RK817 audio fix completely, whatever version is installed: service, daemon,
# I2C helper, sleep hook, volume-key wrapper, the on-screen volume control ("Master") and any leftover install files.
# The codec volume stays where it is; EmulationStation goes back to its own scale after the reboot.
# Leaves the menu-music link in place.
S() { sudo -n "$@"; }
printf '\033c'
S true 2>/dev/null || { echo "sudo does not work here - nothing removed."; sleep 8; exit 1; }
F="/etc/systemd/system/rk817-audio-kick.service /usr/local/bin/rk817-audio-kick.sh /usr/local/bin/rk817-audio-kick.py /usr/local/bin/rk817-codec /lib/systemd/system-sleep/rk817-audio-kick /usr/local/bin/amixer"
S systemctl disable --now rk817-audio-kick.service 2>/dev/null
MO=$(/usr/bin/amixer -c 0 cget name='Master Playback Volume' 2>/dev/null)
case "$MO" in
  *"values=2,min=0,max=100,"*)                                    # ours: delete it (the kernel only allows deleting user-made controls)
    echo "On-screen volume control: $(S python3 -SI -c "
import os, fcntl, struct
fd = os.open('/dev/snd/controlC0', os.O_RDWR)
fcntl.ioctl(fd, 0xC0405519, struct.pack('=IiII44sI', 0, 2, 0, 0, b'Master Playback Volume', 0))
print('removed')" 2>&1 | tail -1)" ;;
esac
for f in $F; do S rm -f "$f" "$f.new"; done
S rm -rf /usr/local/lib/rk817-audio-fix.backup
LEFT=""; for f in $F; do [ -e "$f" ] && LEFT="$LEFT $f"; done
if /usr/bin/amixer -c 0 cget name='Master Playback Volume' 2>/dev/null | grep -q 'values=2,min=0,max=100,'; then
  LEFT="$LEFT Master-volume-control"
else
  S alsactl store 2>/dev/null                                     # saved mixer state without the removed control
fi
S systemctl daemon-reload; sync
if [ -z "$LEFT" ]; then echo "Audio fix removed. Reboot to return to stock dArkOS audio behaviour."
else echo "Could NOT remove:$LEFT"; fi
sleep 8
