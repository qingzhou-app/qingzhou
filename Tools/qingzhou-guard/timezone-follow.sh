#!/bin/sh
# 跟随出口地区改系统时区（由 guard-run.sh 的循环调用）。
#
# 数据流：App 拿到出口时区 → 写 App Group 的 `follow-timezone.json`（含目标时区或"还原"）
# → guard-run.sh 每 10 秒读一次 → 检测到变化就调本脚本（root 权限）→ 改系统时区。
#
# 三条纪律：
#   1. 只改时区，**绝不动系统语言**（改 AppleLanguages 需要注销登录，副作用太大）。
#   2. 首次切换前记录「原时区」，隧道断开后还原 —— 不能把用户机器永久留在出口时区。
#   3. 目标时区校验失败（非法）就忽略，不写坏系统。

set -u
BASE="/Library/Application Support/qingzhou-guard"
STATE="$BASE/timezone-state"       # 记录原时区
LAST="$BASE/timezone-last"        # 上次应用的目标（去重，避免每 10 秒重复执行）

log() { echo "$(date '+%F %T') [guard-tz] $*"; }

# 从 App Group 读指令（JSON：{"timezone":"Asia/Singapore"} 或 {"timezone":""} 表示还原）
INSTRUCTION="$1"
TZ_VALUE="$2"

apply() {
  local target="$1"
  # 还原：有记录的原时区就用原时区，否则用系统当前时区
  if [ -z "$target" ]; then
    if [ -f "$STATE" ]; then
      target="$(cat "$STATE")"
      log "还原时区 → $target"
    else
      log "无原时区记录，不还原"
      return 0
    fi
  fi

  # 校验：必须是合法 IANA 时区（systemsetup 会拒绝非法值，但先自检更干净）
  if [ ! -f "/usr/share/zoneinfo/$target" ]; then
    log "非法时区，忽略：$target"
    return 1
  fi

  # 首次切换：记录原时区（读系统当前时区）
  if [ ! -f "$STATE" ]; then
    local orig
    orig="$(systemsetup -gettimezone 2>/dev/null | awk -F': ' '{print $2}')"
    if [ -n "$orig" ] && [ -f "/usr/share/zoneinfo/$orig" ]; then
      printf '%s' "$orig" > "$STATE"
      chmod 600 "$STATE"
      log "记录原时区：$orig"
    fi
  fi

  # 去重：目标没变就跳过（避免每 10 秒重复执行 systemsetup）
  if [ -f "$LAST" ] && [ "$(cat "$LAST")" = "$target" ]; then
    return 0
  fi

  if systemsetup -settimezone "$target" >/dev/null 2>&1; then
    printf '%s' "$target" > "$LAST"
    chmod 600 "$LAST"
    log "系统时区 → $target"
    return 0
  else
    log "设置时区失败：$target"
    return 1
  fi
}

apply "$TZ_VALUE"
