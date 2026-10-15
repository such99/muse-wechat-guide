#!/usr/bin/env bash
# wechat-lock.sh — 微信事件处理的互斥锁（防旧处理者和新处理者同时发送）。
#
# 用法: wechat-lock.sh acquire | release | status | break | run -- <命令> [参数...]
#   acquire: 拿到锁返回 0；锁被健康持有者占用返回 1；
#            仅当持有者 PID 已死时才接管（stale），返回 0。
#   release: 释放自己持有的锁。
#   break:   人工强制清除锁（持有者疑似卡死时用，需人工确认）。
#   run: 拿到锁后执行临界区命令，退出时（正常或被信号终止）释放锁；
#        被 kill -9 时锁残留，由下一次 acquire 按 stale 规则接管。
#        这是推荐用法——持有者是长生命周期的 run 进程，避免短命脚本的 PID 立刻失效。
#
# 锁目录: ~/hooks/state/wechat-handler.lock/，内含 pid 与 ts（UTC）。
# Stale 判定：仅当持有者 PID 不存在时视为可接管。
#   注意：不再按"超过 N 秒"抢占活着的持有者——长任务持有锁超过时限是正常的，
#   抢占会导致两个处理者并发。PID 复用的理论风险改由人工 break 处理。
# 接管时会把旧锁信息记入 ~/hooks/state/wechat-send-log.jsonl（state=lock_takeover）备查。

set -u
LOCK_DIR="$HOME/hooks/state/wechat-handler.lock"
LOG="$HOME/hooks/state/wechat-send-log.jsonl"
# 父目录不存在时 mkdir 会失败并被误判为"锁已存在"，先建好。
mkdir -p "$(dirname "$LOCK_DIR")"

now_s() { date +%s; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

do_release() {
  HOLDER="${WECHAT_LOCK_HOLDER_PID:-$BASHPID}"
  if [ -f "$LOCK_DIR/pid" ] && [ "$(cat "$LOCK_DIR/pid")" = "$HOLDER" ]; then
    rm -rf "$LOCK_DIR"
  fi
}

# 写入锁文件时使用的持有者 PID：run 模式下由外层长生命周期进程指定。
holder_pid() { echo "${WECHAT_LOCK_HOLDER_PID:-$BASHPID}"; }

case "${1:?need acquire|release|status|break|run}" in
  acquire)
    # 用独立 flock 串行化"检查+接管"，防两个进程同时发现死锁、
    # A 重建后 B 又把 A 的锁删掉（两边都以为拿到锁）。
    exec 201>"$(dirname "$LOCK_DIR")/.wechat-lock-acquire.lock"
    flock 201 || { echo "cannot serialize lock acquire" >&2; exit 1; }
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      holder_pid > "$LOCK_DIR/pid"
      now_iso > "$LOCK_DIR/ts"
      echo "ACQUIRED by $BASHPID"
      exit 0
    fi
    # 锁已存在：仅当持有者 PID 已死才可接管；活着的持有者无论持有多久都不抢占。
    HPID=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "?")
    HTS=$(cat "$LOCK_DIR/ts" 2>/dev/null || echo "?")
    HTS_S=$(date -d "$HTS" +%s 2>/dev/null || echo 0)
    AGE=$(( $(now_s) - HTS_S ))
    ALIVE=0
    if [[ "$HPID" =~ ^[0-9]+$ ]] && kill -0 "$HPID" 2>/dev/null; then ALIVE=1; fi
    if [ "$ALIVE" -eq 0 ]; then
      rm -rf "$LOCK_DIR"
      mkdir "$LOCK_DIR"
      holder_pid > "$LOCK_DIR/pid"
      now_iso > "$LOCK_DIR/ts"
      python3 - "$LOG" "$HPID" <<'EOF'
import json,sys,datetime
log, hpid = sys.argv[1:3]
rec = {"ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
       "event_id": "-", "to_wxid": "-", "state": "lock_takeover",
       "detail": ("stale lock taken over: old_pid=%s (dead)" % hpid)[:300]}
open(log, "a").write(json.dumps(rec, ensure_ascii=False) + "\n")
EOF
      echo "TAKEOVER (stale: pid_dead, old holder $HPID)"
      exit 0
    fi
    echo "HELD by live pid $HPID (age ${AGE}s); use '$0 break' to force-clear after manual check" >&2
    exit 1
    ;;
  break)
    # 人工强制清除：仅在确认持有者已卡死/无用后使用。记日志备查。
    if [ -d "$LOCK_DIR" ]; then
      HPID=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "?")
      rm -rf "$LOCK_DIR"
      python3 - "$LOG" "$HPID" <<'EOF'
import json,sys,datetime
log, hpid = sys.argv[1:3]
rec = {"ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
       "event_id": "-", "to_wxid": "-", "state": "lock_break",
       "detail": ("manual break: cleared lock held by %s" % hpid)[:300]}
open(log, "a").write(json.dumps(rec, ensure_ascii=False) + "\n")
EOF
      echo "BROKEN (cleared lock held by $HPID)"
    else
      echo "no lock to break"
    fi
    exit 0
    ;;
  release)
    HOLDER="$(holder_pid)"
    if [ -f "$LOCK_DIR/pid" ] && [ "$(cat "$LOCK_DIR/pid")" = "$HOLDER" ]; then
      rm -rf "$LOCK_DIR"
      echo "RELEASED"
      exit 0
    fi
    echo "not holder; not releasing" >&2
    exit 1
    ;;
  run)
    # 用法: wechat-lock.sh run -- <cmd> [args...]
    shift
    [ "${1:-}" = "--" ] && shift
    # 先走一遍 acquire（含 stale 接管）；拿不到锁直接退出。
    # 用外层进程 PID 作为持有者，保证持有期间 PID 存活。
    export WECHAT_LOCK_HOLDER_PID=$BASHPID
    if ! "$0" acquire >/dev/null 2>&1; then
      echo "cannot acquire lock; held by a live holder" >&2
      exit 1
    fi
    trap do_release EXIT
    "$@"
    RC=$?
    exit "$RC"
    ;;
  status)
    if [ -d "$LOCK_DIR" ]; then
      echo "held: pid=$(cat "$LOCK_DIR/pid" 2>/dev/null) ts=$(cat "$LOCK_DIR/ts" 2>/dev/null)"
    else
      echo "free"
    fi
    ;;
esac
