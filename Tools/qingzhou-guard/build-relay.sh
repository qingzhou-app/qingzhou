#!/bin/sh
# 编译 qingzhou-relay。不需要 sudo；产物由 install.sh 安装。
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/build/qingzhou-relay}"
mkdir -p "$(dirname "$OUT")"
echo "编译中…"
swiftc -O "$HERE/relay/main.swift" -o "$OUT"
echo "已生成：$OUT"
file "$OUT" | sed 's/^/  /'
