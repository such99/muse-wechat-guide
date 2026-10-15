#!/usr/bin/env bash
# VM 替换导致 /etc 丢失后，一键重装 wx-bot systemd 服务。root 执行。
# 用法：先把本仓库 config/wx-bot.service.template 的 __HOME__/__USER__
# 替换为实际值，保存为 wx-bot.service 后再运行本脚本。
set -euo pipefail

SERVICE_SRC="$(cd "$(dirname "$0")" && pwd)/wx-bot.service"
[ -f "$SERVICE_SRC" ] || { echo "先按注释把 wx-bot.service.template 替换成 wx-bot.service"; exit 1; }

cp "$SERVICE_SRC" /etc/systemd/system/wx-bot.service
chmod 644 /etc/systemd/system/wx-bot.service
systemctl daemon-reload
systemctl enable --now wx-bot.service
sleep 8

HOME_DIR="$(grep -oP '^Environment=HOME=\K.*' /etc/systemd/system/wx-bot.service | head -1)"
export HOME="$HOME_DIR"
BINDING="${WXBOT_BINDING:-muse}"
set -a
[ -f "$HOME/.config/wx-bot/env" ] && . "$HOME/.config/wx-bot/env"
set +a
"$HOME/.local/bin/wx-bot" health --binding "$BINDING" --grace 30s
