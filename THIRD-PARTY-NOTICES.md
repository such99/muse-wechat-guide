# 第三方来源说明（THIRD-PARTY-NOTICES）

本仓库是实验性部署指南，脚本、prompt 与文档大多为原创，个别文件改写自上游；
对上游项目的使用情况逐项说明如下。措辞区分三档：
**依赖**（调用其提供的二进制/命令）、**参考**（读其文档后自己实现）、
**改写**（复制或改写其代码——本仓库的 `scripts/wechat-inbox-watch.sh` 属于此类）。

## 1. lawrencewzen/wx-bot（依赖，无代码复制）

- 上游：https://github.com/lawrencewzen/wx-bot
- 用途：本仓库**依赖**其 releases 发布的 `wx-bot` 单文件二进制（验证用 v0.4.8，
  sha256 校验通过），通过命令行调用完成微信消息收发。
  本仓库**没有复制、改写或分发** wx-bot 的任何源码。
- 参考过的文档（仅照着用法自己写脚本，未复制内容）：
  - `docs/agents/muse.md` —— Muse 接入说明（`login`、`health`、`inbox pull --lease`、
    `inbox ack`、`send --text -` 等命令的用法核对）
  - `docs/protocol.md` —— 事件协议（`event_id`、`create_time`、`kind=alert` 的
    `alert.message` / `alert.hint` 结构）
  - `adapters/muse/wx-bot.service` —— systemd 单元模板的占位符惯例
    （`__HOME__` / `__USER__`）；本仓库的 `config/wx-bot.service.template` 为原创，
    仅占位符命名风格与之一致
  - `examples/config.pull.example.json` —— pull 模式配置字段参考
- 许可证：MIT，版权归属 `Copyright (c) 2026 Lawrence`。
  虽未分发其代码，为尊重原作者，全文附后。

## 2. 改写自上游的内容

### `scripts/wechat-inbox-watch.sh` —— 改写自 `adapters/muse/wechat-hook.sh`

- 上游文件：https://github.com/lawrencewzen/wx-bot/blob/main/adapters/muse/wechat-hook.sh
- 保留的上游结构：`inbox count` → 有新事件则 wake；`health --liveness` 异常则 wake
 （同一问题 1 小时内只提醒一次，用 `$HOME/.cache/wx-bot/hook-alerted` 做标记）；
  `WXBOT` / `WXBOT_BINDING` / `MARK` 三个变量的命名与默认值。
- 本仓库的实质改写：
  - 上游只做"计数探测"（worker 自己 pull）；本仓库把 pull 下沉到 bash 脚本内
    （`inbox pull --lease 30m` → `persist-events.py` 落盘 → wake 时带 payload），
    这是"主会话回复"架构延迟优化的关键，上游没有这部分；
  - 适配新版 hook 运行时协议（`source "$HATCH_HOOK_RUNTIME"` 提供
    `wake`/`silent`/`log`，上游示例用的是旧版 `echo "wake: ..."` 协议）；
  - 增加 dry_run 安全（`HATCH_HOOK_DRY_RUN=1` 时跳过 pull，每个终端调用后显式 `exit`）；
  - `persist-events.py` 缺失时 fail-fast 告警；`WECHAT_PERSIST_PY` 覆盖变量。
- 许可证：上游 MIT（Copyright (c) 2026 Lawrence），改写保留原许可，全文附后。

## 3. 本仓库原创内容（MIT，见根目录 LICENSE）

以下全部为本项目原创，未衍生自上游或其他项目：

- `scripts/wechat-send.sh` —— 预写式发送状态机（幂等、flock 并发保护、
  unknown 人工核查闭环）
- `scripts/wechat-lock.sh` —— 过渡期互斥锁
- `scripts/persist-events.py` —— 事件落盘（原子写入、600/700 权限）
- `scripts/test-fault-injection.sh` —— 故障注入回归测试
- `config/worker-prompt.fetch-only.md` —— "只取信" worker prompt
  （针对"主会话回复"架构原创；上游默认 prompt 是 worker 直接回复，
  架构不同，未复制）
- `config/wx-bot.service.template`、`config/reinstall-service.sh`
- `docs/` 下全部文档（tutorial、main-session-playbook、testing）

## 上游 LICENSE 全文（lawrencewzen/wx-bot，MIT）

```
MIT License

Copyright (c) 2026 Lawrence

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
