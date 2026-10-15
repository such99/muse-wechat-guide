# 主会话操作手册（"主会话回复"架构）

> 当 hook worker 上报微信新事件时，主会话按本手册处理。
> 前提：worker 已按 `config/worker-prompt.fetch-only.md` 做到"只取信、不回复、不确认"，
> 事件 JSON 已落盘在 `~/hooks/state/wechat-events/`，payload 里有 event_ids 和文件路径。

## 1. 接收与排序

1. 读 payload 中的文件列表；每个文件是一条事件的完整 JSON
  （含 `text` / `voice_text` / `media[].path` 本机路径 / `from_wxid`）。
2. **硬性要求：回复前必须打开事件文件读全文，禁止只依据 worker 摘要回复。**
   worker 摘要里的 `text` 只截取前 50 字（快速通知用），完整正文、
   语音转文字、图片路径都在落盘文件里，一字不删。只看摘要就回复，
   长消息会被截断理解——这是已知的唯一截断风险点。
3. **先看 `kind`**：`kind=alert` 走第 3 节；`kind=message` 走第 2 节。
   不要先用"空消息跳过"规则——alert 的正文通常为空，信息在
   `alert.message` / `alert.hint` 里，先排除会丢告警。
4. 多条 message 事件按 **`create_time`** 升序排列后逐条处理
   （上游协议字段；一次 pull 内天然有序，跨 pull 按 create_time 重排；
   缺失时回退到文件写入顺序）。
5. message 事件若 text/voice_text/media 都为空：**仍然要 ack**
  （上游要求"处理完包括决定不回复也要 ack"，否则 30 分钟后重复领取），
   只是在主聊天备注一条即可，不必回复微信。

## 2. 回复消息事件

对每条 message 事件：

1. 用主会话的完整上下文组织回复（纯文本，不用 Markdown）。
2. 回复正文写入临时文件（如 `/tmp/wx-reply-<event_id 后 6 位>.txt`）。
3. 调用发送状态机：

```bash
~/workspace/wx-bot/wechat-send.sh "<event_id>" "<from_wxid>" /tmp/wx-reply-xxxxxx.txt
# 图片：追加 --image 参数，文件换成图片路径
# 同一事件的多阶段回复（如先回"正在查"再回结果）：追加 --tag=part2，
# 幂等键变为 event_id#part2，不会被第一条的 sent 拦截
```

4. 按退出码处理：
   - `0`（sent，或 skipped=此前已发送）：执行 `wx-bot inbox ack <event_id>`。
     skipped 说明是重复上报，直接 ack 即可。
   - `1`（failed，明确未发出）：**不 ack**，在主聊天告诉用户失败原因
     （常见：未登录、参数错误）；租约到期后事件会重新上报，届时可重试。
   - `2`（unknown 结果不明，或 blocked=unknown 被拦截）：**不 ack、不重发**。
     按第 4b 节走人工核查闭环。

### 4b. unknown 人工核查闭环（必须完整执行）

unknown 表示"可能发出也可能没发出"，脚本已拒绝自动重发。主会话必须：

1. **在主聊天问用户**："刚才那条微信（<简述内容>）发送结果不明，你那边收到了吗？"
2. **用户确认"收到了"** → 立即执行 `wx-bot inbox ack <event_id>`，
   并可在发送日志追加一条人工确认记录。**必须 ack**，否则 30 分钟租约到期后
   事件重新上报，会无限唤醒。
3. **用户确认"没收到，重发"** → 仅在收到用户明确补发指令时，用显式参数重发：

```bash
~/workspace/wx-bot/wechat-send.sh "<event_id>" "<from_wxid>" /tmp/wx-reply-xxxxxx.txt --retry-unknown
```

   `--retry-unknown` 是唯一能放行 unknown 重发的途径；不带它会被拦截。
   注意：`sent` 状态的事件即使带 `--retry-unknown` 也**永远**被拒绝重发。
4. **用户尚未回复，租约到期又收到同一 event_id 上报**（状态仍为 unknown/blocked）：
   **不重复发送，不重复打扰用户**，只记录等待中。若已问过一次，本次不上报。

## 3. 处理 alert 事件

`kind=alert` 是 wx-bot 的系统通知（断线、登录过期、已恢复）：

1. 把 `message`/`hint` 翻译成中文，在主聊天转告用户并给出建议。
2. **不要**回微信。
3. 转告后执行 `inbox ack`。

## 4. 记忆裁决（长期事实）

worker 不做真伪判断，只把候选原话放在摘要「待记录」小节。主会话逐条裁决：

1. 是新事实？与现有记录是否冲突？是测试/玩笑/编造吗？
2. 通过 → 写入长期记忆（标注来源"微信+日期时间"）或当日日记。
3. 测试信息 → 不入长期记忆；若已误记，执行回滚并注明原因。
4. 用户明确说"测试"的、当场编造的，一律归为测试信息。

## 5. 延迟记录（建议）

每次真实往返记录：事件 `ts` → 发送完成时间 = 端到端延迟。
写入测试记录文件，便于跟踪回归。参考：脚本内取信优化后约 20–30 秒
（不含深度思考时间；需要动脑的回复更长）。

## 6. 回滚检查清单（切回 worker 直接回复前）

1. 查 `~/hooks/state/wechat-send-log.jsonl`：无 `sending`/`unknown` 在途。
2. 新流程已 `sent` 但未 ack 的事件，先手动 `inbox ack`。
3. 确认 `inbox count` 为 0 后，再换回上游默认 prompt。
