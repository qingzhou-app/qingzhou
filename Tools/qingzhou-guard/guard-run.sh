#!/bin/sh
# 由 LaunchDaemon com.sbraveyoung.qingzhou.guard 以 root 运行：
#   1) 启动 root 中继（供代理出站使用）
#   2) 若存在 enabled 标记：
#      - utun（10.0.10.1）未就绪时加载「fail-closed 基础规则」（仅放行 lo0 / 局域网 / root，
#        去掉 __TUN_DEV__ 放行行），消除启动与重连窗口的泄漏；
#      - utun 就绪时加载完整规则（含 pass out quick on utunN all）；
#      - 以 <= 1s 轮询监听状态或接口名变化，仅在变化或规则缺失时重载 pf。
#
# 没有任何 `enabled` 标记时不碰 pf：装好但没启用的状态下，机器网络保持原样。

set -u
BASE="/Library/Application Support/qingzhou-guard"
PORT="$(cat "$BASE/port" 2>/dev/null || echo 10808)"
CONTROL_PORT="$(cat "$BASE/control-port" 2>/dev/null || echo 10809)"
ANCHOR="com.apple/qingzhou_guard"
RENDERED="$BASE/qingzhou-guard.rendered.conf"
LAST_STATE=""

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

enable_pf_with_token() {
  if [ -s "$BASE/pf-token" ]; then
    if pfctl -s info 2>/dev/null | grep -q 'Status: Enabled'; then
      return 0
    fi
    rm -f "$BASE/pf-token"
  fi
  E_OUT="$(pfctl -E 2>&1 || true)"
  TOKEN="$(printf '%s\n' "$E_OUT" | sed -n 's/.*Token[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)"
  if [ -n "$TOKEN" ]; then
    printf '%s' "$TOKEN" > "$BASE/pf-token"
    chmod 600 "$BASE/pf-token"
  fi
}

render_rules() {
  dev="$1"
  if [ -n "$dev" ]; then
    sed "s/__TUN_DEV__/${dev}/g" "$BASE/qingzhou-guard.conf" > "$RENDERED" 2>/dev/null || return 1
  else
    # 无 utun 时剥离 __TUN_DEV__ 规则行（保留文件头注释与 lo0 / 局域网 / root / block out quick all）
    sed '/^pass .*__TUN_DEV__/d' "$BASE/qingzhou-guard.conf" > "$RENDERED" 2>/dev/null || return 1
  fi
  chmod 600 "$RENDERED"
  return 0
}

apply_rules() {
  dev="$(find_tun_dev || true)"
  render_rules "$dev" || return 1
  if [ -n "$dev" ]; then
    new_state="tun:${dev}"
  else
    new_state="none"
  fi
  pfctl -a "$ANCHOR" -f "$RENDERED" >/dev/null 2>&1 || { log "pfctl 加载失败"; return 1; }
  enable_pf_with_token
  LAST_STATE="$new_state"
  return 0
}

if [ -f "$BASE/enabled" ]; then
  if apply_rules; then
    log "pf 规则已加载（锚点 ${ANCHOR}，状态 ${LAST_STATE}，中继端口 ${PORT}）"
  fi
else
  log "未启用断网开关（无 enabled 标记），只启动中继"
fi

"$BASE/qingzhou-relay" --port "$PORT" --control-port "$CONTROL_PORT" --auth-file "$BASE/relay-auth" --log /var/log/qingzhou-relay.log &
RELAY=$!
log "中继已启动 pid=$RELAY"

# 主循环：中继退出就跟着退出（KeepAlive 会整体重启）；
# <= 1s 感知 utun 出现/消失/改名以及锚点被外部清空，仅在变化或缺失时重载 pfctl。
while kill -0 "$RELAY" 2>/dev/null; do
  sleep 1
  if [ -f "$BASE/enabled" ]; then
    cur="$(find_tun_dev || true)"
    if [ -n "$cur" ]; then
      desired="tun:${cur}"
    else
      desired="none"
    fi
    rules_now="$(pfctl -s rules -a "$ANCHOR" 2>/dev/null || true)"
    if [ -z "$rules_now" ]; then
      log "锚点规则为空，重新加载（状态 ${desired}）"
      apply_rules || true
    elif [ "$desired" != "$LAST_STATE" ]; then
      log "隧道状态变化：${LAST_STATE:-init} → ${desired}，更新 pf 规则"
      apply_rules || true
    elif ! pfctl -s info 2>/dev/null | grep -q 'Status: Enabled'; then
      log "pf 未启用，重新加载（状态 ${desired}）"
      apply_rules || true
    fi
  else
    LAST_STATE=""
  fi
done

log "中继已退出，guard-run 结束"
wait "$RELAY"
