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

log() { echo "$(date '+%F %T') [guard-run] $*"; }

apply_rules() {
  pfctl -a "$ANCHOR" -f "$BASE/qingzhou-guard.conf" >/dev/null 2>&1
  pfctl -E >/dev/null 2>&1 || true
}

if [ -f "$BASE/enabled" ]; then
  apply_rules
  log "pf 规则已加载（锚点 $ANCHOR，端口 $PORT）"
else
  log "未启用断网开关（无 enabled 标记），只启动中继"
fi

"$BASE/qingzhou-relay" --port "$PORT" --auth-file "$BASE/relay-auth" --log /var/log/qingzhou-relay.log &
RELAY=$!
log "中继已启动 pid=$RELAY"

# 主循环：中继退出就跟着退出（KeepAlive 会整体重启）；
# 同时定期补 pf 规则，防止被别的程序清掉。
while kill -0 "$RELAY" 2>/dev/null; do
  sleep 10
  if [ -f "$BASE/enabled" ]; then
    apply_rules
  fi
done

log "中继已退出，guard-run 结束"
wait "$RELAY"
