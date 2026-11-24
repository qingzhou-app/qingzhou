#!/bin/sh
# 彻底卸载：停服务、清规则、删文件。**先解除拦截再做别的**。
#
# 用法： sudo sh "/Library/Application Support/qingzhou-guard/uninstall.sh"
#
# 顺序很重要：先 off（保证不再拦流量），再停守护进程，最后删目录。
# 任一步失败都继续往下走 —— 卸载脚本不能因为一个错误停在半路。

set -u
BASE="/Library/Application Support/qingzhou-guard"
PLIST="/Library/LaunchDaemons/com.sbraveyoung.qingzhou.guard.plist"
ANCHOR="com.apple/qingzhou_guard"

if [ "$(id -u)" -ne 0 ]; then
  echo "需要 root：sudo sh \"$0\"" >&2
  exit 1
fi

echo "==> 1/4 先解除拦截"
[ -x "$BASE/off.sh" ] && sh "$BASE/off.sh" >/dev/null 2>&1
rm -f "$BASE/enabled"
pfctl -a "$ANCHOR" -F rules 2>/dev/null
pfctl -d 2>/dev/null

echo "==> 2/4 停止并移除 LaunchDaemon"
launchctl bootout system "$PLIST" 2>/dev/null \
  || launchctl unload -w "$PLIST" 2>/dev/null \
  || true
rm -f "$PLIST"

echo "==> 3/4 停止中继进程"
pkill -f "$BASE/qingzhou-relay" 2>/dev/null || true
sleep 1

echo "==> 4/4 删除文件"
rm -rf "$BASE"
rm -f /var/log/qingzhou-relay.log /var/log/qingzhou-guard.log

echo
echo "已卸载。残留检查："
printf '  锚点规则：'; pfctl -s rules -a "$ANCHOR" 2>/dev/null | wc -l | tr -d ' '; echo " 行"
printf '  服务：'; launchctl print system/com.sbraveyoung.qingzhou.guard >/dev/null 2>&1 && echo "仍在" || echo "已移除"
printf '  目录：'; [ -d "$BASE" ] && echo "仍在" || echo "已删除"
echo
echo "⚠️ 如果轻舟的配置里还留着指向 127.0.0.1 的 relay 出站，记得改回去，否则代理会连不上。"
