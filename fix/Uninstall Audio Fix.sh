#!/bin/bash
# Uninstall Audio Fix.sh - removes the RK817 audio PLL kick service
S() { sudo -n "$@"; }
S systemctl disable --now rk817-audio-kick.service 2>/dev/null
S rm -f /etc/systemd/system/rk817-audio-kick.service /usr/local/bin/rk817-audio-kick.py /lib/systemd/system-sleep/rk817-audio-kick
S systemctl daemon-reload
echo "Audio fix removed. Reboot."
sleep 4
