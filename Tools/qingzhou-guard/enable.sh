#!/bin/sh
# 启用断网开关（开始拦截）。
#
# 用法： sudo sh "/Library/Application Support/qingzhou-guard/enable.sh"
#
# ⚠️ 前置条件（两条都必须满足，否则这台机器会立刻上不了网）：
#   1. 轻舟已连接，utun 在位（否则没有「放行 utun」的规则，App 的正常流量也没了出口）；
#   2. 代理的出站已经串到中继上（否则 xray 自己的出站被拦，等于断网）。
#
# 脚本自己会检查，任一不过就**不启用**。

set -u
BASE="/Library/Application Support/qingzhou-guard"
ANCHOR="com.apple/qingzhou_guard"
PORT="$(cat "$BASE/port" 2>/dev/null || echo 10808)"
RENDERED="$BASE/qingzhou-guard.rendered.conf"

if [ "$(id -u)" -ne 0 ]; then
  echo "需要 root：sudo sh \"$0\"" >&2
  exit 1
fi

echo "==> 1/4 检查中继"
if ! nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
  echo "    中继没有在 127.0.0.1:$PORT 监听 —— 不启用。" >&2
  echo "    先跑： sudo launchctl kickstart -k system/com.sbraveyoung.qingzhou.guard" >&2
  exit 1
fi
echo "    OK"

echo "==> 2/4 找轻舟的隧道设备"
TUN=""
for dev in $(ifconfig -l 2>/dev/null); do
  case "$dev" in
    utun*) ifconfig "$dev" 2>/dev/null | grep -q 'inet 10\.0\.10\.1 ' && TUN="$dev" && break ;;
  esac
done
if [ -z "$TUN" ]; then
  echo "    没找到轻舟的 utun（地址 10.0.10.1）—— 先连上 VPN 再来启用。" >&2
  exit 1
fi
echo "    OK：$TUN"

echo "==> 3/4 渲染并校验 pf 规则"
sed "s/__TUN_DEV__/$TUN/g" "$BASE/qingzhou-guard.conf" > "$RENDERED" 2>/dev/null
chmod 600 "$RENDERED"
if ! pfctl -n -a "$ANCHOR" -f "$RENDERED" 2>/dev/null; then
  echo "    语法检查失败 —— 不启用。" >&2
  exit 1
fi
echo "    OK"

echo "==> 4/4 加载规则"
: > "$BASE/enabled"
chmod 644 "$BASE/enabled"
# ⚠️ 不再吞掉 pfctl 的 stderr：语法错、权限不够都会在这里显形，
# 之前 2>/dev/null 让"为什么没进锚点"变成黑箱。
LOAD_ERR="$(pfctl -a "$ANCHOR" -f "$RENDERED" 2>&1)"
LOAD_RC=$?
[ -n "$LOAD_ERR" ] && echo "    pfctl: $LOAD_ERR"
pfctl -E >/dev/null 2>&1 || true
sleep 1

# 校验方式：看锚点里**有没有规则**，而不是匹配固定文案。
# macOS 的 `pfctl -s rules` 会把 `block out quick all` 规范成
# `block drop out quick all` —— 早先按原文案 grep 永远匹配不上，
# 于是"规则其实加载成功了"也会被判成失败并回退（线上踩过）。
RULES_OUT="$(pfctl -s rules -a "$ANCHOR" 2>&1)"
if [ $LOAD_RC -ne 0 ] || [ -z "$RULES_OUT" ]; then
  echo "    规则没有进入锚点 —— 回退。" >&2
  rm -f "$BASE/enabled"
  pfctl -a "$ANCHOR" -F rules 2>/dev/null
  exit 1
fi
# 兜底规则必须存在（允许 block / block drop 两种写法）
if ! printf '%s\n' "$RULES_OUT" | grep -Eq 'block (drop )?out'; then
  echo "    锚点里没有兜底 block 规则 —— 回退。" >&2
  rm -f "$BASE/enabled"
  pfctl -a "$ANCHOR" -F rules 2>/dev/null
  exit 1
fi

echo
echo "已启用。当前锚点规则："
printf '%s\n' "$RULES_OUT" | sed 's/^/    /'
echo
echo "自检：在**另一个**终端里（不要在这个 sudo 窗口）跑"
echo "    curl -sS -o /dev/null -w '%{http_code}\\n' https://claude.ai"
echo "  200 = 代理链路通；000 = 代理没串到中继，立刻解除："
echo "    sudo sh \"$BASE/off.sh\""
