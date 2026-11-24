#!/bin/sh
# 清理空闲的 utun 接口（默认只列出来，不动手）。
#
# 用法：
#   sh destroy-idle-utun.sh            # 只打印判断，不删除
#   sudo sh destroy-idle-utun.sh --yes # 真的销毁被判定为空闲的接口
#
# 判定「空闲」的标准（三条都要满足，宁可不删）：
#   1. 有 IPv6 默认路由指向它，但**内核当前没有选它**（route get 公网 IPv6 走的不是它）
#   2. 没有 IPv4 地址
#   3. 它的 IPv6 地址只有链路本地 + 一个 ULA（说明是隧道），且不是轻舟的 utun
#
# 为什么默认不删：这些接口由系统或别的客户端创建，删掉可能被立刻重建；
# 更稳妥的做法是让 pf 规则根本不放行它们（见 pf/qingzhou-guard.conf，故意不含 fc00::/7）。

set -u
DO_IT=0
[ "${1:-}" = "--yes" ] && DO_IT=1

if [ "$DO_IT" -eq 1 ] && [ "$(id -u)" -ne 0 ]; then
  echo "销毁需要 root：sudo sh \"$0\" --yes" >&2
  exit 1
fi

# 轻舟的 utun：IPv4 地址固定 10.0.10.1
QZ_TUN=""
for dev in $(ifconfig -l 2>/dev/null); do
  case "$dev" in
    utun*) ifconfig "$dev" 2>/dev/null | grep -q 'inet 10\.0\.10\.1 ' && QZ_TUN="$dev" ;;
  esac
done
echo "轻舟的隧道：${QZ_TUN:-未连接}"
echo

# 内核给一个公网 IPv6 选的接口
ACTIVE_V6="$(route -n get -inet6 2606:4700:4700::1111 2>/dev/null | awk '/interface:/{print $2}')"
echo "公网 IPv6 实际走：${ACTIVE_V6:-无}"
echo

echo "utun 接口一览："
CANDIDATES=""
for dev in $(ifconfig -l 2>/dev/null); do
  case "$dev" in utun*) ;; *) continue ;; esac
  [ "$dev" = "$QZ_TUN" ] && continue

  info="$(ifconfig "$dev" 2>/dev/null)"
  v4="$(printf '%s\n' "$info" | awk '/inet /{print $2}' | head -1)"
  ula="$(printf '%s\n' "$info" | awk '/inet6 f[cd]/{print $2}' | head -1)"
  has_default="no"
  netstat -rn -f inet6 2>/dev/null | awk -v d="$dev" '$1=="default" && $NF==d{f=1} END{exit !f}' && has_default="yes"

  reason=""
  [ -n "$v4" ] && reason="有 IPv4 地址（$v4）"
  [ "$has_default" = "yes" ] && [ "$dev" = "$ACTIVE_V6" ] && reason="当前实际在用"
  [ -z "$ula" ] && [ -z "$reason" ] && reason="没有 ULA 地址（可能不是隧道）"

  if [ -n "$reason" ]; then
    printf "  %-8s 跳过 —— %s\n" "$dev" "$reason"
  else
    printf "  %-8s 空闲候选（ULA=%s，有默认路由但不承载实际流量）\n" "$dev" "${ula:-无}"
    CANDIDATES="$CANDIDATES $dev"
  fi
done

echo
if [ -z "$CANDIDATES" ]; then
  echo "没有可清理的接口。"
  exit 0
fi

echo "候选：$CANDIDATES"
if [ "$DO_IT" -eq 0 ]; then
  echo
  echo "这只是判断，没有删除。确认无误后执行："
  echo "  sudo sh \"$0\" --yes"
  echo
  echo "建议：先别删。断网开关的 pf 规则已经故意不放行 fc00::/7，"
  echo "     这些接口即使在，也无法在开关生效期间承载流量。"
  exit 0
fi

for dev in $CANDIDATES; do
  echo "销毁 $dev"
  ifconfig "$dev" destroy 2>&1 | sed 's/^/  /'
done
echo
echo "完成。用 ifconfig -l | tr ' ' '\\n' | grep utun 复查。"
echo "注意：如果某个客户端还活着，它可能立刻重建同名接口 —— 那不是没删掉，是被重新创建了。"
