#!/bin/sh
# 一条命令：构建 → 备份 → 替换 → 重启 → 验收；任何一步失败自动回滚。
#
# 用法（在「终端」里跑，不要通过 AI 助手，因为它会把你的网短暂中断）：
#   sh Tools/install-app.sh          # 正式安装
#   sh Tools/install-app.sh --check  # 只做预检，不构建、不改动任何东西
#
# 为什么必须自己跑、而且一次性跑完：
#   替换 App 必须先把正在运行的轻舟退出 —— 你此刻的网络（包括 AI 助手的连接）
#   就是经它走的。退出那几秒连接会断，所以整段操作必须由一个不依赖网络会话的
#   脚本一口气跑完，并在结尾把 VPN 重新拉起来。
#
# 不需要 sudo：/Applications 对 admin 组可写。
#
# 兼容性说明：全文只用 POSIX sh 语法（不用 >( ) 进程替换、不用数组），
# 所以 `sh` / `bash` / `zsh` 下都能直接跑。

set -u

MODE="install"
case "${1:-}" in
  --check) MODE="check" ;;
  "" ) ;;
  * ) echo "未知参数：$1（可用：--check）" >&2; exit 2 ;;
esac

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
APP_DST="/Applications/Qingzhou.app"
BACKUP_ROOT="$HOME/Downloads/backup/轻舟/app-$TS"
BUILD_DIR="/tmp/qingzhou-build-$TS"

if [ "$MODE" = "check" ]; then
  LOG="/tmp/qingzhou-install-check.log"
  : > "$LOG"
else
  mkdir -p "$BACKUP_ROOT"
  LOG="$BACKUP_ROOT/install.log"
  : > "$LOG"
fi

# 同时打印到终端与日志文件（POSIX 做法，不依赖 tee 子进程）
log() {
  line="$(date '+%F %T') $*"
  printf '%s\n' "$line"
  printf '%s\n' "$line" >>"$LOG"
}
# 把某文件的后 N 行格式化进日志/终端
logtail() {
  file="$1"; n="${2:-30}"
  tail -n "$n" "$file" 2>/dev/null | while IFS= read -r l; do
    printf '    %s\n' "$l"
    printf '    %s\n' "$l" >>"$LOG"
  done
}

log "===== 轻舟安装开始 ${TS}（模式：${MODE}）====="
log "仓库：$REPO"

# ---------- 1. 预检 ----------
log "--- 1/7 预检"
for tool in xcodegen xcodebuild ditto codesign curl security; do
  command -v "$tool" >/dev/null 2>&1 || { log "❌ 缺少 $tool"; exit 1; }
done
[ -d "$APP_DST" ] || { log "❌ $APP_DST 不存在 —— 这不是替换安装的场景，已停止"; exit 1; }
[ -f "$REPO/Apps/project.yml" ] || { log "❌ 仓库路径不对：$REPO"; exit 1; }
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Development"; then
  log "❌ 找不到 Apple Development 签名身份，构建出的 App 无法启用 VPN"
  exit 1
fi
CUR_TEAM="$(codesign -dv --verbose=2 "$APP_DST" 2>&1 | awk -F= '/TeamIdentifier/{print $2}')"
WRITABLE="否"
[ -w /Applications ] && WRITABLE="是"
log "    签名身份：OK；当前 App 团队：${CUR_TEAM:-未知}；/Applications 可写：$WRITABLE"
log "    OK"

if [ "$MODE" = "check" ]; then
  log "===== 预检通过（--check 到此结束，没有构建、没有改动任何东西）====="
  exit 0
fi

# ---------- 2. 构建 ----------
log "--- 2/7 构建 Release（需要几分钟，期间网络正常）"
( cd "$REPO" && xcodegen generate --spec Apps/project.yml >/dev/null 2>&1 )
BUILD_LOG="$BUILD_DIR.log"
if ! ( cd "$REPO" && xcodebuild -project Apps/Qingzhou.xcodeproj -scheme Qingzhou-macOS \
        -configuration Release -destination 'generic/platform=macOS' \
        -derivedDataPath "$BUILD_DIR" -allowProvisioningUpdates build >"$BUILD_LOG" 2>&1 ); then
  log "❌ 构建失败"
  logtail "$BUILD_LOG" 40
  log "完整日志：$BUILD_LOG"
  exit 1
fi
NEW_APP="$BUILD_DIR/Build/Products/Release/Qingzhou.app"
[ -d "$NEW_APP" ] || { log "❌ 构建产物不存在：$NEW_APP"; exit 1; }
[ -d "$NEW_APP/Contents/PlugIns/Qingzhou-Tunnel-macOS.appex" ] || { log "❌ 缺少隧道扩展"; exit 1; }
if ! codesign --verify --deep --strict "$NEW_APP" >/dev/null 2>&1; then
  log "❌ 新构建的签名校验失败，拒绝安装"
  exit 1
fi
log "    OK：$NEW_APP"

# ---------- 3. 备份 ----------
log "--- 3/7 备份当前 App"
if ! ditto "$APP_DST" "$BACKUP_ROOT/Qingzhou.app"; then
  log "❌ 备份失败 —— 不改任何东西，已停止"
  exit 1
fi
log "    OK：$BACKUP_ROOT/Qingzhou.app"

# ---------- 4. 退出 ----------
log "--- 4/7 退出轻舟（此刻你的网络会短暂中断）"
osascript -e 'tell application "Qingzhou" to quit' >/dev/null 2>&1 || true
i=0
while [ "$i" -lt 15 ]; do
  pgrep -f "Qingzhou.app/Contents/MacOS/Qingzhou" >/dev/null 2>&1 || break
  sleep 1; i=$((i+1))
done
pkill -f "Qingzhou.app/Contents/MacOS/Qingzhou" >/dev/null 2>&1 || true
sleep 2
log "    已退出（等了 ${i}s）"

# ---------- 5. 替换 ----------
log "--- 5/7 替换 App"
if ! rm -rf "$APP_DST"; then
  log "❌ 无法删除旧 App"
  exit 1
fi
if ! ditto "$NEW_APP" "$APP_DST"; then
  log "❌ 复制新 App 失败 —— 立刻回滚"
  ditto "$BACKUP_ROOT/Qingzhou.app" "$APP_DST"
  open "$APP_DST"
  exit 1
fi
xattr -dr com.apple.quarantine "$APP_DST" 2>/dev/null || true
# 证明「跑起来的确实是我刚构建的这个二进制」：比签名 CDHash，而不是比版本号
#（版本号这次没变，比版本号会得出"装成功了"的假结论）。
NEW_HASH="$(codesign -dv --verbose=4 "$NEW_APP" 2>&1 | awk -F= '/^CDHash=/{print $2}')"
DST_HASH="$(codesign -dv --verbose=4 "$APP_DST" 2>&1 | awk -F= '/^CDHash=/{print $2}')"
log "    二进制指纹：新=${NEW_HASH:-?} 已装=${DST_HASH:-?}"
if [ -n "$NEW_HASH" ] && [ "$NEW_HASH" = "$DST_HASH" ]; then
  log "    OK（已安装的就是刚构建的产物）"
else
  log "⚠️ 指纹不一致，但仍继续验收（以最终能否上网为准）"
fi

# ---------- 6. 重启等 VPN ----------
log "--- 6/7 重开轻舟并等待连接"
open "$APP_DST"
CONNECTED=0
j=0
while [ "$j" -lt 24 ]; do
  sleep 4
  if scutil --nc list 2>/dev/null | grep -q '(Connected)'; then CONNECTED=1; break; fi
  j=$((j+1))
done
log "    VPN 连接：$([ "$CONNECTED" -eq 1 ] && echo 是 || echo 否)（等了 $((j*4))s）"

# ---------- 7. 验收 ----------
#
# 判据用「专门测连通性的探针」，而不是 claude.ai：
# claude.ai 对裸 curl（无浏览器头）返回 403（Cloudflare 挑战页）——
# 那恰恰说明请求**到达了服务器**，网络是通的。上一版把它当失败，误触发回滚。
# generate_204 / api.ipify.org 不带任何头也返回 204 / 200，没有歧义。
log "--- 7/7 验收（普通用户身份、清空代理变量）"
PROBE_PRIMARY="https://www.gstatic.com/generate_204"
PROBE_IP="https://api.ipify.org"
CLEAN_ENV="env -u http_proxy -u https_proxy -u ALL_PROXY -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY"

# 刚换完 App 的头一两分钟，扩展可能还挂在旧会话上（系统会立刻显示"已连接"，
# 但 xray 没真正跑起来）—— 实测出现过：连接状态是"已连接"、国内通、海外全 000，
# 几分钟后自行恢复。所以这里不急着判失败：先耐心探，再强制重启一次隧道。
CODE="000"
SVC_ID="$(scutil --nc list 2>/dev/null | awk '/Qingzhou/ {for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F-]{36}$/) {print $i; exit}}')"

probe() {
  CODE="$($CLEAN_ENV curl -sS --noproxy '*' -m 12 -o /dev/null -w '%{http_code}' "$PROBE_PRIMARY" 2>/dev/null)"
  [ -z "$CODE" ] && CODE="000"
  [ "$CODE" = "204" ]
}

if [ "$CONNECTED" -eq 1 ]; then
  attempt=1
  while [ "$attempt" -le 6 ]; do
    probe && break
    # 第 3 次还不行，且拿得到服务 ID：停掉隧道让它重新完整启动一次
    if [ "$attempt" -eq 3 ] && [ -n "$SVC_ID" ]; then
      log "    探针未通，重启隧道一次（${SVC_ID}）"
      scutil --nc stop "$SVC_ID" >/dev/null 2>&1 || true
      sleep 3
      open "$APP_DST"
      sleep 8
    fi
    attempt=$((attempt+1)); sleep 10
  done
fi
log "    $PROBE_PRIMARY → ${CODE}（期望 204）"

if [ "$CODE" = "204" ]; then
  EXIT_IP="$($CLEAN_ENV curl -sS --noproxy '*' -m 12 "$PROBE_IP" 2>/dev/null)"
  log "    出口 IP：${EXIT_IP:-取不到}"
  CLAUDE_CODE="$($CLEAN_ENV curl -sS --noproxy '*' -m 12 -o /dev/null -w '%{http_code}' https://claude.ai/ 2>/dev/null)"
  log "    参考：https://claude.ai/ → ${CLAUDE_CODE:-000}（403 通常是 Cloudflare 挑战，说明已到达服务器）"
fi

if [ "$CONNECTED" -eq 1 ] && [ "$CODE" = "204" ]; then
  log "===== 安装成功 ====="
  log "旧版本备份：$BACKUP_ROOT/Qingzhou.app"
  log "回滚：pkill -f Qingzhou.app; ditto \"$BACKUP_ROOT/Qingzhou.app\" \"$APP_DST\"; open \"$APP_DST\""
  exit 0
fi

# ---------- 失败回滚 ----------
log "❌ 验收未通过（VPN=$CONNECTED 探针=${CODE}），开始回滚"
osascript -e 'tell application "Qingzhou" to quit' >/dev/null 2>&1 || true
sleep 2
pkill -f "Qingzhou.app/Contents/MacOS/Qingzhou" >/dev/null 2>&1 || true
sleep 1
rm -rf "$APP_DST"
ditto "$BACKUP_ROOT/Qingzhou.app" "$APP_DST"
open "$APP_DST"
R=0
k=0
while [ "$k" -lt 24 ]; do
  sleep 4
  if scutil --nc list 2>/dev/null | grep -q '(Connected)'; then R=1; break; fi
  k=$((k+1))
done
if [ "$R" -eq 1 ]; then
  log "已回滚到旧版本，VPN 已连上。"
  exit 1
else
  log "⚠️ 回滚后 VPN 仍未连上。手动打开「轻舟」App 试一次。"
  exit 2
fi
