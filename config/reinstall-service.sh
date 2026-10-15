#!/usr/bin/env bash
# Reinstall the wx-bot systemd unit after a VM replacement (/etc is ephemeral).
# Run as root.
set -euo pipefail
cp /home/hatch/workspace/wx-bot/wx-bot.service /etc/systemd/system/wx-bot.service
chmod 644 /etc/systemd/system/wx-bot.service
systemctl daemon-reload
systemctl enable --now wx-bot.service
sleep 8
[ -f /home/hatch/.config/wx-bot/env ] && export $(grep -v '^#' /home/hatch/.config/wx-bot/env | xargs)
/home/hatch/.local/bin/wx-bot health --binding muse --grace 30s
