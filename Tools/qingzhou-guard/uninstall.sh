#!/bin/sh
# 彻底卸载：停服务、还原系统时区、清规则、删文件。**先解除拦截再做别的**。
#
# 用法： sudo sh "/Library/Application Support/qingzhou-guard/uninstall.sh"
#
# 顺序很重要：先 off（仅清本锚点并释放自身 token），再还原 timezone-orig，
# 再停守护进程，最后删目录。任一步失败都继续往下走。

set -u
BASE="/Library/Application Support/qingzhou-guard"
PLIST="/Library/LaunchDaemons/com.sbraveyoung.qingzhou.guard.plist"
ANCHOR="com.apple/qingzhou_guard"

if [ "$(id -u)" -ne 0 ]; then
  echo "需要 root：sudo sh \"$0\"" >&2
  exit 1
fi

echo "==> 1/5 先解除拦截（仅清轻舟锚点）"
[ -x "$BASE/off.sh" ] && sh "$BASE/off.sh" >/dev/null 2>&1 || true
rm -f "$BASE/enabled"
pfctl -a "$ANCHOR" -F all 2>/dev/null || true
if [ -f "$BASE/pf-token" ]; then
  TOKEN="$(tr -d '[:space:]' < "$BASE/pf-token" 2>/dev/null)"
  [ -n "$TOKEN" ] && pfctl -X "$TOKEN" 2>/dev/null || true
  rm -f "$BASE/pf-token"
fi

echo "==> 2/5 还原系统时区"
if [ -f "$BASE/timezone-orig" ]; then
  ORIG_TZ="$(tr -d '\r\n' < "$BASE/timezone-orig" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  case "$ORIG_TZ" in
    ""|*..*|/*|*\\*|+*|*[[:space:]]*|posixrules)
      echo "    ⚠️ timezone-orig 内容非法，跳过还原"
      ;;
    *)
      if [ -f "/usr/share/zoneinfo/$ORIG_TZ" ] \
        && [ ! -d "/usr/share/zoneinfo/$ORIG_TZ" ] \
        && head -c 4 "/usr/share/zoneinfo/$ORIG_TZ" 2>/dev/null | grep -q '^TZif'; then
        /usr/sbin/systemsetup -settimezone "$ORIG_TZ" >/dev/null 2>&1 || true
        echo "    已还原系统时区：${ORIG_TZ}"
      else
        echo "    ⚠️ 时区不存在或无效（/usr/share/zoneinfo/${ORIG_TZ}），跳过还原"
      fi
      ;;
  esac
else
  echo "    （无 timezone-orig 记录，跳过）"
fi

echo "==> 3/5 停止并移除 LaunchDaemon"
launchctl bootout system "$PLIST" 2>/dev/null \
  || launchctl unload -w "$PLIST" 2>/dev/null \
  || true
rm -f "$PLIST"

echo "==> 4/5 停止中继进程"
pkill -f "$BASE/qingzhou-relay" 2>/dev/null || true
sleep 1

echo "==> 5/5 删除文件"
rm -rf "$BASE"
rm -f /var/log/qingzhou-relay.log /var/log/qingzhou-relay.log.1 /var/log/qingzhou-guard.log

echo
echo "已卸载。残留检查："
printf '  锚点规则：'; pfctl -s rules -a "$ANCHOR" 2>/dev/null | wc -l | tr -d ' '; echo " 行"
printf '  服务：'; launchctl print system/com.sbraveyoung.qingzhou.guard >/dev/null 2>&1 && echo "仍在" || echo "已移除"
printf '  目录：'; [ -d "$BASE" ] && echo "仍在" || echo "已删除"
echo
echo "⚠️ 如果轻舟的配置里还留着指向 127.0.0.1 的 relay 出站，记得改回去，否则代理会连不上。"
