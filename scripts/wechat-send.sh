#!/usr/bin/env bash
# wechat-send.sh — 经 wx-bot 发送微信消息，带预写式发送状态记录。
#
# 用法: wechat-send.sh <event_id> <to_wxid> <file> [--image] [--retry-unknown] [--tag=<t>]
#   默认文本模式：file 为纯文本文件（不支持 Markdown），用 --text - 发送。
#   --image 模式：file 为图片路径，用 --image 发送。
#   --retry-unknown：仅当上次状态为 unknown 且已获人工确认"未收到"时，
#     显式放行一次重发。不带此参数时 unknown 状态拒绝自动重发。
#   --tag=<t>：同一入站事件的多阶段回复（如 --tag=part2）。幂等键变为
#     event_id#tag，不同 tag 独立计数；不带 tag 时幂等键就是 event_id。
# 环境变量 WXBOT_OVERRIDE: 测试时覆盖 wx-bot 可执行文件路径。
# 环境变量 WXBOT_BINDING: binding 名，默认 muse。
#
# 退出码: 0 = 已发送（或已确认发送过，skipped）；1 = 明确失败（未发出）；
#          2 = 结果不明（unknown，禁止自动重发，转人工核查）或被拦截
#
# 状态日志: ~/hooks/state/wechat-send-log.jsonl（只追加，崩溃安全）
#   pending  -> 事件已接收，待处理
#   sending  -> 已记录发送意图，正在调用 wx-bot send（预写，调用之前落盘）
#   sent     -> send 退出码 0
#   failed   -> 明确未发出（未登录、参数非法等"发送前"错误）；可重试
#   unknown  -> 超时 / 传输层错误 / 遗留 sending 恢复 / 无法证明未发出；
#               保守分类，禁止自动重发
#   skipped  -> 幂等键已有 sent 记录，拒绝重复发送
#   blocked  -> unknown 状态被拦截（未带 --retry-unknown 的重发尝试）
#
# 并发安全：按幂等键 flock，检查+发送整个临界区串行；kill -9 后锁由内核释放。
#
# 崩溃窗口说明（诚实版）：
#   - 在写 "sending" 之前崩溃：事件停留在 pending，租约到期后重新唤醒，无重复。
#   - 在 "sending" 之后、send 返回之前崩溃：状态为 sending，无结果记录。
#     下次运行时恢复扫描发现"最后一条是 sending 且无终态"，直接记为 unknown，
#     退出码 2，不再调用 send。未知是否发出，转人工核查。
#   - send 成功但写 "sent" 之前崩溃：同上，按 unknown 处理（宁可暂停，不可静默重发）。
#   因此本脚本不承诺"不重复"：unknown 场景下是否补发由人工决定；
#   脚本只保证：同一幂等键不会被脚本自身发送两次（unknown 需显式参数才放行）。

set -u

EVENT_ID="${1:?need event_id}"
TO_WXID="${2:?need to_wxid}"
FILE="${3:?need file}"
[ -f "$FILE" ] || { echo "file not found: $FILE" >&2; exit 1; }

MODE="text"
ALLOW_RETRY="0"
TAG=""
shift 3
for a in "$@"; do
  case "$a" in
    --image) MODE="image" ;;
    --retry-unknown) ALLOW_RETRY="1" ;;
    --tag=*) TAG="${a#--tag=}" ;;
    *) echo "unknown option: $a" >&2; exit 1 ;;
  esac
done
# 幂等键：默认 event_id；多阶段回复用 --tag 区分（如 event_id#part2）。
KEY="$EVENT_ID"
[ -n "$TAG" ] && KEY="${EVENT_ID}#${TAG}"

BINDING="${WXBOT_BINDING:-muse}"

STATE_DIR="$HOME/hooks/state"
LOG="$STATE_DIR/wechat-send-log.jsonl"
WXBOT="${WXBOT_OVERRIDE:-$HOME/.local/bin/wx-bot}"
mkdir -p "$STATE_DIR"
touch "$LOG"
chmod 600 "$LOG" 2>/dev/null || true

# 并发安全（Bug4 修复）：按幂等键加锁，检查+发送整个临界区串行。
# flock 由内核管理，kill -9 后自动释放，无残留。
LOCKFILE="$STATE_DIR/.send-lock-${KEY//[^A-Za-z0-9_-]/_}"
exec 200>"$LOCKFILE"
flock 200 || { echo "cannot acquire send lock for $KEY" >&2; exit 1; }

# 安全写 JSON：用 python3 组装，避免引号破坏日志格式。键为幂等键 KEY。
# 带 fsync 落盘；调用方必须检查退出码（预写失败时禁止发送）。
jlog() { # jlog <state> <detail>
  python3 - "$LOG" "$KEY" "$TO_WXID" "$1" "$2" <<'EOF'
import json,sys,datetime,os
log, key, to, state, detail = sys.argv[1:6]
rec = {"ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
       "event_id": key, "to_wxid": to, "state": state, "detail": detail[:300]}
with open(log, "a") as f:
    f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    f.flush()
    os.fsync(f.fileno())
EOF
}

# 该幂等键的最后一条状态（恢复扫描用）。
last_state() {
  python3 - "$LOG" "$KEY" <<'EOF'
import json,sys
log, key = sys.argv[1:3]
last = ""
for line in open(log):
    try: r = json.loads(line)
    except: continue
    if r.get("event_id") == key:
        last = r.get("state", "")
print(last)
EOF
}

# 历史上是否出现过 sent（Bug3 修复：不只看最后一条，skipped 之后也要拦）。
ever_sent() {
  python3 - "$LOG" "$KEY" <<'EOF'
import json,sys
log, key = sys.argv[1:3]
for line in open(log):
    try: r = json.loads(line)
    except: continue
    if r.get("event_id") == key and r.get("state") == "sent":
        print("yes"); break
else:
    print("no")
EOF
}

# 1) 幂等：历史上出现过 sent，直接拒绝重发（--retry-unknown 也不放行）。
# 历史读取失败时禁止发送（转人工核查），不能当作"无历史"继续。
ES_OUT=$(ever_sent); ES_RC=$?
if [ "$ES_RC" -ne 0 ] || { [ "$ES_OUT" != "yes" ] && [ "$ES_OUT" != "no" ]; }; then
  echo "FATAL: cannot read send history (exit=$ES_RC); refusing to send, escalate." >&2
  exit 2
fi
if [ "$ES_OUT" = "yes" ]; then
  jlog "skipped" "key already sent before; refusing duplicate"
  echo "SKIP: $KEY already has a sent record" >&2
  exit 0
fi
LS=$(last_state); LS_RC=$?
if [ "$LS_RC" -ne 0 ]; then
  echo "FATAL: cannot read last send state (exit=$LS_RC); refusing to send, escalate." >&2
  exit 2
fi

# 2) 恢复：最后一条是 sending（进程死在发送中），转 unknown，禁止重发。
if [ "$LS" = "sending" ]; then
  jlog "unknown" "recovered leftover sending with no terminal state; delivery ambiguous"
  echo "UNKNOWN: leftover sending state for $KEY; delivery ambiguous. Do NOT auto-retry; escalate." >&2
  exit 2
fi

# 2b) unknown/blocked 拦截：结果不明时禁止自动重发，需人工确认后用 --retry-unknown 显式放行。
if { [ "$LS" = "unknown" ] || [ "$LS" = "blocked" ]; } && [ "$ALLOW_RETRY" != "1" ]; then
  jlog "blocked" "unknown/blocked state; refusing auto-retry without --retry-unknown"
  echo "BLOCKED: $KEY is in $LS state. Confirm with user first; retry only with --retry-unknown." >&2
  exit 2
fi

# 3) 预写：先落盘发送意图，再真正调用。
# 预写失败（磁盘满/权限错误）时禁止发送——否则崩溃后无记录，可能重复发送。
if [ "$ALLOW_RETRY" = "1" ]; then
  jlog "sending" "explicit retry of unknown event (--retry-unknown)" \
    || { echo "FATAL: cannot write sending state; refusing to send" >&2; exit 1; }
else
  jlog "sending" "invoking wx-bot send (mode=$MODE)" \
    || { echo "FATAL: cannot write sending state; refusing to send" >&2; exit 1; }
fi

# 代理环境（与 systemd 服务一致）
if [ -f "$HOME/.config/wx-bot/env" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$HOME/.config/wx-bot/env"
  set +a
fi

ERR_FILE="$STATE_DIR/.send-${KEY//[^A-Za-z0-9_-]/_}.err"
# 超时：文本 60 秒；图片按上游媒体预算给 600 秒（弱网大图避免过早进 unknown）。
if [ "$MODE" = "image" ]; then
  timeout 600 "$WXBOT" send --binding "$BINDING" --to "$TO_WXID" --image "$FILE" 2>"$ERR_FILE"
else
  timeout 60 "$WXBOT" send --binding "$BINDING" --to "$TO_WXID" --text - < "$FILE" 2>"$ERR_FILE"
fi
RC=$?
if [ "$RC" -eq 0 ]; then
  jlog "sent" "wx-bot send exited 0"
  rm -f "$ERR_FILE"
  exit 0
fi
ERRMSG=$(head -c 300 "$ERR_FILE" 2>/dev/null | tr '\n' ' ' | tr -d '"')
rm -f "$ERR_FILE"

if [ "$RC" -eq 124 ]; then
  jlog "unknown" "send timed out after 60s; delivery ambiguous"
  echo "UNKNOWN: send timed out after 60s; delivery ambiguous. Do NOT auto-retry; escalate." >&2
  exit 2
fi

# 保守分类：只有明确"发送前就失败"的才判 failed（可安全重试）；
# 无法证明未发出的（含空 stderr），一律 unknown（转人工核查）。
case "$ERRMSG" in
  *[Nn]ot\ logged\ in*|*login*expired*|*unauthori*|*invalid*wxid*|*bad\ argument*|*not\ found*|*No\ such*)
    jlog "failed" "pre-send failure, definitely not sent: $ERRMSG"
    echo "FAILED: $ERRMSG" >&2
    exit 1
    ;;
  *)
    jlog "unknown" "cannot prove unsent: $ERRMSG"
    echo "UNKNOWN: $ERRMSG — cannot prove unsent; do NOT auto-retry; escalate." >&2
    exit 2
    ;;
esac
