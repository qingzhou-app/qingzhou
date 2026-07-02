#!/usr/bin/env python3
"""校验/更新 Sources/QingzhouCore/Resources/tracker-domains.txt（追踪器域名后缀表）。

数据源（域名本身是事实性数据，清单许可见各自项目）：
  - EasyPrivacy：https://easylist.to/easylist/easyprivacy.txt（GPLv3 / CC BY-SA 3.0 双许可）
  - DuckDuckGo Tracker Blocklists（TDS JSON，源自 Tracker Radar，CC BY-NC-SA 4.0）：
    https://github.com/duckduckgo/tracker-blocklists

本脚本拉取上述两个清单，然后逐条校验资源表：
  - 报告不在任何上游清单里的条目（应删除、核实，或行尾加 `# manual` 标注人工核实豁免）；
  - 顺带做格式卫生检查（小写、无重复）。

表本身是「高频子集」——收哪些条目是人工判断（口径见资源文件头注释）；
本脚本保证子集资格（每条都真在上游追踪器清单里，或被明确标注人工核实），
不负责自动挑选新条目。

用法：python3 scripts/update-tracker-domains.py
"""

import json
import re
import subprocess
import sys
from pathlib import Path

RESOURCE = Path(__file__).resolve().parent.parent / "Sources/QingzhouCore/Resources/tracker-domains.txt"

EASYPRIVACY_URL = "https://easylist.to/easylist/easyprivacy.txt"
# DDG TDS 的稳定发布位（新→旧依次尝试）
DDG_TDS_URLS = [
    "https://staticcdn.duckduckgo.com/trackerblocking/v6/current/extension-tds.json",
    "https://staticcdn.duckduckgo.com/trackerblocking/v5/current/extension-tds.json",
    "https://staticcdn.duckduckgo.com/trackerblocking/v2.1/tds.json",
]


def fetch(url: str) -> str:
    # 用 curl 而不是 urllib：macOS 上 python.org 装的 Python 常缺 CA 证书链
    return subprocess.run(["curl", "-sSfL", "--max-time", "120", url],
                          check=True, capture_output=True, text=True).stdout


def easyprivacy_domains() -> set:
    """EasyPrivacy 的 ||domain^ / ||domain/ 规则里的域名。"""
    text = fetch(EASYPRIVACY_URL)
    out = set()
    pat = re.compile(r"^\|\|([a-z0-9][a-z0-9.-]*\.[a-z]{2,})[\^/]")
    for line in text.splitlines():
        m = pat.match(line)
        if m:
            out.add(m.group(1).lower())
    return out


def ddg_domains() -> set:
    """DDG TDS：trackers 的键 + entities 的 domains，全是域名。"""
    for url in DDG_TDS_URLS:
        try:
            data = json.loads(fetch(url))
        except Exception:
            continue
        out = set(d.lower() for d in data.get("trackers", {}))
        for ent in data.get("entities", {}).values():
            out.update(d.lower() for d in ent.get("domains", []))
        print(f"DDG TDS：{url} → {len(out)} 个域名", file=sys.stderr)
        return out
    print("警告：DDG TDS 全部候选地址都拉取失败，只用 EasyPrivacy 校验", file=sys.stderr)
    return set()


def covered(entry: str, upstream: set) -> bool:
    """entry 是否被上游覆盖：自身/父域在上游内（后缀语义），
    或上游存在 entry 的子域（上游收了更精确的条目，本表的后缀覆盖它）。"""
    labels = entry.split(".")
    if any(".".join(labels[i:]) in upstream for i in range(len(labels) - 1)):
        return True
    suffix = "." + entry
    return any(d.endswith(suffix) for d in upstream)


def main() -> int:
    entries: list[tuple[str, bool]] = []   # (domain, manual豁免)
    for raw in RESOURCE.read_text(encoding="utf-8").splitlines():
        content, _, comment = raw.partition("#")
        s = content.strip()
        if not s:
            continue
        entries.append((s, "manual" in comment))

    problems = []
    names = [e for e, _ in entries]
    if len(names) != len(set(names)):
        dup = sorted({e for e in names if names.count(e) > 1})
        problems.append(f"重复条目：{dup}")
    for e, _ in entries:
        if e != e.lower():
            problems.append(f"非小写：{e}")

    print(f"资源表 {len(entries)} 条，拉取上游清单 …", file=sys.stderr)
    upstream = easyprivacy_domains()
    print(f"EasyPrivacy：{len(upstream)} 个域名", file=sys.stderr)
    upstream |= ddg_domains()

    manual = 0
    for e, is_manual in entries:
        if is_manual:
            manual += 1
            continue
        if not covered(e, upstream):
            problems.append(f"不在上游清单（核实后删除，或加 `# manual` 标注）：{e}")

    if problems:
        print("\n".join(problems))
        print(f"\n{len(problems)} 个问题。", file=sys.stderr)
        return 1
    print(f"OK：{len(entries)} 条全部有效（{len(entries) - manual} 条经上游校验，{manual} 条人工核实标注）。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
