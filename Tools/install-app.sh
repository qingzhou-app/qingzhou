#!/bin/bash
# 一条命令：构建 → 备份 → 替换 → 重启 → 验收；任何一步失败自动回滚。
#
# 用法（在「终端」里跑，不要通过 AI 助手，因为它会把你的网短暂中断）：
#   sh Tools/install-app.sh
#
# 为什么必须自己跑、而且一次性跑完：
#   替换 App 必须先把正在运行的轻舟退出 —— 你此刻的网络（包括 AI 助手的连接）
#   就是经它走的。退出那几秒连接会断，所以整段操作必须由一个不依赖网络会话的
#   脚本跑完，并在结尾把 VPN 重新拉起来。
#
# 不需要 sudo：/Applications 对 admin 组可写。

set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
APP_DST="/Applications/Qingzhou.app"
BACKUP_ROOT="$HOME/Downloads/backup/轻舟/app-$TS"
BUILD_DIR="/tmp/qingzhou-build-$TS"
LOG="$BACKUP_ROOT/install.log"
OLD_PID=""

mkdir -p "$BACKUP_ROOT"
exec > >(tee -a "$LOG") 2>&1

log() { echo "$(date '+%F %T') $*"; }
fail() { log "❌ $*"; }

log "===== 轻舟安装开始 $TS ====="
log "仓库：$REPO"
log "日志：$LOG"

# ---------- 1. 预检 ----------
log "--- 1/7 预检"
for tool in xcodegen xcodebuild ditto codesign curl; do
  command -v "$tool" >/dev/null 2>&1 || { fail "缺少 $tool"; exit 1; }
done
[ -d "$APP_DST" ] || { fail "$APP_DST 不存在 —— 这不是替换安装的场景，已停止"; exit 1; }
[ -f "$REPO/Apps/project.yml" ] || { fail "仓库路径不对：$REPO"; exit 1; }
log "    OK"

# ---------- 2. 构建 ----------
log "--- 2/7 构建 Release（需要几分钟）"
( cd "$REPO" && xcodegen generate --spec Apps/project.yml >/dev/null 2>&1 )
if ! ( cd "$REPO" && xcodebuild -project Apps/Qingzhou.xcodeproj -scheme Qingzhou-macOS \
        -configuration Release -destination 'generic/platform=macOS' \
        -derivedDataPath "$BUILD_DIR" -allowProvisioningUpdates build > "$BUILD_DIR.log" 2>&1 ); then
  fail "构建失败，详见 $BUILD_DIR.log"
  tail -30 "$BUILD_DIR.log"
  exit 1
fi
NEW_APP="$BUILD_DIR/Build/Products/Release/Qingzhou.app"
[ -d "$NEW_APP" ] || { fail "构建产物不存在：$NEW_APP"; exit 1; }
[ -d "$NEW_APP/Contents/PlugIns/Qingzhou-Tunnel-macOS.appex" ] || { fail "缺少隧道扩展"; exit 1; }
if ! codesign --verify --deep --strict "$NEW_APP" >/dev/null 2>&1; then
  fail "新构建的签名校验失败，拒绝安装"; exit 1
fi
log "    OK：$NEW_APP"

# ---------- 3. 备份现有 App ----------
log "--- 3/7 备份当前 App"
if ! ditto "$APP_DST" "$BACKUP_ROOT/Qingzhou.app"; then
  fail "备份失败 —— 不改任何东西，已停止"; exit 1
fi
log "    OK：$BACKUP_ROOT/Qingzhou.app"

# ---------- 4. 退出轻舟 ----------
log "--- 4/7 退出轻舟（此刻网络会短暂中断）"
osascript -e 'tell application "Qingzhou" to quit' >/dev/null 2>&1 || true
i=0
while [ $i -lt 15 ]; do
  pgrep -f "Qingzhou.app/Contents/MacOS/Qingzhou" >/dev/null 2>&1 || break
  sleep 1; i=$((i+1))
done
pkill -f "Qingzhou.app/Contents/MacOS/Qingzhou" >/dev/null 2>&1 || true
sleep 2
log "    已退出（等了 ${i}s）"

# ---------- 5. 替换 ----------
log "--- 5/7 替换 App"
if ! rm -rf "$APP_DST"; then
  fail "无法删除旧 App"; exit 1
fi
if ! ditto "$NEW_APP" "$APP_DST"; then
  fail "复制新 App 失败 —— 立刻回滚"
  ditto "$BACKUP_ROOT/Qingzhou.app" "$APP_DST"
  open "$APP_DST"
  exit 1
fi
# 去掉隔离标记，避免首次启动弹"来自互联网"
xattr -dr com.apple.quarantine "$APP_DST" 2>/dev/null || true
log "    OK"

# ---------- 6. 重启并等待 VPN ----------
log "--- 6/7 重开轻舟并等待连接"
open "$APP_DST"
CONNECTED=0
j=0
while [ $j -lt 24 ]; do
  sleep 4
  if scutil --nc list 2>/dev/null | grep -q '(Connected)'; then CONNECTED=1; break; fi
  j=$((j+1))
done
log "    VPN 连接：$([ $CONNECTED -eq 1 ] && echo 是 || echo 否)（等了 $((j*4))s）"

# ---------- 7. 验收：真实出网 ----------
log "--- 7/7 验收（普通用户身份、清空代理变量）"
HTTP=""
if [ $CONNECTED -eq 1 ]; then
  for attempt in 1 2 3; do
    HTTP="$(env -u http_proxy -u https_proxy -u ALL_PROXY -u all_proxy \
      curl -sS --noproxy '*' -m 12 -o /dev/null -w '%{http_code}' https://claude.ai/ 2>/dev/null || echo 000)"
    [ "$HTTP" = "200" ] && break
    sleep 5
  done
fi
log "    https://claude.ai/ → $HTTP"

if [ "$CONNECTED" -eq 1 ] && [ "$HTTP" = "200" ]; then
  log "===== 安装成功 ====="
  log "旧版本备份：$BACKUP_ROOT/Qingzhou.app"
  log "回滚命令：pkill -f Qingzhou.app; ditto \"$BACKUP_ROOT/Qingzhou.app\" \"$APP_DST\"; open \"$APP_DST\""
  exit 0
fi

# ---------- 失败回滚 ----------
fail "验收未通过（VPN=$CONNECTED HTTP=$HTTP），开始回滚"
osascript -e 'tell application "Qingzhou" to quit' >/dev/null 2>&1 || true
sleep 2
pkill -f "Qingzhou.app/Contents/MacOS/Qingzhou" >/dev/null 2>&1 || true
sleep 1
rm -rf "$APP_DST"
ditto "$BACKUP_ROOT/Qingzhou.app" "$APP_DST"
open "$APP_DST"
R=0
k=0
while [ $k -lt 24 ]; do
  sleep 4
  if scutil --nc list 2>/dev/null | grep -q '(Connected)'; then R=1; break; fi
  k=$((k+1))
done
if [ $R -eq 1 ]; then
  log "已回滚到旧版本，VPN 已连上。"
  exit 1
else
  log "⚠️ 回滚后 VPN 仍未连上。手动处理：打开「轻舟」App，或看 docs/SPLIT-EXIT.md 的自救步骤。"
  exit 2
fi
