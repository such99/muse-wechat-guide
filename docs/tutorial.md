# 完整配置教程：wx-bot 云端路线 + 主会话回复

> 前置阅读：上游仓库 https://github.com/lawrencewzen/wx-bot 的 `docs/agents/muse.md`
> （安装主线按它走；本教程补充"主会话回复"架构所需的全部步骤）。
> 全文路径用 `~` / `$HOME`，无硬编码；个人信息处用 `<...>` 占位符。

## 0. 前置条件

- 一台长期开机的 Linux 主机（本指南在 Muse 的 Linux VM 上验证）
- 能访问 GitHub（下载二进制；国内主机需备好代理）
- 一个微信号（扫码登录用）
- 会进系统执行 root 命令（装 systemd 服务时需要）

### 依赖清单

| 依赖 | 用途 | 检查 |
|---|---|---|
| `bash` 4+ | 全部脚本 | `bash --version` |
| `python3` | 事件落盘、状态日志 JSON | `python3 --version` |
| `jq` | hook 脚本解析 | `jq --version` |
| `curl` | 下载二进制 | `curl --version` |
| `flock`（util-linux） | 发送脚本按事件加锁 | `flock --version` |
| `systemd` | 常驻服务 | `systemctl --version` |
| `timeout`（coreutils） | 发送超时保护 | `timeout --version` |

缺哪个装哪个（Debian/Ubuntu：`apt install -y jq curl python3 util-linux` 等）。

## 1. 安装 wx-bot

从 GitHub releases 下载对应平台的单文件二进制并校验（以上游文档的命令为准，
大意）：

```bash
mkdir -p ~/.local/bin && cd ~/.local/bin
# 按架构拼接 asset 名：wx-bot_linux_amd64 或 wx-bot_linux_arm64（musl 系统加 _musl 后缀）
curl -fLO https://github.com/lawrencewzen/wx-bot/releases/latest/download/<ASSET>
curl -fLO https://github.com/lawrencewzen/wx-bot/releases/latest/download/checksums.txt
sha256sum -c --ignore-missing checksums.txt   # 必须通过
mv <ASSET> wx-bot && chmod 0755 wx-bot
~/.local/bin/wx-bot version
```

> 上游还提供 `install.sh` 一键安装脚本和 `wx-bot update` 自更新；
> 本教程用手动下载是为了让你看清每一步装了什么。两种方式装完是一样的。

## 2. 写配置（pull 模式）

- `~/.config/wx-bot/config.json`：目录权限 `0700`，文件 `0600`。
  内容模板取上游 `examples/config.pull.example.json`，关键字段：
  binding 名自定（本指南用 `muse`），`"delivery": "pull"`。
  pull 模式不需要 webhook URL 和 key。
- 代理（如果 shell 里有 `*_proxy` 变量）：写进 `~/.config/wx-bot/env`
  （`KEY=VALUE` 每行一个，文件 `0600`）。systemd 服务启动时不继承 shell
  代理，不写这一步服务连不上微信。
- **无代理也建议建一个空 env 文件**（`touch ~/.config/wx-bot/env && chmod 0600`）：
  service 模板用 `EnvironmentFile=-`（`-` 前缀表示可选，不存在也不报错），
  重装脚本里也有存在性检查；但显式建空文件最省心，避免以后加代理时忘记。

## 3. 扫码登录

```bash
~/.local/bin/wx-bot login muse --qr-png ~/workspace/wx-bot-qr.png --timeout 10m
```

- 二维码以**图片**发给用户，**每张码约 2 分钟有效**，生成后立刻发；
  同一张码只发一次，过期等下一张（日志里 `QR #n+1`）。
- 看到 `login ok` 即成功。超时（`not scanned within 10m`）等用户准备好再重跑。
- 验证：`~/.local/bin/wx-bot health --binding muse --grace 0`，
  退出码 0 且 `logged_in: true`。

## 4. 常驻服务（注意 /etc 不持久）

用本仓库 `config/wx-bot.service.template`，把 `__HOME__` 换成 home 绝对路径、
`__USER__` 换成该目录属主（与上游 `adapters/muse/wx-bot.service` 的占位符一致）：

```bash
# root 执行：
cp wx-bot.service /etc/systemd/system/wx-bot.service
systemctl daemon-reload && systemctl enable --now wx-bot
systemctl status wx-bot --no-pager
```

检查项：`systemctl is-enabled wx-bot` 为 `enabled`；
`~/.local/bin/wx-bot status` 显示 `logged_in: true`、`delivery: pull`。

> ⚠️ **坑**：部分 VM 环境（如 Muse 的）`/etc` 在机器替换后不持久，
> 单元文件会丢失且服务不会自动回来。务必把单元文件备份在仓库目录，
> 并保留 `config/reinstall-service.sh` 一键重装。**每次重新扫码或改了
> env 文件后都要 `systemctl restart wx-bot`**。

## 5. 部署支撑脚本（必须在建 hook 之前）

```bash
mkdir -p ~/workspace/wx-bot ~/hooks/state/wechat-events ~/hooks/scripts
cp scripts/wechat-send.sh scripts/persist-events.py scripts/wechat-lock.sh ~/workspace/wx-bot/
chmod +x ~/workspace/wx-bot/wechat-send.sh ~/workspace/wx-bot/wechat-lock.sh
```

> 状态目录 `~/hooks/state/` 是事件文件、发送日志、锁的家，
> 首次部署必须建好（脚本里有 `mkdir -p` 兜底，但 hook 首次运行时目录不存在会静默失败）。

- `persist-events.py`：轮询脚本调用，把 pull 输出的每个事件原样落盘。
- `wechat-send.sh <event_id> <to_wxid> <文件> [--image]`：预写式发送状态机，
  退出码 `0`=已发送 / `1`=明确失败 / `2`=结果不明（**禁止自动重发**，
  转人工核查）。同一 event_id 已有发送记录则拒绝重发。
- `wechat-lock.sh`：过渡/回滚期的互斥锁，稳态下可不用（worker 只取信、
  主会话串行，天然单处理者）。

## 6. 建轮询 hook

把 `scripts/wechat-inbox-watch.sh` 放到 `~/hooks/scripts/` 并加执行权限：

```bash
cp scripts/wechat-inbox-watch.sh ~/hooks/scripts/
chmod +x ~/hooks/scripts/wechat-inbox-watch.sh
```

逻辑：

1. `wx-bot inbox count --binding <你的binding>`：大于 0 → 脚本内直接
   `inbox pull --binding <你的binding> --lease 30m`，再用
   `scripts/persist-events.py` 把每个事件原样落盘到
   `~/hooks/state/wechat-events/`，然后 `wake`（payload 带 event_ids
   和文件路径）。pull 只在非 dry-run 时执行。
2. 否则跑 `wx-bot health --binding <你的binding> --liveness`：
   退出码非 0 → `wake`（原因以「wx-bot 异常：」开头，同一问题 1 小时内
   只提醒一次）。
3. 其余 `silent`。

> 设计说明：把 pull+落盘放在脚本里（bash，1–2 秒）而不是 worker 里，
> 是延迟优化的关键——worker 只做摘要和上报。`poll_interval_secs` 设 5
>（平台下限）。时间口径：5 秒内轮询唤醒 worker，约 20 秒通知到达主会话，
> 端到端往返实测约 20–50 秒（含主会话思考时间）。

创建 hook（delivery 指向主会话），先 `dry_run` 验证（空收件箱应 `silent`），
再启用。

> **如何建 hook（目前只能手动在界面操作，无 CLI）**：
> 在 Muse 应用的 hook 管理界面新建一个 hook，逐项填写：
>
> | 字段 | 填什么 |
> |---|---|
> | 脚本路径 | `~/hooks/scripts/wechat-inbox-watch.sh`（第 6 步已放好） |
> | 类型 | 轮询（poll） |
> | 轮询间隔 | `poll_interval_secs: 5`（平台下限，改不掉） |
> | worker 指令 | 把 `config/worker-prompt.fetch-only.md` 全文粘贴进去 |
> | delivery 目标 | 主会话（main chat） |
>
> 建完先跑一次 dry_run：空收件箱时决策应为 `silent`，且**没有**实际执行
> `inbox pull`（看日志确认）。通过后再正式启用。
> 注意：hook 是 Muse 平台功能，不是 wx-bot 的——换平台需要自己实现等价的
> 定时唤醒机制（见 README 的"平台依赖说明"）。

## 7. worker prompt（只取信版）

把 `config/worker-prompt.fetch-only.md` 的内容作为 hook 唤醒指令。
核心约束：

- 只取信、只上报：**禁止** `wx-bot send` 回复，**禁止** `inbox ack`
- RESOLVE 阶段**必须**通知主会话（禁止 `nothing_to_do`）——否则主会话收不到
- 记忆**只读不写**：「记住」类请求原话放摘要「待记录」，由主会话裁决
- 服务异常时不 pull、不自行重启（用户可能是故意停的）

## 8. 验证（按 docs/testing.md）

1. hook `dry_run`：空收件箱 → `silent`
2. 从微信发一条文字 → 约 20 秒内上报到达主会话 → 主会话回复 → 微信收到 → ack
3. 发一张图片 → 主会话能读取并回应内容
4. 跑 `scripts` 自带的故障注入（隔离环境，不碰真实微信）
5. 测端到端延迟并记录（参考值：优化后约 20–30 秒，含思考时间更长）

## 9. 日常使用

之后所有微信消息都走"主会话回复"：worker 上报 → 主会话按
`docs/main-session-playbook.md` 处理（接收→排序→发送→确认→记忆裁决）。
早报、提醒等定时任务如需发微信，直接调 `wx-bot send`（文件用 `--file`，
图片用 `--image`）。

## 常见问题

- **上报到不了主会话**：检查 prompt 是否写了 RESOLVE 强制通知；
  常规 worker 会 `nothing_to_do` 静默掉，这是最常见的坑。
- **服务崩了没回来**：先看 `/etc/systemd/system/wx-bot.service` 还在不在，
  不在就用 `reinstall-service.sh` 重装。
- **登录过期**：收件箱会收到 alert 事件，按 playbook 转告用户后重扫码，
  再 `systemctl restart wx-bot`。
- **想切回 worker 直接回复**：按 `docs/main-session-playbook.md` 第 6 节的
  回滚检查清单（查在途→手动 ack→确认收件箱为空），再换回上游默认 prompt。
