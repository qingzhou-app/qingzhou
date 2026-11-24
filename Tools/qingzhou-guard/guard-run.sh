#!/bin/sh
# 由 LaunchDaemon com.sbraveyoung.qingzhou.guard 以 root 运行：
#   1) 启动 root 中继（供代理出站使用）
#   2) 若存在 enabled 标记，把 pf 规则灌进锚点，并每 10 秒补一次
#      （别的程序清掉 pf 规则时自动补回 —— 需求里要求的"被清掉会自己补回来"）
#
# 没有任何 `enabled` 标记时不碰 pf：装好但没启用的状态下，机器网络保持原样。

set -u
BASE="/Library/Application Support/qingzhou-guard"
PORT="$(cat "$BASE/port" 2>/dev/null || echo 10808)"
ANCHOR="com.apple/qingzhou_guard"
RENDERED="$BASE/qingzhou-guard.rendered.conf"

log() { echo "$(date '+%F %T') [guard-run] $*"; }

# 找轻舟的 utun：它的 IPv4 地址固定是 10.0.10.1（PacketTunnelProvider 里的 NEIPv4Settings）。
# 按地址找而不是按 utunN 序号找 —— 设备号每次连接都可能变，写死会错。
find_tun_dev() {
  for dev in $(ifconfig -l 2>/dev/null); do
    case "$dev" in
      utun*)
        if ifconfig "$dev" 2>/dev/null | grep -q 'inet 10\.0\.10\.1 '; then
          echo "$dev"; return 0
        fi
        ;;
    esac
  done
  return 1
}

apply_rules() {
  dev="$(find_tun_dev)"
  if [ -z "$dev" ]; then
    # 找不到隧道设备 = 轻舟没连上。此时**不能**把规则灌进去：
    # 没有「放行 utun」的规则，连正常上网都会被拦，等于把机器锁死。
    log "未找到轻舟的 utun（10.0.10.1），本轮不加载规则"
    return 1
  fi
  sed "s/__TUN_DEV__/${dev}/g" "$BASE/qingzhou-guard.conf" > "$RENDERED" 2>/dev/null || return 1
  chmod 600 "$RENDERED"
  pfctl -a "$ANCHOR" -f "$RENDERED" >/dev/null 2>&1 || { log "pfctl 加载失败"; return 1; }
  pfctl -E >/dev/null 2>&1 || true
  return 0
}

if [ -f "$BASE/enabled" ]; then
  if apply_rules; then
    log "pf 规则已加载（锚点 ${ANCHOR}，中继端口 ${PORT}）"
  fi
else
  log "未启用断网开关（无 enabled 标记），只启动中继"
fi

"$BASE/qingzhou-relay" --port "$PORT" --auth-file "$BASE/relay-auth" --log /var/log/qingzhou-relay.log &
RELAY=$!
log "中继已启动 pid=$RELAY"

# 主循环：中继退出就跟着退出（KeepAlive 会整体重启）；
# 同时定期补规则 —— 既防被别人清掉，也跟上隧道重连后的新设备名。
while kill -0 "$RELAY" 2>/dev/null; do
  sleep 10
  if [ -f "$BASE/enabled" ]; then
    # 同样的规范化坑：pfctl 输出是 `block drop out`，不能按原文案 grep。
    if [ -z "$(pfctl -s rules -a "$ANCHOR" 2>/dev/null)" ]; then
      log "锚点规则不见了，重新加载"
      apply_rules
    else
      # 隧道重连后设备名可能变了：规则里的设备名和当前不一致就重灌
      cur="$(find_tun_dev)"
      if [ -n "$cur" ] && ! grep -q "on $cur all" "$RENDERED" 2>/dev/null; then
        log "隧道设备变为 ${cur}，重灌规则"
        apply_rules
      fi
    fi
  fi

  # 跟随出口地区改系统时区：App 把目标时区（或"还原"空串）写进 App Group，
  # 这里读出来，有变化就调用 timezone-follow.sh（root 权限执行 systemsetup）。
  # App 只能写自己的 App Group 容器（沙箱），guard 是 root 能读任意用户目录，
  # 所以直接读 App Group 里的指令文件，不做中间桥接。
  #
  # ⚠️ 不能 `eval echo ~$TARGET_USER`：macOS 上短用户名（sbrave）和 home 目录名
  # （sbraveyoung）可能不一致，`~sbrave` 会展开成不存在的 /Users/sbrave。
  # 用 dscl 查真实 home 目录，查不到再退回 /Users/<短名>。
  TARGET_USER="$(stat -f %Su /dev/console 2>/dev/null)"
  TARGET_HOME="$(dscl . -read "/Users/${TARGET_USER}" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
  if [ -z "$TARGET_HOME" ]; then
    TARGET_HOME="/Users/${TARGET_USER}"
  fi
  TZ_FILE="$TARGET_HOME/Library/Group Containers/group.com.sbraveyoung.qingzhou/follow-timezone.request"
  if [ -f "$TZ_FILE" ]; then
    TZ_VALUE="$(cat "$TZ_FILE" 2>/dev/null)"
    # 有值才处理；空文件说明 App 正在写，下轮再看
    if [ -n "$TZ_VALUE" ]; then
      sh "$BASE/timezone-follow.sh" "" "$TZ_VALUE"
      rm -f "$TZ_FILE"
    fi
  fi
done

log "中继已退出，guard-run 结束"
wait "$RELAY"
