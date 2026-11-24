#!/bin/sh
# 只读体检：确认断网开关能不能成立、当前处在什么状态。
#
# 用法： sh diagnose.sh            （不需要 sudo，能查的先查）
#        sudo sh diagnose.sh       （补上需要 root 的部分：pf 状态/规则/进程 uid）
#
# 这个脚本**不改任何东西**：不加载规则、不启停服务、不碰 VPN。

set -u
echo "===== 1. 轻舟 VPN 状态 ====="
scutil --nc list 2>/dev/null | sed 's/^/  /' || echo "  (scutil 不可用)"

echo
echo "===== 2. 隧道接口与默认路由 ====="
echo "  --- IPv4 默认路由 ---"
netstat -rn -f inet 2>/dev/null | awk '$1=="default"' | sed 's/^/  /'
echo "  --- IPv6 默认路由 ---"
netstat -rn -f inet6 2>/dev/null | awk '$1=="default"' | sed 's/^/  /'

echo
echo "===== 3. 代理进程的真实 UID（决定 pf 规则能不能只放行代理）====="
python3 - <<'PY'
import ctypes
try:
    lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
except OSError:
    print("  libproc 不可用"); raise SystemExit
lib.proc_listpids.restype = ctypes.c_int
lib.proc_listpids.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_int]
lib.proc_pidinfo.restype = ctypes.c_int
lib.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
need = lib.proc_listpids(1, 0, None, 0)
if need <= 0:
    print("  proc_listpids 不可用"); raise SystemExit
buf = (ctypes.c_int * (need // 4))()
got = lib.proc_listpids(1, 0, buf, need)
raw = (ctypes.c_char * 256)()
rows = []
for i in range(got // 4):
    pid = buf[i]
    if pid <= 0: continue
    r = lib.proc_pidinfo(pid, 3, 0, raw, 256)
    if r <= 0: continue
    b = bytes(raw[:r])
    uid = int.from_bytes(b[20:24], 'little')
    comm = b[48:64].split(b'\x00')[0].decode('utf-8', 'replace')
    if 'qingzhou' in comm.lower():
        rows.append((pid, uid, comm))
if rows:
    for pid, uid, comm in sorted(rows):
        print(f"  pid={pid:<7} uid={uid:<6} {comm}")
    print("  ↑ 若 tunnel 进程的 uid 不是 0，则「只放行 root」必须配合 root 中继才成立")
else:
    print("  未发现轻舟进程（VPN 可能没在跑）")
PY

echo
echo "===== 4. 断网开关组件状态 ====="
BASE="/Library/Application Support/qingzhou-guard"
if [ -d "$BASE" ]; then
  echo "  目录：存在"
  ls -la "$BASE" 2>/dev/null | sed 's/^/    /'
  printf "  拦截开关："; [ -f "$BASE/enabled" ] && echo "已启用（正在拦截）" || echo "未启用"
else
  echo "  目录：不存在（尚未安装）"
fi
printf "  LaunchDaemon："
if launchctl print system/com.sbraveyoung.qingzhou.guard >/dev/null 2>&1; then
  echo "已加载"
else
  echo "未加载"
fi
printf "  plist："; [ -f /Library/LaunchDaemons/com.sbraveyoung.qingzhou.guard.plist ] && echo "存在" || echo "不存在"

echo
echo "===== 5. pf 状态 ====="
if [ "$(id -u)" -eq 0 ]; then
  pfctl -s info 2>/dev/null | head -4 | sed 's/^/  /'
  echo "  --- 锚点 com.apple/qingzhou_guard ---"
  R="$(pfctl -s rules -a com.apple/qingzhou_guard 2>/dev/null)"
  if [ -n "$R" ]; then echo "$R" | sed 's/^/  /'; else echo "  （空）"; fi
else
  echo "  需要 root 才能读 pf 状态 —— 用 sudo 再跑一次这个脚本"
  echo "  /etc/pf.conf 里的锚点（只读）："
  grep -n 'anchor' /etc/pf.conf 2>/dev/null | sed 's/^/    /'
fi

echo
echo "===== 6. 结论提示 ====="
echo "  · 隧道扩展若是 uid 501（普通用户），pf 无法区分「代理的出站」和「普通程序的出站」，"
echo "    必须让代理经 root 中继出网，才能既不断网又零泄漏。"
echo "  · 安装后**先不启用**（install.sh 不会加载 pf 规则），把代理串到中继、确认能上网后，"
echo "    再执行 enable.sh。顺序颠倒会立刻断网。"
