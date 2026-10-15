# 测试说明

> 以下方法来自一次真实部署的验证过程。请在自己的环境重跑，
> 不要把这里的数字当作普适保证。

## 1. 功能验证清单

- [ ] hook `dry_run`：空收件箱 → `silent`；`count`/`health` 不消费消息
- [ ] 微信发文字 → 上报到达主会话 → 主会话回复 → 微信收到 → ack
- [ ] 微信发图片 → 主会话能读取 `media[].path` 并回应图片内容
- [ ] 主会话发图片到微信（`--image`；`--file` 走 `wx-bot send` 直接发送，
  不经过 `wechat-send.sh` 的幂等保护，见教程第 9 节说明）
- [ ] 连续两条消息 → 按 `ts` 顺序各回各的，不串
- [ ] 双向事实：主会话的新事实能被微信问答 recall；微信的更正能被主会话记住
- [ ] alert 事件（如断线）：主会话在主聊天转告用户，不回微信，ack

## 2. 故障注入（隔离环境，不碰真实微信）

用 `WXBOT_OVERRIDE` 指向一个假 wx-bot（成功/卡住两种模式），
`HOME` 指向临时目录，覆盖以下场景：

| 测试 | 做法 | 期望 |
|---|---|---|
| T1 发送中被 kill | `sending` 状态下 kill -9 发送进程 | 恢复扫描识别遗留 `sending` → 记 `unknown`（退出码 2），不再调用 send |
| T2 锁恢复 | 持有者死亡 / 健康持有 / 崩溃后 | 死亡可接管、健康拒绝并发、崩溃可恢复 |
| T3 重复投递 | 同一 event_id 投递两次 | 第二次被 `SKIP` 拦截，send 不再被调用 |
| T4 跨批排序 | 乱序到达的两批事件 | 按 `create_time` 排序处理（**机制演示**，未测真实流程） |
| T7 第三次调用拦截 | 同一 event_id 调三次 | 第三次仍被 SKIP（查 ever_sent，不只看最后一条） |
| T8 并发同一事件 | 两进程同时发送同一 event_id | 实际只发送 1 次（flock），另一进程 SKIP |
| T5 超时识别 | 假 wx-bot 以 124 退出（模拟传输层超时） | 退出码 2，状态记 `unknown`（不是 `failed`） |
| T6 unknown 拦截与放行 | unknown 事件无参数重调 / 带 `--retry-unknown` 重调 / sent 后重调 | 无参数被拦截（`blocked`，不调 send）；`--retry-unknown` 放行成功记 `sent`；`sent` 后任何重发仍被拒绝 |

参考实现见本仓库 `scripts/test-fault-injection.sh`（`WXBOT_OVERRIDE` 注入点）。
一次部署的实测：30/30 断言通过（12 组：T1 发送中 kill -9、T2 锁恢复、T2d 锁不抢占活持有者、T2e 孤儿任务不误接管、T3 重复投递、T4 排序机制演示、T5 超时识别、T6 unknown 拦截、T7 第三次调用、T8 并发、T9 预写失败、T10 历史不可读）。

> 测试环境：Ubuntu 24.04.5 LTS、bash 5.2.21、Python 3.12.3、flock (util-linux 2.39.3)；
> 隔离 HOME=/tmp/wxbot-fault-test，假 wx-bot（hang/ok/timeout/slowcount），
> 未触碰真实微信与真实状态。

## 3. 延迟测量方法

端到端延迟 = 事件 `ts`（微信发出时间）→ `wechat-send.sh` 返回成功的时间。
记录"收到请回复"类短消息（几乎无思考）和需要组织内容的回复（持有思考）
两种，供对比。一次部署的实测：短消息 51 秒（优化前）→ 22 秒
（pull+落盘移入脚本后）；需要思考的回复更长。

延迟构成（诚实版）：微信云端→本地（不可控）+ 5 秒轮询（平台下限）
+ worker 启动与上报（约 10 秒）+ 主会话思考与发送。秒回做不到。

## 4. 已知未验证项

- `unknown` 状态的人工核查全流程（真实环境未触发过）
- 换网络/换机器后的延迟与稳定性
- 平台 hook/worker 行为变更后的兼容性

## 5. 回归建议

改动 `wechat-send.sh`、`wechat-inbox-watch.sh`、`persist-events.py`
后，重跑第 2 节的故障注入，确认文本模式不受影响，再上线。
