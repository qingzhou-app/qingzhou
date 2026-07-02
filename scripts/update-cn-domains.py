#!/usr/bin/env python3
"""校验/更新 Sources/QingzhouCore/Resources/cn-domains.txt（CN 域名后缀表）。

数据源：v2fly/domain-list-community 的 geosite:cn（= tld-cn + geolocation-cn）。
本脚本拉取上游数据、递归解析 include，然后逐条校验资源表：
  - 报告已不在上游 geosite:cn 的条目（应删除或核实）；
  - 顺带做格式卫生检查（小写、无 .cn 冗余、无重复）。

表本身是「高频子集」——上游没有热度数据，收哪些条目是人工判断；
本脚本保证子集资格（每条都真在 geosite:cn 里），不负责自动挑选新条目。

用法：python3 scripts/update-cn-domains.py
"""

import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

# 一次性下载整个仓库 tarball —— geolocation-cn 递归 include 几百个文件，逐个拉太慢
TARBALL = "https://github.com/v2fly/domain-list-community/archive/refs/heads/master.tar.gz"
RESOURCE = Path(__file__).resolve().parent.parent / "Sources/QingzhouCore/Resources/cn-domains.txt"

_data_dir: Path | None = None


def data_dir() -> Path:
    global _data_dir
    if _data_dir is None:
        tmp = Path(tempfile.mkdtemp(prefix="geosite-"))
        tar = tmp / "repo.tar.gz"
        # 用 curl 而不是 urllib：macOS 上 python.org 装的 Python 常缺 CA 证书链
        subprocess.run(["curl", "-sSfL", "--max-time", "120", "-o", str(tar), TARBALL], check=True)
        with tarfile.open(tar) as tf:
            tf.extractall(tmp)
        _data_dir = next(tmp.glob("domain-list-community-*")) / "data"
    return _data_dir


def fetch(name: str) -> str:
    return (data_dir() / name).read_text(encoding="utf-8")


def resolve(name: str, seen: set, domains: set):
    """递归解析一个 data 文件：收集 plain/full 域名，跟进 include。"""
    if name in seen:
        return
    seen.add(name)
    for raw in fetch(name).splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        value = parts[0]
        # 带 @!cn 属性的条目 = 上游明确标注「不算 CN 归属」（geolocation-cn 的
        # include 都带 @-!cn 过滤），成员校验时按排除处理
        if "@!cn" in parts[1:]:
            continue
        if value.startswith("include:"):
            resolve(value[len("include:"):], seen, domains)
        elif value.startswith("full:"):
            domains.add(value[len("full:"):].lower())
        elif value.startswith(("regexp:", "keyword:")):
            continue  # 正则/关键词规则无法做后缀成员校验，跳过
        else:
            domains.add(value.lower())


def covered(entry: str, upstream: set) -> bool:
    """entry 在上游后缀语义下是否被覆盖（自身或其父域在上游表内）。"""
    labels = entry.split(".")
    return any(".".join(labels[i:]) in upstream for i in range(len(labels) - 1))


def main() -> int:
    entries = []
    for raw in RESOURCE.read_text(encoding="utf-8").splitlines():
        s = raw.strip()
        if s and not s.startswith("#"):
            entries.append(s)

    problems = []
    if len(entries) != len(set(entries)):
        dup = sorted({e for e in entries if entries.count(e) > 1})
        problems.append(f"重复条目：{dup}")
    for e in entries:
        if e != e.lower():
            problems.append(f"非小写：{e}")
        if e.endswith(".cn") or e.endswith(".xn--fiqs8s") or e.endswith(".xn--fiqz9s"):
            problems.append(f".cn/.中国 冗余（TLD 规则已覆盖）：{e}")

    print(f"资源表 {len(entries)} 条，拉取上游 geosite:cn …", file=sys.stderr)
    upstream: set = set()
    resolve("cn", set(), upstream)
    print(f"上游共 {len(upstream)} 条域名规则", file=sys.stderr)

    missing = [e for e in entries if not covered(e, upstream)]
    for e in missing:
        problems.append(f"不在上游 geosite:cn：{e}")

    if problems:
        print("\n".join(problems))
        print(f"\n{len(problems)} 个问题。", file=sys.stderr)
        return 1
    print(f"OK：{len(entries)} 条全部有效（均在上游 geosite:cn 内，格式合规）。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
