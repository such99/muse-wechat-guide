#!/usr/bin/env python3
"""把 wx-bot inbox pull 的输出原样落盘为事件文件。

用法: python3 persist-events.py < pull输出.json
输入可以是 pull 的直接输出 {"events": [...]}，也可以是 exec 包装后的
{"stdout": "{\\"events\\": [...]}", ...}。
每个事件写入 ~/hooks/state/wechat-events/<event_id>.json（冒号转下划线），
内容为事件 JSON 原样（不删减字段，含 media 本机路径）。
打印 {"files": [...], "count": N}。
"""
import json
import os
import sys


def main():
    raw = sys.stdin.read()
    try:
        data = json.loads(raw)
    except Exception as e:
        print(f"FATAL: 输入不是合法 JSON: {e}", file=sys.stderr)
        sys.exit(1)
    if "events" not in data and "stdout" in data:
        try:
            data = json.loads(data["stdout"])
        except Exception as e:
            print(f"FATAL: stdout 不是合法 JSON: {e}", file=sys.stderr)
            sys.exit(1)
    events = data.get("events")
    if not isinstance(events, list):
        print("FATAL: 输入中没有 events 数组", file=sys.stderr)
        sys.exit(1)

    outdir = os.path.expanduser("~/hooks/state/wechat-events")
    os.makedirs(outdir, exist_ok=True)
    os.chmod(outdir, 0o700)  # 事件含聊天正文与联系人标识，仅属主可读
    files = []
    event_ids = []
    rejected = 0
    for ev in events:
        eid = ev.get("event_id") or ev.get("message_id")
        if not eid or not isinstance(eid, str) or not eid.strip():
            # 缺失/非法 ID：拒绝落盘，不伪造同一个 "unknown" ID 导致互相覆盖。
            # 正常上游协议必带 event_id，此为异常输入。
            rejected += 1
            print(f"WARN: event missing event_id/message_id, rejected: {str(ev)[:200]}",
                  file=sys.stderr)
            continue
        eid = eid.strip()
        event_ids.append(eid)
        fname = eid.replace(":", "_").replace("/", "_") + ".json"
        path = os.path.join(outdir, fname)
        # 原子写入：先写临时文件再 rename，避免崩溃留下不完整 JSON
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(ev, f, ensure_ascii=False, indent=2)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
        files.append(path)
    print(json.dumps({"files": files, "event_ids": event_ids,
                      "count": len(files), "rejected": rejected}, ensure_ascii=False))


main()
