#!/usr/bin/env bash
# wx-bot 微信收件箱轮询器（Muse hook 用）。
# 每 5 秒轮询本地 wx-bot 回环接口；有新事件时自己 pull（bash 内完成，
# 比 worker 快）并把每个事件落盘到 ~/hooks/state/wechat-events/，
# 然后唤醒一个只做摘要上报的 worker。桥不健康时也唤醒。
# dry_run 安全：`inbox count` 和 `health` 不认领消息；DRY=1 时跳过 pull。
set -euo pipefail
source "$HATCH_HOOK_RUNTIME"

# Loopback only: proxy vars must not interfere with 127.0.0.1.
for v in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy; do
  unset "$v" 2>/dev/null || true
done

WXBOT="${WXBOT:-$HOME/.local/bin/wx-bot}"
BINDING="${WXBOT_BINDING:-muse}"
MARK="${HOME}/.cache/wx-bot/hook-alerted"
DRY="${HATCH_HOOK_DRY_RUN:-0}"
# 事件落盘脚本位置：按教程第 5 步部署在 ~/workspace/wx-bot/；
# 可用 WECHAT_PERSIST_PY 环境变量覆盖。缺失时直接报错，不静默跳过。
PERSIST="${WECHAT_PERSIST_PY:-$HOME/workspace/wx-bot/persist-events.py}"
if [ ! -f "$PERSIST" ]; then
  log "persist-events.py not found" "{\"path\": \"$PERSIST\"}"
  wake "微信事件落盘脚本缺失" "{\"expected\": \"$PERSIST\"}"
  exit 0
fi
ERR_DIR="$HOME/hooks/state"

if ! count="$("$WXBOT" inbox count --binding "$BINDING" 2>&1)"; then
  log "wx-bot count failed" "{\"error\": $(printf '%s' "$count" | jq -Rs .)}"
  # count 自身失败走独立节流告警（配置损坏/binding错误/DB打不开等），
  # 不能静默：否则持续故障会一直无通知。1小时内只提醒一次，恢复后标记清除。
  COUNT_MARK="${MARK}.count"
  if [ -f "$COUNT_MARK" ] && [ -z "$(find "$COUNT_MARK" -mmin +60 2>/dev/null)" ]; then
    silent "wx-bot count 失败已在1小时内提醒过" '{"binding": "'"$BINDING"'"}'
    exit 0
  fi
  mkdir -p "$(dirname "$COUNT_MARK")"
  touch "$COUNT_MARK"
  wake "wx-bot 收件箱查询失败" "{\"binding\": \"$BINDING\", \"error\": $(printf '%s' "$count" | jq -Rs . | head -c 200)}"
  exit 0
fi
# count 恢复正常后清除告警标记
rm -f "${MARK}.count"

if [[ "$count" =~ ^[0-9]+$ ]] && [ "$count" -gt 0 ]; then
  if [ "$DRY" = "1" ]; then
    wake "微信有 $count 条新事件（dry run，未 pull）" "{\"count\": $count, \"binding\": \"$BINDING\", \"dry_run\": true}"
    exit 0
  fi
  # 取信（bash 内完成，比 worker 快）：pull(lease 30m) -> 事件落盘。
  if pull_out="$("$WXBOT" inbox pull --binding "$BINDING" --lease 30m 2>"$ERR_DIR/.wx-pull.err")"; then
    if persist_out="$(printf '%s' "$pull_out" | python3 "$PERSIST" 2>"$ERR_DIR/.wx-persist.err")"; then
      payload="$(printf '%s' "$persist_out" | python3 -c "
import json,sys
d = json.load(sys.stdin)
d['binding'] = '$BINDING'
print(json.dumps(d, ensure_ascii=False))")"
      n="$(printf '%s' "$persist_out" | python3 -c "import json,sys; print(json.load(sys.stdin)['count'])")"
      if [ "$n" -gt 0 ]; then
        wake "微信有 $n 条新事件（已取信落盘）" "$payload"
        exit 0
      else
        silent "pull 返回 0 条事件" '{"binding": "'"$BINDING"'"}'
        exit 0
      fi
    else
      perr="$(cat "$ERR_DIR/.wx-persist.err" 2>/dev/null | head -c 300)"
      log "persist failed" "{\"error\": $(printf '%s' "$perr" | jq -Rs .)}"
      wake "微信事件落盘失败" "{\"binding\": \"$BINDING\"}"
      exit 0
    fi
  else
    perr="$(cat "$ERR_DIR/.wx-pull.err" 2>/dev/null | head -c 300)"
    log "wx-bot pull failed" "{\"error\": $(printf '%s' "$perr" | jq -Rs .)}"
    wake "微信拉取失败" "{\"binding\": \"$BINDING\"}"
    exit 0
  fi
fi

if health_out="$("$WXBOT" health --binding "$BINDING" --liveness 2>&1)"; then
  rm -f "$MARK"
  silent "wx-bot 运行正常" '{"binding": "'"$BINDING"'"}'
  exit 0
fi

# Unhealthy: wake once, then at most hourly while it lasts.
if [ "$DRY" = "1" ]; then
  wake "wx-bot 异常（dry run）：$health_out" '{"binding": "'"$BINDING"'", "dry_run": true}'
  exit 0
fi
if [ -f "$MARK" ] && [ -z "$(find "$MARK" -mmin +60 2>/dev/null)" ]; then
  silent "wx-bot 异常已在1小时内提醒过" '{"binding": "'"$BINDING"'"}'
  exit 0
fi
mkdir -p "$(dirname "$MARK")"
touch "$MARK"
wake "wx-bot 异常：$health_out" '{"binding": "'"$BINDING"'"}'
exit 0
