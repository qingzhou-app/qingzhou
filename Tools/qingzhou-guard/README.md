# qingzhou-guard —— 断网开关（当前状态：代码与 M1 加固已完成并经本地单测/TSan 验证；目标机仍需用户手动 `sudo` 安装与端到端验收）

目标：代理崩了、被退出、虚拟网卡没了的时候，普通程序一个包都出不去，只剩局域网能通；
开机自动生效，被别的程序清掉会自己补回来；一条命令解除。

## 为什么需要 root 中继（这是本方案的地基）

实测（`diagnose.sh` 第 3 节，可复现）：

```
pid=20651 uid=501  Qingzhou-Tunnel       ← 轻舟的 xray 跑在这里
```

隧道扩展和普通程序是**同一个 uid（501）**。macOS 的 pf 只能按 uid / 网段 / 端口匹配，
**没有进程名匹配**。于是：

- 写 `block out all user != root` → 连 xray 自己的出站也被拦，整机断网；
- 写「按检测结果切换规则」→ 检测有窗口，做不到"一条都不漏"。

所以只能让**代理的出站由一个 root 进程代为拨号**：

```
App ──▶ utun ──▶ xray(uid 501) ──▶ 127.0.0.1:10808 (root 中继) ──▶ 外网
                      │
                      └─ 只连回环，pf 放行

代理挂了 / TUN 没了：普通程序的包从 en0 直接出去 ──▶ uid 501 ──▶ pf 丢弃
```

规则加载后由内核 `pf` 静态拦截；`guard-run.sh` 在启用态下以 `<= 1s`（`sleep 1`）轮询 `utun` 与锚点状态：
`utun` 未就绪或重连瞬间自动加载**fail-closed 基础规则**（剥离 `^pass .*__TUN_DEV__` 行，只放行 `lo0` / 局域网 / `root`），
消除启动与重连泄漏窗口。

## 架构与组件

核心中继逻辑位于 SPM 库 **`Sources/QingzhouGuardRelayCore/`**（支持 `swift test` 与 TSan 验证），
`Tools/qingzhou-guard/relay/main.swift` 为薄 CLI 入口（解析参数、校验分离凭据、启动 `RelayServer` 并进入 `dispatchMain()`）。

| 文件 | 作用 |
|---|---|
| `Sources/QingzhouGuardRelayCore/` | 中继核心库：`RelayConfig`、`RelayServer`、`ClientSession`（每会话独立串行 `DispatchQueue`、幂等 `close()`、TCP 半关闭 `SHUT_WR`、16 KiB 握手缓冲上限）、`ControlSession`、`TimeZoneController`、`RelayDNS`、`RelayLogger`、`RelayAuthCredentials` |
| `relay/main.swift` | 薄 CLI 入口：校验端口与分离凭据（缺失/相同则 fail-closed 退出）、启动 `10808` 转发 + `10809` 控制监听 |
| `build-relay.sh` | 编译中继（`Sources/QingzhouGuardRelayCore/*.swift` + `relay/main.swift`，免 `sudo`） |
| `pf/qingzhou-guard.conf` | pf 规则模板（回环 / 轻舟 `utun` / 局域网与 `100.64.0.0/10` / 链路本地与组播 `fe80::/10`, `ff00::/8` / `root` 放行，其余全拒；故意不放行 `fc00::/7`） |
| `guard-run.sh` | 守护脚本：带 `--port` / `--control-port` 启动中继；启用态下无 `utun` 加载 fail-closed 基础规则，`<= 1s` 变更感知轮询，仅在接口变化、锚点为空或 `pf` 关闭时重载 |
| `install.sh` | 安装文件、写入 `port`/`control-port`（默认 `10808`/`10809`）、生成/迁移分离凭据 `relay-auth`（`0600`）、同步包含 `controlPort`/`controlUsername`/`controlPassword` 的 App Group `guard-relay.json`（`0600`、`dscl` 查真实 home）、注册 LaunchDaemon（`bootout` 等待 + `bootstrap` 重试，**不启用拦截**） |
| `enable.sh` | 5 步检查（`1/5`–`5/5`）通过后启用拦截：第 3 步用 Python 结构化校验 `xray-config.json`（含 `tag=="relay"`、`protocol=="socks"`、`127.0.0.1:$PORT` 及 `hop`/`direct` 的 `dialerProxy=="relay"`）并检查 `/var/log/qingzhou-relay.log` 120s 内有写入；第 5 步保存 `pfctl -E` 引用 token 至 `pf-token` |
| `off.sh` | 一条命令解除拦截：删 `enabled` 标记，**仅清空 `com.apple/qingzhou_guard` 锚点**（`pfctl -a com.apple/qingzhou_guard -F all`）并释放轻舟自身 `pf-token`（`pfctl -X "$TOKEN"`），不再调用全局 `pfctl -d`，且不动中继 |
| `uninstall.sh` | 彻底卸载：先解除拦截，第 `2/5` 步校验 `timezone-orig`（`TZif` 魔数且非 `posixrules`）并通过 `/usr/sbin/systemsetup -settimezone` 还原系统时区，再移除 LaunchDaemon、停止中继、删除 `$BASE` 与轮转日志（`/var/log/qingzhou-relay.log`、`.log.1`、`/var/log/qingzhou-guard.log`） |
| `diagnose.sh` | 只读体检（不加 `sudo` 也能跑大半） |

名字固定，急救命令按这两个写：

- pf 锚点：`com.apple/qingzhou_guard`（挂在 `/etc/pf.conf` 已有的 `anchor "com.apple/*"` 下，**不改 pf.conf**）
- LaunchDaemon Label：`com.sbraveyoung.qingzhou.guard`
- 解除脚本：`/Library/Application Support/qingzhou-guard/off.sh`

## 控制端口（`127.0.0.1:10809`）、分离凭据与核心加固

- **分离凭据（fail-closed）**：
  - `/Library/Application Support/qingzhou-guard/relay-auth`（`0600`，root 可读）分两行保存：`forward:<u:p>`（SOCKS5 转发）与 `control:<u:p>`（控制端口）。
  - 对应同步给主 App 的 App Group `guard-relay.json`（`0600`）除 `host`/`port`/`username`/`password` 外，还包含 `controlPort`、`controlUsername`、`controlPassword`。
  - 转发凭据与控制凭据**任一缺失、为空或两者相同**，`QingzhouGuardRelayCore`（`RelayAuthCredentials`）及主 App（`GuardRelayCredentials` / `AppState.sendControlCommand`）均拒绝使用（fail-closed）。
- **TCP 控制协议（`127.0.0.1:10809`）**：
  - 绕开 TCC 对 launchd 进程读取 App Group 容器的限制，主 App 通过回环 TCP 与 root 中继通信；单行按 `\n` 分帧，行上限 **1024 字节**（超限返回 `ERR too-long` 并断开）。
  - 命令集：`AUTH <controlUser> <controlPass>`、`GET-TZ`、`SET-TZ <IANA>`、`RESTORE`。
  - `TimeZoneController` 对 `SET-TZ` 目标时区执行 `/usr/share/zoneinfo/<id>` 存在性与 `TZif` 文件头校验（防路径穿越/注入），首次切换记录原时区至 `timezone-orig`，后续每次 `SET-TZ` 与 **`currentTimeZone()`**（而非 `tzOrigPath`）比对，确保切回原时区也能正确生效；`RESTORE` 与 `uninstall.sh` 均可还原 `timezone-orig`。
- **`RelayDNS` 加固**：
  - 阻塞 `recv()` 下沉至专用 `dnsQueue`，解析完成后切回调用方 `callbackQueue`，避免阻塞网络回调线程；
  - 使用 `connect()` 绑定对端 IP/端口且指定物理接口（`IP_BOUND_IF`）的 UDP socket；
  - 严格校验应答 `TXID`、`QR=1`、`RCODE=0`、`qdcount <= 16`、域名 label `<= 63`（QNAME `<= 255`）；
  - 有界缓存（默认 `maxEntries = 1024`、`ttl = 60s`），写入前先清理过期条目并在满时淘汰最早条目。
- **`RelayLogger` 加固**：
  - 使用 `NSLock` 串行化写入并复用单个 `ISO8601DateFormatter`；
  - 文件权限固定 `0600`，日志超过 **5 MiB**（`5 * 1024 * 1024` 字节）时轮转至 `/var/log/qingzhou-relay.log.1`。

## 安装与启用（顺序不能颠倒）

```sh
# 1) 编译（免 sudo）
sh Tools/qingzhou-guard/build-relay.sh

# 2) 安装（免启用，此时机器网络与之前完全一样）
sudo sh Tools/qingzhou-guard/install.sh

# 3) 自测中继能出网（解析 forward: 行）
U="$(sudo grep '^forward:' "/Library/Application Support/qingzhou-guard/relay-auth" | cut -d: -f2)"
P="$(sudo grep '^forward:' "/Library/Application Support/qingzhou-guard/relay-auth" | cut -d: -f3-)"
curl -sS -o /dev/null -w '%{http_code}\n' --proxy "socks5h://$U:$P@127.0.0.1:10808" https://example.com/

# 4) 在轻舟 App 开启「分流方案」+「经 root 中继出网」并连接 VPN，确认代理能上网后再启用拦截
sudo sh "/Library/Application Support/qingzhou-guard/enable.sh"
```

**代理与中继串联（已实现）**：`SplitExitPlan.swift`、`PacketTunnelProvider+SplitExit.swift` 与设置页「经 root 中继出网」开关已完成集成；开启后链路为 `exit --(dialerProxy)--> hop --(dialerProxy)--> relay` 与 `direct --(dialerProxy)--> relay`。
启用前只需在 App 内确认开启「分流方案」+「经 root 中继出网」并成功建立连接（`enable.sh` 第 3 步会自动校验 `xray-config.json` 与 `/var/log/qingzhou-relay.log` 流量证据）。

## 断网时怎么自救

```sh
sudo sh "/Library/Application Support/qingzhou-guard/off.sh"
```

它只删除 `enabled` 标记、清空 `com.apple/qingzhou_guard` 锚点并释放轻舟自身 `pf-token`，不关闭系统或其它工具的 `pf` 规则，也不杀中继，所以不影响正在跑的 VPN。

## 已知限制与待验项（如实列出）

1. **本地已验证，root 部署与实机 E2E 待验收**：`QingzhouGuardRelayCoreTests`（含 ThreadSanitizer）、`GuardRelayCredentialsTests`、`ControlClientTests` 与脚本自检均已在本地通过；`sudo install.sh` / `enable.sh` / 实机时区切换与 `pf` 实网验收需由用户按 `docs/ACCEPTANCE-CHECKLIST-teamwork.md` 与 `Tools/verify-guard-e2e.sh` 执行。
2. **UDP 转发缺口**：当前中继只处理 TCP（SOCKS5 `CONNECT`），`CMD=3`（`UDP ASSOCIATE`）直接拒绝。分流 + 中继模式下国内 UDP（语音/游戏/部分 QUIC）不通，属已知产品待定项（`UDP ASSOCIATE` vs xray `uot`）。
3. **IPv6 局域网放行边界**：规则里对 `fe80::/10`、`ff00::/8` 放行（局域网/Bonjour 必需），故意**不放行** `fc00::/7`（防止其它 `utun` 的 ULA 网关成为侧信道），启用时仍建议按 `diagnose.sh` 核对本机 `utun` 路由。
4. **`block out quick all` 会拦掉 `_mdnsresponder` 等系统用户的非局域网流量**：局域网（`224.0.0.0/4`、`fe80::/10`、`ff00::/8`）已放行，AirDrop / Bonjour 不受影响；但其它依赖外网的系统服务会被挡。这是"不漏"的代价。
5. **锚点级 `pf` 清理已落地**：`off.sh` 与 `uninstall.sh` 已改为只清空 `com.apple/qingzhou_guard` 并以 `pfctl -X "$TOKEN"` 释放轻舟自身引用，不再执行全局 `pfctl -d`，不会误伤其它依赖 `pf` 的程序。
