#!/bin/sh
# 启用断网开关（开始拦截）。
#
# 用法： sudo sh "/Library/Application Support/qingzhou-guard/enable.sh"
#
# ⚠️ 前置条件：代理的出站已经串到中继上，且代理当前能正常上网。
#    否则执行完这台机器就上不了网 —— 因为规则会拒绝 uid 501 的一切外部出站。
#
# 脚本自己会做三项检查，任一不过就**不启用**并退回：
#   1. 中继在监听（否则代理出站全断）
#   2. pf 规则语法通过（pfctl -n）
#   3. 规则确实进了锚点（pfctl -s rules -a）

set -u
BASE="/Library/Application Support/qingzhou-guard"
ANCHOR="com.apple/qingzhou_guard"
PORT="$(cat "$BASE/port" 2>/dev/null || echo 10808)"

if [ "$(id -u)" -ne 0 ]; then
  echo "需要 root：sudo sh \"$0\"" >&2
  exit 1
fi

echo "==> 1/3 检查中继"
if ! /usr/bin/nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
  echo "    中继没有在 127.0.0.1:$PORT 监听 —— 不启用。" >&2
  echo "    先跑： sudo launchctl kickstart -k system/com.sbraveyoung.qingzhou.guard" >&2
  exit 1
fi
echo "    OK"

echo "==> 2/3 校验 pf 规则语法"
if ! pfctl -n -a "$ANCHOR" -f "$BASE/qingzhou-guard.conf" 2>/dev/null; then
  echo "    语法检查失败 —— 不启用。" >&2
  exit 1
fi
echo "    OK"

echo "==> 3/3 加载规则"
: > "$BASE/enabled"
chmod 644 "$BASE/enabled"
pfctl -a "$ANCHOR" -f "$BASE/qingzhou-guard.conf" 2>/dev/null
pfctl -E 2>/dev/null || true
sleep 1

RULES="$(pfctl -s rules -a "$ANCHOR" 2>/dev/null | grep -c 'block out quick all' || true)"
if [ "${RULES:-0}" -lt 1 ]; then
  echo "    规则没有进入锚点 —— 回退。" >&2
  rm -f "$BASE/enabled"
  pfctl -a "$ANCHOR" -F rules 2>/dev/null
  exit 1
fi

echo
echo "已启用。当前锚点规则："
pfctl -s rules -a "$ANCHOR" 2>/dev/null | sed 's/^/    /'
echo
echo "解除： sudo sh \"$BASE/off.sh\""
echo "如果这时网断了（说明代理没串到中继），在同一台终端里立刻跑上面那条解除命令。"
