#!/bin/sh
# 解除断网开关 —— 一条命令，断网时也能用（不需要联网、不依赖别的组件）。
#
# 用法： sudo sh "/Library/Application Support/qingzhou-guard/off.sh"
#
# 只做「停止拦截」：
#   * 删掉 enabled 标记（守护进程不再补规则）
#   * 清空 pf 锚点里的规则
#   * 如果 pf 是我们打开的（-E 的 token 还在），关掉 pf
#
# 故意**不动**中继：代理的出站可能正串在中继上，杀掉它等于把 VPN 弄断。
# 要彻底卸载请用 uninstall.sh。

set -u
BASE="/Library/Application Support/qingzhou-guard"
ANCHOR="com.apple/qingzhou_guard"

if [ "$(id -u)" -ne 0 ]; then
  echo "需要 root：sudo sh \"$0\"" >&2
  exit 1
fi

echo "==> 删除 enabled 标记（守护进程将不再补规则）"
rm -f "$BASE/enabled"

echo "==> 清空锚点规则 $ANCHOR"
pfctl -a "$ANCHOR" -F rules 2>/dev/null && echo "    已清空" || echo "    （锚点本来就是空的）"

echo "==> 关闭 pf"
# -d 会关掉 pf 本身。若机器上还有别的程序在用 pf，这里也会一起关掉 ——
# 这是有意的：解除开关必须能一条命令回到「不拦任何东西」的状态。
pfctl -d 2>/dev/null && echo "    pf 已关闭" || echo "    pf 本来就是关的"

echo
echo "完成。当前锚点规则（应为空）："
pfctl -s rules -a "$ANCHOR" 2>/dev/null | sed 's/^/    /'
echo
echo "中继仍在运行（代理出站可能依赖它）。彻底卸载： sudo sh \"$BASE/uninstall.sh\""
