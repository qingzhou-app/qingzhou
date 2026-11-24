#!/bin/sh
# 解除断网开关 —— 一条命令，断网时也能用（不需要联网、不依赖别的组件）。
#
# 用法： sudo sh "/Library/Application Support/qingzhou-guard/off.sh"
#
# 只做「停止拦截」：
#   * 删掉 enabled 标记（守护进程不再补规则）
#   * 仅清空轻舟自己的 pf 锚点（不影响系统或其它工具的 pf 规则）
#   * 仅释放轻舟自己持有的 pfctl -E 引用 token（不再调用全局 pfctl -d）
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
pfctl -a "$ANCHOR" -F all 2>/dev/null && echo "    已清空" || echo "    （锚点本来就是空的）"

echo "==> 释放轻舟 pf 引用"
if [ -f "$BASE/pf-token" ]; then
  TOKEN="$(tr -d '[:space:]' < "$BASE/pf-token" 2>/dev/null)"
  if [ -n "$TOKEN" ]; then
    pfctl -X "$TOKEN" 2>/dev/null && echo "    已释放 pf token" || echo "    （token 已失效或 pf 未启用）"
  fi
  rm -f "$BASE/pf-token"
else
  echo "    （无记录的 pf token，不关闭全局 pf）"
fi

echo
echo "完成。当前锚点规则（应为空）："
pfctl -s rules -a "$ANCHOR" 2>/dev/null | sed 's/^/    /'
echo
echo "中继仍在运行（代理出站可能依赖它）。彻底卸载： sudo sh \"$BASE/uninstall.sh\""
