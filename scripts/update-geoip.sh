#!/usr/bin/env bash
# 更新内置 geoip.dat —— 用 v2fly 官方的 geoip-only-cn-private.dat 精简版。
#
# 为什么用精简版而不是全量 geoip.dat（22MB）：
#   iOS 对 packet tunnel 扩展有 50 MiB 内存硬上限（jetsam），xray 以 rule 模式启动时
#   会把 geoip.dat 整个读进内存实时构建 matcher（mph 缓存路径故意留空，见
#   PacketTunnelProvider）。内置规则只用 geoip:cn / geoip:private 两个分类，
#   精简版（~224KB）行为完全等价，还给 Go runtime 省出十几 MB 预算。
#
# 副作用（已在代码层兜住）：
#   用户自定义其他国家码的 GEOIP 规则（如 GEOIP,us）在精简数据下会不生效 ——
#   RoutingRuleConverter 会跳过它们（xray 对缺失分类直接启动失败，绝不能透传），
#   RulesView 对这类规则显示「规则不生效」提示。分类清单见
#   Sources/QingzhouCore/TunnelMemoryStats.swift 的 GeoDataBundle。
#
# 来源：https://github.com/v2fly/geoip （官方 release 产物，每周自动构建）
# 用法：
#   ./scripts/update-geoip.sh              # 拉最新 release
#   ./scripts/update-geoip.sh 202607020247 # 指定 release tag
#
# 当前内置版本：v2fly/geoip release 202607020247
#   sha256: dff2733e43dbbdae88b2a59f908572eb5d9267d4afdb4c456a17f4a49d36747f
# （更新后请把上面两行改成新版本，git commit 时带上）

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DST="$REPO_ROOT/Apps/Tunnel-Shared/Resources/geoip.dat"
ASSET="geoip-only-cn-private.dat"

TAG="${1:-}"
if [ -z "$TAG" ]; then
  TAG=$(curl -fsSL https://api.github.com/repos/v2fly/geoip/releases/latest \
        | python3 -c "import json,sys; print(json.load(sys.stdin)['tag_name'])")
fi
echo "==> v2fly/geoip release: $TAG"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

BASE="https://github.com/v2fly/geoip/releases/download/$TAG"
curl -fsSL -o "$TMP/$ASSET" "$BASE/$ASSET"
curl -fsSL -o "$TMP/$ASSET.sha256sum" "$BASE/$ASSET.sha256sum"

echo "==> Verifying sha256"
(cd "$TMP" && shasum -a 256 -c "$ASSET.sha256sum")

cp "$TMP/$ASSET" "$DST"
echo "==> Installed to $DST"
ls -la "$DST"
echo
echo "记得更新本脚本头部的「当前内置版本」注释（tag + sha256），并检查 GeoDataBundle"
echo "的分类清单与所选产物一致（only-cn-private → cn / private）。"
