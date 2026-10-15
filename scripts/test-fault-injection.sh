#!/usr/bin/env bash
# 故障注入测试：验证 wechat-send.sh 与 wechat-lock.sh 的异常恢复能力。
# 全部在隔离 HOME（/tmp/wxbot-fault-test）下运行，不碰真实状态与真实微信。
# 结果记录到本文件同目录 test-records/2026-10-14-fault-injection.md（由本脚本末尾生成）。
set -u
cd "$(dirname "$0")"

export TEST_HOME=/tmp/wxbot-fault-test
rm -rf "$TEST_HOME"
mkdir -p "$TEST_HOME/hooks/state"
export HOME="$TEST_HOME"

PASS=0; FAIL=0
REPORT_LINES=()

ok()   { PASS=$((PASS+1)); REPORT_LINES+=("PASS: $1"); echo "PASS: $1"; }
bad()  { FAIL=$((FAIL+1)); REPORT_LINES+=("FAIL: $1"); echo "FAIL: $1"; }

LOG="$TEST_HOME/hooks/state/wechat-send-log.jsonl"
last_state() {
  python3 - "$LOG" "$1" <<'EOF'
import json,sys
log, eid = sys.argv[1:3]
last=""
for line in open(log):
    try: r=json.loads(line)
    except: continue
    if r.get("event_id")==eid: last=r.get("state","")
print(last)
EOF
}

# ---- 假 wx-bot ----
mkdir -p "$TEST_HOME/bin"
cat > "$TEST_HOME/bin/fake-hang" <<'EOF'
#!/usr/bin/env bash
touch /tmp/wxbot-fake-invoked
sleep 8
EOF
cat > "$TEST_HOME/bin/fake-ok" <<'EOF'
#!/usr/bin/env bash
touch /tmp/wxbot-fake-invoked
exit 0
EOF
cat > "$TEST_HOME/bin/fake-timeout" <<'EOF'
#!/usr/bin/env bash
# 模拟传输层超时：无输出，直接以 124 退出（同 timeout 杀掉子进程的退出码）
exit 124
EOF
cat > "$TEST_HOME/bin/fake-slowcount" <<'EOF'
#!/usr/bin/env bash
# 慢速发送：每次调用记一次数，用于并发测试
echo "$$ $(date +%s%N)" >> /tmp/wxbot-invoke-count
sleep 2
exit 0
EOF
chmod +x "$TEST_HOME"/bin/fake-*

echo "================ T1: 发送中被 kill -9 ================"
echo "hello" > "$TEST_HOME/text.txt"
rm -f /tmp/wxbot-fake-invoked
WXBOT_OVERRIDE="$TEST_HOME/bin/fake-hang" ./wechat-send.sh evt-t1 wxid-test "$TEST_HOME/text.txt" &
PID1=$!
sleep 2
kill -9 "$PID1" 2>/dev/null
wait "$PID1" 2>/dev/null
sleep 9  # 等残留的 fake-hang 自己退出，避免干扰
[ "$(last_state evt-t1)" = "sending" ] && ok "T1a: 被 kill 后日志最后一条是 sending（无终态）" || bad "T1a: 期望 sending，实际 $(last_state evt-t1)"
# 恢复运行：应转 unknown，且不再调用 send
rm -f /tmp/wxbot-fake-invoked
WXBOT_OVERRIDE="$TEST_HOME/bin/fake-ok" ./wechat-send.sh evt-t1 wxid-test "$TEST_HOME/text.txt" >/dev/null 2>&1
RC=$?
[ "$RC" -eq 2 ] && ok "T1b: 恢复运行退出码为 2（unknown）" || bad "T1b: 退出码期望 2，实际 $RC"
[ ! -f /tmp/wxbot-fake-invoked ] && ok "T1c: 恢复时没有再次调用 send（无重发）" || bad "T1c: 恢复时又调用了 send"
[ "$(last_state evt-t1)" = "unknown" ] && ok "T1d: 状态转入 unknown，等待人工核查" || bad "T1d: 期望 unknown，实际 $(last_state evt-t1)"

echo "================ T2: 锁恢复 ================"
# 构造一个持有者已死的锁（模拟崩溃残留）
rm -rf "$TEST_HOME/hooks/state/wechat-handler.lock"
mkdir -p "$TEST_HOME/hooks/state/wechat-handler.lock"
echo "99999999" > "$TEST_HOME/hooks/state/wechat-handler.lock/pid"
date -u +%Y-%m-%dT%H:%M:%SZ > "$TEST_HOME/hooks/state/wechat-handler.lock/ts"
OUT=$(./wechat-lock.sh acquire 2>&1); RC=$?
{ [ "$RC" -eq 0 ] && echo "$OUT" | grep -q TAKEOVER; } && ok "T2a: 持有者已死的锁被接管（TAKEOVER）" || bad "T2a: 未能接管死锁 (rc=$RC out=$OUT)"
./wechat-lock.sh release >/dev/null 2>&1

echo "================ T2d: 活着的持有者即使超期也不被抢占 ================"
# 构造一个持有者活着但时间戳很旧的锁（模拟长任务持有超 10 分钟）
./wechat-lock.sh run -- sleep 30 &
HOLDER2=$!
sleep 1
# 把时间戳改成 1 小时前（持有者仍活着）
date -u -d "1 hour ago" +%Y-%m-%dT%H:%M:%SZ > "$TEST_HOME/hooks/state/wechat-handler.lock/ts"
OUT=$(./wechat-lock.sh acquire 2>&1); RC=$?
{ [ "$RC" -eq 1 ] && echo "$OUT" | grep -q "HELD by live"; } \
  && ok "T2d: 持有者活着但超期，拒绝抢占（无并发）" \
  || bad "T2d: 不应抢占活着的持有者 (rc=$RC out=$OUT)"
kill -9 "$HOLDER2" 2>/dev/null; wait 2>/dev/null
sleep 1
./wechat-lock.sh release >/dev/null 2>&1 || ./wechat-lock.sh break >/dev/null 2>&1

echo "================ T2e: 外壳被杀但子任务仍活着，不误接管 ================"
# 启动 run -- sleep，后台运行；kill -9 外壳，sleep 子进程成孤儿继续持有 flock
./wechat-lock.sh run -- sleep 30 &
HOLDER3=$!
sleep 1
# 确认锁已持有
./wechat-lock.sh status | grep -q "held" || bad "T2e setup: 锁未持有"
kill -9 "$HOLDER3" 2>/dev/null; wait 2>/dev/null
sleep 1
# 外壳已死，但 sleep 孤儿仍活着并持有 flock → acquire 应拒绝接管
OUT=$(./wechat-lock.sh acquire 2>&1); RC=$?
{ [ "$RC" -eq 1 ] && echo "$OUT" | grep -q "orphaned"; } \
  && ok "T2e: 孤儿任务持有 flock 时拒绝接管" \
  || bad "T2e: 应检测到孤儿任务并拒绝 (rc=$RC out=$OUT)"
# 清理：杀掉孤儿 sleep
pkill -f "sleep 30" 2>/dev/null
sleep 1
./wechat-lock.sh break >/dev/null 2>&1
# 健康持有：用 run 模式起一个长生命周期持有者（sleep 20），主流程应拒绝
./wechat-lock.sh run -- sleep 20 &
HOLDER=$!
sleep 1
OUT=$(./wechat-lock.sh acquire 2>&1); RC=$?
[ "$RC" -eq 1 ] && ok "T2b: 健康持有者占锁时拒绝第二次 acquire（无并发发送）" || bad "T2b: 应拒绝但 rc=$RC"
kill -9 "$HOLDER" 2>/dev/null; wait 2>/dev/null
sleep 1
# 外壳和子任务都死了（杀掉孤儿 sleep），flock 释放 → 下一次应能接管
pkill -f "sleep 20" 2>/dev/null; sleep 1
# 持有者彻底崩溃后锁残留（pid 已死且无孤儿）→ 下一次应能接管
OUT=$(./wechat-lock.sh acquire 2>&1); RC=$?
{ [ "$RC" -eq 0 ] && echo "$OUT" | grep -q TAKEOVER; } && ok "T2c: 持有者彻底崩溃后锁可恢复（按 pid 已死接管）" || bad "T2c: 崩溃后未能恢复 (rc=$RC)"
./wechat-lock.sh release >/dev/null 2>&1

echo "================ T3: 同一事件重复投递 ================"
rm -f /tmp/wxbot-fake-invoked
WXBOT_OVERRIDE="$TEST_HOME/bin/fake-ok" ./wechat-send.sh evt-t3 wxid-test "$TEST_HOME/text.txt" >/dev/null 2>&1
[ "$?" -eq 0 ] && [ -f /tmp/wxbot-fake-invoked ] && ok "T3a: 首次发送成功" || bad "T3a: 首次发送异常"
rm -f /tmp/wxbot-fake-invoked
OUT=$(WXBOT_OVERRIDE="$TEST_HOME/bin/fake-ok" ./wechat-send.sh evt-t3 wxid-test "$TEST_HOME/text.txt" 2>&1); RC=$?
{ [ "$RC" -eq 0 ] && echo "$OUT" | grep -q SKIP && [ ! -f /tmp/wxbot-fake-invoked ]; } \
  && ok "T3b: 重复投递被拦截（SKIP），send 未被再次调用" \
  || bad "T3b: 重复投递未拦截 (rc=$RC)"

echo "================ T4: 跨批次排序（机制演示） ================"
mkdir -p "$TEST_HOME/events"
python3 - <<'EOF'
import json
# 用上游真实字段名 create_time（不用 ts）
ev_a = {"event_id":"muse:1","from_wxid":"u1","text":"第一条","create_time":1000}
ev_b = {"event_id":"muse:2","from_wxid":"u1","text":"第二条","create_time":2000}
# 模拟"后一批先到"的乱序到达
open("/tmp/wxbot-fault-test/events/muse_2.json","w").write(json.dumps(ev_b))
open("/tmp/wxbot-fault-test/events/muse_1.json","w").write(json.dumps(ev_a))
EOF
ORDER=$(python3 - <<'EOF'
import json, glob
evs=[]
for f in glob.glob("/tmp/wxbot-fault-test/events/*.json"):
    evs.append(json.load(open(f)))
evs.sort(key=lambda e: e.get("create_time", 0))
print(",".join(e["event_id"] for e in evs))
EOF
)
[ "$ORDER" = "muse:1,muse:2" ] && ok "T4: 事件按 create_time 排序处理（乱序到达也能纠正）" || bad "T4: 排序错误 $ORDER"
echo "注：T4 为机制演示；真实跨批顺序以后续真实连续对话测试为准（待验证）。"

echo "================ T5: 超时被识别为 unknown（Bug1 回归） ================"
rm -f /tmp/wxbot-fake-invoked
WXBOT_OVERRIDE="$TEST_HOME/bin/fake-timeout" ./wechat-send.sh evt-t5 wxid-test "$TEST_HOME/text.txt" >/dev/null 2>&1
RC=$?
[ "$RC" -eq 2 ] && ok "T5a: 超时退出码为 2（unknown）" || bad "T5a: 超时退出码期望 2，实际 $RC"
[ "$(last_state evt-t5)" = "unknown" ] && ok "T5b: 超时状态记为 unknown（不是 failed）" || bad "T5b: 期望 unknown，实际 $(last_state evt-t5)"

echo "================ T6: unknown 重发拦截与显式放行（Bug2 回归） ================"
# evt-t5 已是 unknown；无参数再次调用应被拦截，不调 send
rm -f /tmp/wxbot-fake-invoked
WXBOT_OVERRIDE="$TEST_HOME/bin/fake-ok" ./wechat-send.sh evt-t5 wxid-test "$TEST_HOME/text.txt" >/dev/null 2>&1
RC=$?
[ "$RC" -eq 2 ] && ok "T6a: unknown 自动重发被拦截（退出码 2）" || bad "T6a: 期望拦截退出码 2，实际 $RC"
[ ! -f /tmp/wxbot-fake-invoked ] && ok "T6b: 拦截时未调用 send" || bad "T6b: 拦截时不应调用 send"
[ "$(last_state evt-t5)" = "blocked" ] && ok "T6c: 拦截记为 blocked 状态" || bad "T6c: 期望 blocked，实际 $(last_state evt-t5)"
# 人工确认"未收到"后，用 --retry-unknown 显式放行
rm -f /tmp/wxbot-fake-invoked
WXBOT_OVERRIDE="$TEST_HOME/bin/fake-ok" ./wechat-send.sh evt-t5 wxid-test "$TEST_HOME/text.txt" --retry-unknown >/dev/null 2>&1
RC=$?
{ [ "$RC" -eq 0 ] && [ -f /tmp/wxbot-fake-invoked ] && [ "$(last_state evt-t5)" = "sent" ]; } \
  && ok "T6d: --retry-unknown 显式放行，重发成功记 sent" \
  || bad "T6d: 显式重发放行异常 (rc=$RC state=$(last_state evt-t5))"
# sent 之后即使带 --retry-unknown 也不许再发
rm -f /tmp/wxbot-fake-invoked
WXBOT_OVERRIDE="$TEST_HOME/bin/fake-ok" ./wechat-send.sh evt-t5 wxid-test "$TEST_HOME/text.txt" --retry-unknown >/dev/null 2>&1
RC=$?
{ [ "$RC" -eq 0 ] && [ ! -f /tmp/wxbot-fake-invoked ]; } \
  && ok "T6e: sent 后 --retry-unknown 仍被拒绝（SKIP）" \
  || bad "T6e: sent 后不应再发送 (rc=$RC)"

echo "================ T7: 第三次调用仍被拦截（Bug3 回归） ================"
rm -f /tmp/wxbot-fake-invoked
WXBOT_OVERRIDE="$TEST_HOME/bin/fake-ok" ./wechat-send.sh evt-t7 wxid-test "$TEST_HOME/text.txt" >/dev/null 2>&1
[ "$?" -eq 0 ] && [ -f /tmp/wxbot-fake-invoked ] && ok "T7a: 首次发送成功" || bad "T7a: 首次发送异常"
rm -f /tmp/wxbot-fake-invoked
WXBOT_OVERRIDE="$TEST_HOME/bin/fake-ok" ./wechat-send.sh evt-t7 wxid-test "$TEST_HOME/text.txt" >/dev/null 2>&1
{ [ "$?" -eq 0 ] && [ ! -f /tmp/wxbot-fake-invoked ]; } && ok "T7b: 第二次被拦截（SKIP）" || bad "T7b: 第二次应拦截"
# 第三次：最后一条是 skipped，旧逻辑会放行；新逻辑查 ever_sent，必须继续拦截
rm -f /tmp/wxbot-fake-invoked
OUT=$(WXBOT_OVERRIDE="$TEST_HOME/bin/fake-ok" ./wechat-send.sh evt-t7 wxid-test "$TEST_HOME/text.txt" 2>&1); RC=$?
{ [ "$RC" -eq 0 ] && echo "$OUT" | grep -q SKIP && [ ! -f /tmp/wxbot-fake-invoked ]; } \
  && ok "T7c: 第三次仍被拦截（ever_sent 生效）" \
  || bad "T7c: 第三次不应发送 (rc=$RC)"

echo "================ T8: 并发发送同一事件（Bug4 回归） ================"
rm -f /tmp/wxbot-invoke-count
WXBOT_OVERRIDE="$TEST_HOME/bin/fake-slowcount" ./wechat-send.sh evt-t8 wxid-test "$TEST_HOME/text.txt" >/dev/null 2>&1 &
P1=$!
WXBOT_OVERRIDE="$TEST_HOME/bin/fake-slowcount" ./wechat-send.sh evt-t8 wxid-test "$TEST_HOME/text.txt" >/dev/null 2>&1 &
P2=$!
wait $P1; R1=$?
wait $P2; R2=$?
N=$(wc -l < /tmp/wxbot-invoke-count 2>/dev/null || echo 0)
[ "$N" -eq 1 ] && ok "T8a: 并发下实际只发送 1 次（flock 生效）" || bad "T8a: 并发送了 $N 次，期望 1"
{ [ "$R1" -eq 0 ] && [ "$R2" -eq 0 ]; } && ok "T8b: 两进程都正常退出（一个 sent，一个 SKIP）" || bad "T8b: 退出码异常 r1=$R1 r2=$R2"

echo "================ T9: 预写失败时禁止发送 ================"
# 把日志文件替换成目录，模拟磁盘满/不可写（连 root 也拦得住）
# 注意：历史检查先于预写，目录导致 ever_sent 失败，走 exit 2（转人工）
rm -f "$TEST_HOME/hooks/state/wechat-send-log.jsonl"
mkdir -p "$TEST_HOME/hooks/state/wechat-send-log.jsonl"
rm -f /tmp/wxbot-fake-invoked
OUT=$(WXBOT_OVERRIDE="$TEST_HOME/bin/fake-ok" ./wechat-send.sh evt-t9 wxid-test "$TEST_HOME/text.txt" 2>&1); RC=$?
[ "$RC" -eq 2 ] && ok "T9a: 日志不可用时退出码为 2（转人工）" || bad "T9a: 期望退出码 2，实际 $RC"
[ ! -f /tmp/wxbot-fake-invoked ] && ok "T9b: 日志不可用时未调用 send" || bad "T9b: 日志不可用不应发送"
echo "$OUT" | grep -q "FATAL" && ok "T9c: 输出 FATAL 提示" || bad "T9c: 缺少 FATAL 提示 (out=$OUT)"
# 恢复：删掉目录，日志文件由下次写入自动重建
rmdir "$TEST_HOME/hooks/state/wechat-send-log.jsonl"

echo "================ T10: 历史不可读时禁止发送 ================"
# 在日志开头写入非法 UTF-8 字节：Python 扫描失败，但追加仍可写入
printf '\xff\xfe{"event_id":"evt-t10","state":"sent"}\n' > "$TEST_HOME/hooks/state/wechat-send-log.jsonl"
rm -f /tmp/wxbot-fake-invoked
OUT=$(WXBOT_OVERRIDE="$TEST_HOME/bin/fake-ok" ./wechat-send.sh evt-t10 wxid-test "$TEST_HOME/text.txt" 2>&1); RC=$?
[ "$RC" -eq 2 ] && ok "T10a: 历史不可读时退出码为 2（转人工）" || bad "T10a: 期望退出码 2，实际 $RC"
[ ! -f /tmp/wxbot-fake-invoked ] && ok "T10b: 历史不可读时未调用 send" || bad "T10b: 历史不可读不应发送"
echo "$OUT" | grep -q "FATAL" && ok "T10c: 输出 FATAL 提示" || bad "T10c: 缺少 FATAL 提示 (out=$OUT)"

echo
echo "================ 结果: PASS=$PASS FAIL=$FAIL ================"

# ---- 写测试记录 ----
mkdir -p test-records
{
echo "# 故障注入测试记录（2026-10-14）"
echo
echo "- 范围：wechat-send.sh（发送状态机）、wechat-lock.sh（互斥锁）、事件排序机制"
echo "- 环境：隔离 HOME=/tmp/wxbot-fault-test，假 wx-bot（hang/ok），未触碰真实微信与真实状态"
echo "- 结果：PASS=$PASS FAIL=$FAIL"
echo
echo "## 用例"
for l in "${REPORT_LINES[@]}"; do echo "- $l"; done
echo
echo "## 说明与待验证项"
echo "- T1 证明：kill -9 发生在 sending 之后，恢复运行时遗留 sending 转 unknown（退出码 2），不再调用 send。"
echo "- T2 证明：持有者死亡的锁可被接管；健康持有时拒绝并发；崩溃后可恢复。"
echo "- T3 证明：同一 event_id 已有 sent 记录时重复投递被 SKIP，send 不再被调用。"
echo "- T4 为机制演示；真实微信跨批次顺序、真实往返延迟待切换后的真实对话测试验证。"
echo "- T5 证明：传输层超时（退出码 124）被正确识别为 unknown（退出码 2），而非 failed。"
echo "- T6 证明：unknown 状态的自动重发被拦截（blocked）；人工确认后 --retry-unknown 可显式放行；sent 后任何重发仍被拒绝。"
echo "- unknown 场景的人工核查流程：主会话在主聊天转告用户，由用户确认微信是否收到，再决定补发。"
} > test-records/2026-10-14-fault-injection.md
echo "记录已写入 test-records/2026-10-14-fault-injection.md"
[ "$FAIL" -eq 0 ]
