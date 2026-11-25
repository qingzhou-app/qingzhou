#!/bin/sh
# qingzhou-guard 交互式 / sudo 端到端验收脚本（需要 root 权限与显式确认）。
#
# ⚠️ 警告：本脚本会在当前 Mac 上执行以下有系统副作用的操作：
#   1. 编译并安装 /Library/Application Support/qingzhou-guard 与 LaunchDaemon；
#   2. 校验 10808 SOCKS5 转发与 10809 控制端口，并通过 systemsetup 临时切换系统时区再还原；
#   3. 若指定 --with-pf（或检测到活跃的轻舟 utun + relay 配置），测试 enable.sh / off.sh 锚点规则；
#   4. 默认在结束时运行 uninstall.sh 验证时区还原与文件清理（可用 --keep-installed 跳过卸载）。
#
# 用法：
#   sudo sh Tools/verify-guard-e2e.sh [--yes-i-know] [--with-pf] [--keep-installed]

set -eu

YES_I_KNOW=0
WITH_PF=0
KEEP_INSTALLED=0

for arg in "$@"; do
  case "$arg" in
    --yes-i-know)
      YES_I_KNOW=1
      ;;
    --with-pf)
      WITH_PF=1
      ;;
    --keep-installed)
      KEEP_INSTALLED=1
      ;;
    -h|--help)
      cat <<'EOF'
Usage: sudo sh Tools/verify-guard-e2e.sh [--yes-i-know] [--with-pf] [--keep-installed]

Options:
  --yes-i-know      Skip interactive confirmation prompt after safety warning
  --with-pf         Require and test enable.sh / pf anchor / off.sh lifecycle
  --keep-installed  Skip uninstall.sh at the end (leaves qingzhou-guard installed)
EOF
      exit 0
      ;;
    *)
      echo "Unknown option: ${arg}" >&2
      exit 2
      ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "错误：本脚本必须以 root 运行，例如：" >&2
  echo "  sudo sh Tools/verify-guard-e2e.sh --yes-i-know" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

BASE="/Library/Application Support/qingzhou-guard"
PLIST="/Library/LaunchDaemons/com.sbraveyoung.qingzhou.guard.plist"
ANCHOR="com.apple/qingzhou_guard"
PORT="${QINGZHOU_GUARD_PORT:-10808}"
CONTROL_PORT="${QINGZHOU_GUARD_CONTROL_PORT:-10809}"

echo "======================================================================"
echo "⚠️  qingzhou-guard E2E 验收即将修改系统状态："
echo "   - 安装/覆盖 ${BASE} 与 ${PLIST}"
echo "   - 临时修改系统时区（测试 SET-TZ / RESTORE）"
if [ "$WITH_PF" -eq 1 ]; then
  echo "   - 启用并测试 pf 锚点 ${ANCHOR}（随后通过 off.sh 清理）"
fi
if [ "$KEEP_INSTALLED" -eq 0 ]; then
  echo "   - 验收末尾将执行 uninstall.sh 还原时区并卸载组件"
fi
echo "======================================================================"

if [ "$YES_I_KNOW" -ne 1 ]; then
  printf "输入 YES 继续，其他任意输入中止: "
  read -r REPLY
  if [ "$REPLY" != "YES" ]; then
    echo "已取消。"
    exit 1
  fi
fi

get_sys_tz() {
  /usr/sbin/systemsetup -gettimezone | sed 's/^Time Zone:[[:space:]]*//' | tr -d '\r\n'
}

ORIG_TZ="$(get_sys_tz)"
if [ -z "$ORIG_TZ" ]; then
  echo "错误：无法读取当前系统时区" >&2
  exit 1
fi
if [ "$ORIG_TZ" = "America/New_York" ]; then
  ALT_TZ="Europe/London"
else
  ALT_TZ="America/New_York"
fi

PF_TOUCHED=0
cleanup() {
  RC=$?
  if [ "$PF_TOUCHED" -eq 1 ] && [ -x "${BASE}/off.sh" ]; then
    sh "${BASE}/off.sh" >/dev/null 2>&1 || true
  fi
  NOW_TZ="$(get_sys_tz || true)"
  if [ -n "$ORIG_TZ" ] && [ -n "$NOW_TZ" ] && [ "$NOW_TZ" != "$ORIG_TZ" ]; then
    /usr/sbin/systemsetup -settimezone "$ORIG_TZ" >/dev/null 2>&1 || true
  fi
  if [ "$RC" -ne 0 ]; then
    echo
    echo "❌ verify-guard-e2e.sh 中途失败（exit=${RC}），已尝试还原系统时区为 ${ORIG_TZ} 并清理 ${ANCHOR}。" >&2
  fi
}
trap cleanup EXIT INT TERM

echo
echo "==> 1/5 编译并安装 qingzhou-guard"
sh Tools/qingzhou-guard/build-relay.sh
sh Tools/qingzhou-guard/install.sh

if [ ! -f "${BASE}/relay-auth" ]; then
  echo "错误：缺少 ${BASE}/relay-auth" >&2
  exit 1
fi
AUTH_MODE="$(stat -f '%Lp' "${BASE}/relay-auth")"
if [ "$AUTH_MODE" != "600" ]; then
  echo "错误：${BASE}/relay-auth 权限应为 600，实际为 ${AUTH_MODE}" >&2
  exit 1
fi

FU="$(grep '^forward:' "${BASE}/relay-auth" | head -1 | cut -d: -f2)"
FP="$(grep '^forward:' "${BASE}/relay-auth" | head -1 | cut -d: -f3-)"
CU="$(grep '^control:' "${BASE}/relay-auth" | head -1 | cut -d: -f2)"
CP="$(grep '^control:' "${BASE}/relay-auth" | head -1 | cut -d: -f3-)"
if [ -z "$FU" ] || [ -z "$FP" ] || [ -z "$CU" ] || [ -z "$CP" ] || { [ "$FU" = "$CU" ] && [ "$FP" = "$CP" ]; }; then
  echo "错误：relay-auth 分离凭据无效或相等" >&2
  exit 1
fi
echo "  OK: relay-auth 权限 600 且 forward/control 凭据已分离"

launchctl print system/com.sbraveyoung.qingzhou.guard >/dev/null 2>&1
echo "  OK: LaunchDaemon com.sbraveyoung.qingzhou.guard 已激活"

echo
echo "==> 2/5 验证 127.0.0.1:${PORT} SOCKS5 转发"
HTTP_CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 --proxy "socks5h://${FU}:${FP}@127.0.0.1:${PORT}" https://example.com/)"
if [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "301" ] && [ "$HTTP_CODE" != "302" ]; then
  echo "错误：经 SOCKS5 中继访问 https://example.com/ 返回 HTTP ${HTTP_CODE}" >&2
  exit 1
fi
echo "  OK: SOCKS5 转发正常（HTTP ${HTTP_CODE}）"

echo
echo "==> 3/5 验证 127.0.0.1:${CONTROL_PORT} 控制协议与系统时区切换/还原（原时区: ${ORIG_TZ}，测试时区: ${ALT_TZ}）"
python3 - "$CONTROL_PORT" "$CU" "$CP" "$FU" "$FP" "$ORIG_TZ" "$ALT_TZ" "${BASE}/timezone-orig" <<'PY'
import socket, subprocess, sys, os

cport, cu, cp, fu, fp, orig_tz, alt_tz, tz_orig_path = sys.argv[1:9]
cport = int(cport)

def get_tz():
    out = subprocess.check_output(["/usr/sbin/systemsetup", "-gettimezone"], text=True)
    return out.split("Time Zone:", 1)[1].strip()

def send_cmds(cmds):
    with socket.create_connection(("127.0.0.1", cport), timeout=5) as s:
        f = s.makefile("rw", encoding="utf-8", newline="\n")
        replies = []
        for cmd in cmds:
            f.write(cmd + "\n")
            f.flush()
            replies.append(f.readline().rstrip("\r\n"))
        return replies

# 1. 转发凭据必须被控制口拒绝
r_bad = send_cmds([f"AUTH {fu} {fp}"])
assert r_bad[0].startswith("ERR"), f"expected ERR for forward creds on control port, got {r_bad}"

# 2. 合法控制凭据 AUTH + GET-TZ + SET-TZ alt_tz
r1 = send_cmds([f"AUTH {cu} {cp}", "GET-TZ", f"SET-TZ {alt_tz}"])
assert r1 == ["OK", orig_tz, "OK"], f"unexpected replies 1: {r1}"
assert get_tz() == alt_tz, f"expected system TZ {alt_tz}, got {get_tz()}"
assert os.path.isfile(tz_orig_path), f"missing {tz_orig_path}"
with open(tz_orig_path, "r", encoding="utf-8") as fh:
    assert fh.read().strip() == orig_tz, "timezone-orig mismatch"

# 3. 切回 orig_tz（验证 M1 currentTimeZone() 修复）
r2 = send_cmds([f"AUTH {cu} {cp}", f"SET-TZ {orig_tz}"])
assert r2 == ["OK", "OK"], f"unexpected replies 2: {r2}"
assert get_tz() == orig_tz, f"failed to switch back to {orig_tz}, got {get_tz()}"

# 4. 再次切到 alt_tz 并执行 RESTORE
r3 = send_cmds([f"AUTH {cu} {cp}", f"SET-TZ {alt_tz}", "RESTORE"])
assert r3 == ["OK", "OK", "OK"], f"unexpected replies 3: {r3}"
assert get_tz() == orig_tz, f"RESTORE failed, got {get_tz()}"
print("  OK: 控制口 AUTH / 拒绝转发凭据 / GET-TZ / SET-TZ 往返 / RESTORE 全部通过")
PY

echo
echo "==> 4/5 检查 pf 断网开关生命周期"
TUN_ACTIVE=""
for dev in $(ifconfig -l 2>/dev/null); do
  case "$dev" in
    utun*) ifconfig "$dev" 2>/dev/null | grep -q 'inet 10\.0\.10\.1 ' && TUN_ACTIVE="$dev" && break ;;
  esac
done

if [ "$WITH_PF" -eq 1 ] || [ -n "$TUN_ACTIVE" ]; then
  if [ "$WITH_PF" -eq 0 ]; then
    echo "  检测到活跃轻舟隧道 (${TUN_ACTIVE})，但未传 --with-pf；为避免误触当前 VPN/pf，跳过 enable.sh（需要验收 pf 请传 --with-pf）。"
  else
    PF_WAS_ENABLED=0
    if pfctl -s info 2>/dev/null | grep -q 'Status: Enabled'; then
      PF_WAS_ENABLED=1
    fi
    PF_TOUCHED=1
    sh "${BASE}/enable.sh"
    RULES_NOW="$(pfctl -s rules -a "$ANCHOR" 2>/dev/null || true)"
    if [ -z "$RULES_NOW" ] || ! printf '%s\n' "$RULES_NOW" | grep -Eq 'block (drop )?out'; then
      echo "错误：enable.sh 后锚点 ${ANCHOR} 缺少预期 block 规则" >&2
      exit 1
    fi
    # 确认 guard-run.sh 1s 轮询期间规则保持稳定
    sleep 2
    RULES_AFTER="$(pfctl -s rules -a "$ANCHOR" 2>/dev/null || true)"
    if [ -z "$RULES_AFTER" ]; then
      echo "错误：guard-run.sh 轮询后锚点 ${ANCHOR} 意外变空" >&2
      exit 1
    fi
    sh "${BASE}/off.sh"
    PF_TOUCHED=0
    RULES_OFF="$(pfctl -s rules -a "$ANCHOR" 2>/dev/null || true)"
    if [ -n "$RULES_OFF" ]; then
      echo "错误：off.sh 后锚点 ${ANCHOR} 未清空" >&2
      exit 1
    fi
    if [ "$PF_WAS_ENABLED" -eq 1 ] && ! pfctl -s info 2>/dev/null | grep -q 'Status: Enabled'; then
      echo "错误：off.sh 意外关闭了原本处于启用状态的全局 pf" >&2
      exit 1
    fi
    echo "  OK: enable.sh -> guard-run.sh 保持 -> off.sh 仅清锚点（保留无关 pf 状态）通过"
  fi
else
  echo "  SKIPPED: 当前无轻舟 utun (10.0.10.1) 且未指定 --with-pf"
fi

echo
echo "==> 5/5 验收 uninstall.sh 时区还原与清理"
if [ "$KEEP_INSTALLED" -eq 1 ]; then
  echo "  SKIPPED: 已指定 --keep-installed，保留 ${BASE}"
else
  # 故意先切到 ALT_TZ，确认 uninstall.sh 第 2/5 步能自动还原至 ORIG_TZ
  python3 - "$CONTROL_PORT" "$CU" "$CP" "$ALT_TZ" <<'PY'
import socket, sys
cport, cu, cp, alt_tz = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
with socket.create_connection(("127.0.0.1", cport), timeout=5) as s:
    f = s.makefile("rw", encoding="utf-8", newline="\n")
    for cmd in (f"AUTH {cu} {cp}", f"SET-TZ {alt_tz}"):
        f.write(cmd + "\n")
        f.flush()
        reply = f.readline().rstrip("\r\n")
        assert reply == "OK", f"{cmd} -> {reply}"
PY
  sh "${BASE}/uninstall.sh"
  TZ_AFTER_UNINSTALL="$(get_sys_tz)"
  if [ "$TZ_AFTER_UNINSTALL" != "$ORIG_TZ" ]; then
    echo "错误：uninstall.sh 后系统时区未还原为 ${ORIG_TZ}（当前：${TZ_AFTER_UNINSTALL}）" >&2
    exit 1
  fi
  if [ -d "$BASE" ] || [ -f "$PLIST" ] \
     || [ -f /var/log/qingzhou-relay.log ] \
     || [ -f /var/log/qingzhou-relay.log.1 ] \
     || [ -f /var/log/qingzhou-guard.log ]; then
    echo "错误：uninstall.sh 后仍有残留目录、plist 或日志文件" >&2
    exit 1
  fi
  echo "  OK: uninstall.sh 已还原系统时区 (${TZ_AFTER_UNINSTALL}) 并清理所有文件与日志"
fi

echo
echo "✅ verify-guard-e2e.sh 全部验收通过。"
