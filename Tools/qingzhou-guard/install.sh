#!/bin/sh
# 安装断网开关的组件（**不启用拦截**）。
#
# 用法： sudo sh install.sh
#
# 这一步只做「装上去」：
#   * root 中继二进制 + 认证文件（随机生成，仅 root 可读）
#   * LaunchDaemon com.sbraveyoung.qingzhou.guard（开机自启 + 崩溃自拉）
#   * pf 规则文件（放在目录里，**不加载**）
#
# 之所以不顺手启用：本方案的拦截规则一旦生效，uid 501 的所有出站都会被拒。
# 只有把代理的出站（exit / hop / direct）都串到中继上，网络才不中断。
# 串好、验证过之后再跑 enable.sh —— 顺序错了就是整机断网。

set -u
BASE="/Library/Application Support/qingzhou-guard"
PLIST="/Library/LaunchDaemons/com.sbraveyoung.qingzhou.guard.plist"
HERE="$(cd "$(dirname "$0")" && pwd)"
PORT="${QINGZHOU_GUARD_PORT:-10808}"

if [ "$(id -u)" -ne 0 ]; then
  echo "需要 root：sudo sh \"$0\"" >&2
  exit 1
fi

echo "==> 目录 $BASE"
install -d -m 755 -o root -g wheel "$BASE"

echo "==> 中继二进制"
if [ -x "$HERE/build/qingzhou-relay" ]; then
  install -m 755 -o root -g wheel "$HERE/build/qingzhou-relay" "$BASE/qingzhou-relay"
elif [ -x "$BASE/qingzhou-relay" ]; then
  echo "    复用已安装的二进制"
else
  echo "    找不到 build/qingzhou-relay，先跑一次 build-relay.sh（不需要 sudo）" >&2
  exit 1
fi

echo "==> pf 规则与运行脚本"
install -m 644 -o root -g wheel "$HERE/pf/qingzhou-guard.conf" "$BASE/qingzhou-guard.conf"
install -m 755 -o root -g wheel "$HERE/guard-run.sh" "$BASE/guard-run.sh"
install -m 755 -o root -g wheel "$HERE/off.sh" "$BASE/off.sh"
install -m 755 -o root -g wheel "$HERE/enable.sh" "$BASE/enable.sh"
install -m 755 -o root -g wheel "$HERE/uninstall.sh" "$BASE/uninstall.sh"
install -m 755 -o root -g wheel "$HERE/diagnose.sh" "$BASE/diagnose.sh"
printf '%s' "$PORT" > "$BASE/port"
chmod 644 "$BASE/port"

echo "==> 中继认证（仅 root 可读）"
if [ ! -f "$BASE/relay-auth" ]; then
  U="$(openssl rand -hex 8)"
  P="$(openssl rand -hex 16)"
  printf '# 中继凭据（SOCKS5 用户名/密码）。代理的 relay 出站要用同样的值。\n%s:%s\n' "$U" "$P" > "$BASE/relay-auth"
  chmod 600 "$BASE/relay-auth"
  chown root:wheel "$BASE/relay-auth"
  echo "    已生成：$BASE/relay-auth"
else
  echo "    已存在，保留原凭据"
fi

# App 需要同一份凭据来配置 xray 的 relay 出站；root 的 relay-auth 是 600，
# App 读不到，所以另写一份到该用户的 App Group 容器（属主=用户，600）。
echo "==> 把凭据同步给 App（App Group）"
TARGET_USER="${SUDO_USER:-$(stat -f %Su /dev/console)}"
TARGET_HOME="$(eval echo "~$TARGET_USER")"
GROUP_DIR="$TARGET_HOME/Library/Group Containers/group.com.sbraveyoung.qingzhou"
if [ -d "$GROUP_DIR" ]; then
  U="$(grep -v '^#' "$BASE/relay-auth" | head -1 | cut -d: -f1)"
  P="$(grep -v '^#' "$BASE/relay-auth" | head -1 | cut -d: -f2)"
  printf '{"host":"127.0.0.1","port":%s,"username":"%s","password":"%s"}' "$PORT" "$U" "$P" > "$GROUP_DIR/guard-relay.json"
  chown "$TARGET_USER" "$GROUP_DIR/guard-relay.json"
  chmod 600 "$GROUP_DIR/guard-relay.json"
  echo "    已写入 ${GROUP_DIR}/guard-relay.json（属主 ${TARGET_USER}）"
else
  echo "    ⚠️ 未找到 App Group 容器（先运行一次轻舟 App 再重跑本脚本），否则 App 读不到凭据"
fi

echo "==> LaunchDaemon"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.sbraveyoung.qingzhou.guard</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BASE/guard-run.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>StandardOutPath</key>
    <string>/var/log/qingzhou-guard.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/qingzhou-guard.log</string>
</dict>
</plist>
PLISTEOF
chmod 644 "$PLIST"
chown root:wheel "$PLIST"

echo "==> 加载（仅启动中继，不加载 pf 规则）"
launchctl bootout system "$PLIST" 2>/dev/null || true
launchctl bootstrap system "$PLIST" 2>/dev/null || launchctl load -w "$PLIST"

sleep 2
if launchctl print system/com.sbraveyoung.qingzhou.guard >/dev/null 2>&1; then
  echo "    服务已加载"
else
  echo "    ⚠️ 服务未加载，检查 /var/log/qingzhou-guard.log" >&2
fi

echo
echo "中继监听：127.0.0.1:${PORT}（凭据见 $BASE/relay-auth）"
echo "本地自测："
echo "  U=\$(grep -v '^#' \"$BASE/relay-auth\" | cut -d: -f1); P=\$(grep -v '^#' \"$BASE/relay-auth\" | cut -d: -f2)"
echo "  curl -sS -o /dev/null -w '%{http_code}\\n' --proxy \"socks5h://\$U:\$P@127.0.0.1:$PORT\" https://example.com/"
echo
echo "下一步（顺序不能颠倒）："
echo "  1. 在轻舟里把 exit / hop / direct 三个出站都串到这个中继（见 Tools/qingzhou-guard/README.md）"
echo "  2. 确认代理仍能正常上网"
echo "  3. 再跑： sudo sh \"$BASE/enable.sh\""
echo
echo "⚠️ 现在还没拦任何流量，机器网络与之前完全一样。"
