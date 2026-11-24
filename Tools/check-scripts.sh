#!/bin/sh
# 检查 shell 脚本里「$VAR 紧跟非 ASCII 字符」的写法。
#
# 为什么必须查：shell 解析变量名时会吃掉后面的多字节字符，`$TS（模式…` 被当成
# 一个叫 `TS（` 的变量 —— `set -u` 下直接 `unbound variable` 中止脚本，
# `set +u` 下更糟：静默变成空串，输出错但不报错。
#
# 这个坑在本项目已踩三次（install-app.sh、enable.sh、install.sh），
# 靠人工扫描会漏 —— 每次新加含中文的日志行就可能复发。
#
# 用法： sh Tools/check-scripts.sh
# 返回码 0 = 干净，1 = 有问题。

set -u
FAIL=0
FOUND=0

for f in Tools/*.sh Tools/qingzhou-guard/*.sh; do
  [ -f "$f" ] || continue
  # 不检查自己：本文件里的反例说明本身就会命中
  case "$f" in *check-scripts.sh) continue ;; esac
  FOUND=$((FOUND + 1))
  # 跳过注释行；命中时只输出 ASCII 诊断，避免终端编码把提示变成乱码
  OUT="$(perl -ne 'next if /^\s*#/; while (/\$([A-Za-z_][A-Za-z0-9_]*)[^\x00-\x7F]/g) { printf "  line %d: \$%s<non-ASCII>\n", $., $1 }' "$f")"
  if [ -n "$OUT" ]; then
    echo "❌ $f"
    echo "$OUT"
    FAIL=1
  fi
done

if [ "$FAIL" -eq 0 ]; then
  echo "✅ $FOUND 个脚本，未发现「\$VAR 紧跟非 ASCII」的写法"
else
  echo
  echo "修法：把 \$VAR 写成 \${VAR}，即 '…\$TS（' → '…\${TS}（'"
fi
exit "$FAIL"
