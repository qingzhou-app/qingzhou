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

echo "==> 1/5 检查中继"
if ! nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
  echo "    中继没有在 127.0.0.1:$PORT 监听 —— 不启用。" >&2
  echo "    先跑： sudo launchctl kickstart -k system/com.sbraveyoung.qingzhou.guard" >&2
  exit 1
fi
echo "    OK"

echo "==> 2/5 找轻舟的隧道设备"
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
echo "    OK：${TUN}"

echo "==> 3/5 确认代理真的在经中继出网（不做这步就开拦截 = 整机断网）"
# 证据一：结构化校验 xray-config.json 中的 outbounds：
#   - 存在 tag=="relay"、protocol=="socks"、127.0.0.1:$PORT 的出站
#   - hop 与 direct 的 streamSettings.sockopt.dialerProxy == "relay"
TARGET_USER="${SUDO_USER:-$(stat -f %Su /dev/console)}"
# ⚠️ 不能用 `eval echo ~$TARGET_USER`：短用户名（sbrave）≠ home 目录名（sbraveyoung）
TARGET_HOME="$(dscl . -read "/Users/${TARGET_USER}" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
if [ -z "$TARGET_HOME" ]; then
  TARGET_HOME="/Users/${TARGET_USER}"
fi
XRAY_CFG="$TARGET_HOME/Library/Group Containers/group.com.sbraveyoung.qingzhou/xray-config.json"
if [ ! -f "$XRAY_CFG" ] || ! python3 - "$XRAY_CFG" "$PORT" <<'PY'
import json, sys

cfg_path, port_str = sys.argv[1], sys.argv[2]
expected_port = int(port_str)

try:
    with open(cfg_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    sys.exit(1)

if not isinstance(data, dict):
    sys.exit(1)
outbounds = data.get("outbounds")
if not isinstance(outbounds, list):
    sys.exit(1)

by_tag = {}
for ob in outbounds:
    if isinstance(ob, dict) and isinstance(ob.get("tag"), str):
        by_tag[ob["tag"]] = ob

relay = by_tag.get("relay")
if not relay or relay.get("protocol") != "socks":
    sys.exit(1)
servers = (relay.get("settings") or {}).get("servers")
if not isinstance(servers, list) or not any(
    isinstance(s, dict)
    and s.get("address") == "127.0.0.1"
    and s.get("port") == expected_port
    for s in servers
):
    sys.exit(1)

for req_tag in ("hop", "direct"):
    ob = by_tag.get(req_tag)
    if not ob:
        sys.exit(1)
    dialer = ((ob.get("streamSettings") or {}).get("sockopt") or {}).get("dialerProxy")
    if dialer != "relay":
        sys.exit(1)

sys.exit(0)
PY
then
  echo "    App 生效的 xray 配置结构校验未通过（缺少合法 relay 出站或 hop/direct 未绑定 dialerProxy=relay）。" >&2
  echo "    请先在 App：设置 → 分流方案 → 打开「经 root 中继出网」并重连，再回来。" >&2
  exit 1
fi
# 证据二：中继日志最近 2 分钟内有过 CONNECT —— 说明有真实流量在走它
RELAY_LOG="/var/log/qingzhou-relay.log"
if [ -f "$RELAY_LOG" ]; then
  LOG_MTIME="$(stat -f %m "$RELAY_LOG")"
  NOW="$(date +%s)"
  AGE=$((NOW - LOG_MTIME))
  if [ "$AGE" -gt 120 ]; then
    echo "    中继日志 ${AGE}s 没有新流量 —— App 大概率没在经中继出网。" >&2
    echo "    请确认：分流开关已开 + 「经 root 中继出网」已开 + 已重连。" >&2
    exit 1
  fi
  echo "    OK（${AGE}s 前有流量经过中继）"
else
  echo "    ⚠️ 找不到 ${RELAY_LOG}，跳过流量证据检查"
fi

echo "==> 4/5 渲染并校验 pf 规则"
sed "s/__TUN_DEV__/${TUN}/g" "$BASE/qingzhou-guard.conf" > "$RENDERED" 2>/dev/null
chmod 600 "$RENDERED"
if ! pfctl -n -a "$ANCHOR" -f "$RENDERED" 2>/dev/null; then
  echo "    语法检查失败 —— 不启用。" >&2
  exit 1
fi
echo "    OK"

echo "==> 5/5 加载规则"
: > "$BASE/enabled"
chmod 644 "$BASE/enabled"
LOAD_ERR="$(pfctl -a "$ANCHOR" -f "$RENDERED" 2>&1)"
LOAD_RC=$?
[ -n "$LOAD_ERR" ] && echo "    pfctl: $LOAD_ERR"

ACQUIRED_NEW_TOKEN=""
if [ ! -s "$BASE/pf-token" ] || ! pfctl -s info 2>/dev/null | grep -q 'Status: Enabled'; then
  rm -f "$BASE/pf-token"
  E_OUT="$(pfctl -E 2>&1 || true)"
  TOKEN="$(printf '%s\n' "$E_OUT" | sed -n 's/.*Token[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)"
  if [ -n "$TOKEN" ]; then
    printf '%s' "$TOKEN" > "$BASE/pf-token"
    chmod 600 "$BASE/pf-token"
    ACQUIRED_NEW_TOKEN="$TOKEN"
  fi
fi
sleep 1

RULES_OUT="$(pfctl -s rules -a "$ANCHOR" 2>&1)"
if [ $LOAD_RC -ne 0 ] || [ -z "$RULES_OUT" ]; then
  echo "    规则没有进入锚点 —— 回退。" >&2
  rm -f "$BASE/enabled"
  pfctl -a "$ANCHOR" -F all 2>/dev/null || true
  if [ -n "$ACQUIRED_NEW_TOKEN" ]; then
    pfctl -X "$ACQUIRED_NEW_TOKEN" 2>/dev/null || true
    rm -f "$BASE/pf-token"
  fi
  exit 1
fi
if ! printf '%s\n' "$RULES_OUT" | grep -Eq 'block (drop )?out'; then
  echo "    锚点里没有兜底 block 规则 —— 回退。" >&2
  rm -f "$BASE/enabled"
  pfctl -a "$ANCHOR" -F all 2>/dev/null || true
  if [ -n "$ACQUIRED_NEW_TOKEN" ]; then
    pfctl -X "$ACQUIRED_NEW_TOKEN" 2>/dev/null || true
    rm -f "$BASE/pf-token"
  fi
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
