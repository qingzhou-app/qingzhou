# 交接文档 —— 分流方案（split-exit）与断网开关（guard）

初版写于 2026-11-25 05:15（北京时间），并已在 `master/teamwork`（M1–M5）同步合并与加固状态。接手者请先读完"30 秒速览"和"纪律"两节，
其余按需查。**本文只写核实过的事实**，凡未实机/特权环境验证的项目均已明确标出并收敛至 `docs/ACCEPTANCE-CHECKLIST-teamwork.md`。

---

## 1. 30 秒速览

**项目**：轻舟（Qingzhou），macOS/iOS 的代理客户端，Swift Package 结构，
自研 NE 隧道扩展 + libXray。仓库 `github.com/qingzhou-app/qingzhou`，
工作区 `<repo-root>`（当前集成分支 `master/teamwork`）。

**演进历程**：
- `feat/split-exit`（基于 `main` `f3925d6d`，共 29 个 commit 至 `c6a908e1`）完成了**分流方案**、**断网开关**（guard）、6 个真机根因级 bug 修复（见 §4）与时区控制端口原型。
- `master/teamwork` 从 `baseline/2026-11-24-build38`（`74fe8841`，含 build 38 双栈 FakeDNS 与域名流量账本）出发，通过 `8f104bbd` 合并 `feat/split-exit`（`c6a908e1`），并先后完成：
  - **M1（`e0ee9ea5`）**：提取 `Sources/QingzhouGuardRelayCore/`、修复 `SET-TZ` vs `currentTimeZone()` / `uninstall.sh` 时区还原 / `AppState.sendControlCommand` / 会话并发安全 / `RelayDNS` 阻塞 `recv()` 与有界缓存 / `RelayLogger` 5 MiB 轮转 / `forward:` 与 `control:` 凭据分离 / `guard-run.sh` fail-closed 1s 轮询 / `off.sh` 锚点级清理 / `enable.sh` 结构化 JSON 校验。
  - **M2（`8c3b6168`）**：macOS 专属 UI（`SettingsSplitExitSection` / `SettingsGuardSection` 等）用 `#if os(macOS)` 隔离、4 语 `*.xcstrings` 补全与 `LocalizedStringKey` 修复、`PacketTunnelProvider+SplitExit` 透传 `self.blockQUIC` 与清理冗余 `.prefix`、`Rule.noResolve` 语义分离及 `PROCESS-NAME` / `USER-AGENT` 显式诊断。
  - **M3（`6af9d359`）**：`Sources/QingzhouCore/Resources/geosite-cn.txt` + `GeoSiteCNMatcher` 前置去重、通用 `SplitExitPolicyGroup` 替代硬编码站点规则、拆分 `AppState.swift` / `PacketTunnelProvider.swift` / `SettingsView.swift` 并通过 `xcodegen generate` 对齐工程。
  - **M4（`48cf4ef8`）**：仓库路径脱敏、文档同步、自动化脚本（`Tools/verify-local.sh`、`Tools/verify-guard-e2e.sh`）与验收清单（`docs/ACCEPTANCE-CHECKLIST-teamwork.md`）。
  - **M5（`21a84c1c` + Tier 5 加固）**：新增 65 项黑盒端到端测试套件（`Tests/QingzhouE2ETests/`），并完成 Tier 5 对抗探针加固（`ClientSession`/`ControlSession` 半关闭 drain、`startTunnel` 无 `currentNodeId` 分流启动、`effBlockQUIC` 与 `testNode`/`performTest` 负载校验、`setGuardRelayEnabled` 重连联动与 `performReapply` 缺失凭据 fail-closed 防护、凭据空白/换行校验、分流名单等量刷新内容比对与 `enable.sh` 启动竞态修复）。

**现在的状态**：代码加固、跨平台隔离、本地单测 / TSan 与无签名 Xcode 构建（iOS Simulator & macOS）已通过；
目标机 `sudo` 安装 / 实机时区与 `pf` E2E、真机签名构建与 50 MiB NE 内存实测列入 [docs/ACCEPTANCE-CHECKLIST-teamwork.md](ACCEPTANCE-CHECKLIST-teamwork.md)。

---

## 2. 纪律（很重要，违反会浪费几小时）

| 事项 | 说明 |
|---|---|
| **不能擅自跑 sudo / 改 VPN** | 自动化流程不执行 `sudo`（root 安装/时区/pf）也不断开或切换用户运行中的 VPN。所有 root 验收集中在 `Tools/verify-guard-e2e.sh` 与 `docs/ACCEPTANCE-CHECKLIST-teamwork.md`，由用户确认后执行 |
| **沙箱与构建边界** | `swift test` 在普通终端可跑全套 11 个 target；`xcodebuild` 真机签名需用户本机环境与签名证书，本地无签名编译用 `Tools/verify-local.sh`（`CODE_SIGNING_ALLOWED=NO`） |
| **不能读 TCC 保护路径** | `~/Library/Group Containers/...`、`~/Library/Containers/.../Data` 在非授权终端读文件可能报 `Operation not permitted`（`ls -l` 拿 stat 可以，`cat`/`xxd`/python open 不行） |
| **提交前跑脚本自检** | `sh Tools/check-scripts.sh` —— 专抓"`$VAR` 紧跟非 ASCII 字符"，这类错在 `set -u` 下直接 unbound variable 崩脚本 |
| **验证优先于推断** | 多个历史误判都是"看起来该对"的假设造成的（见 §7）。任何结论都要有一条命令或一段日志支撑 |

构建/测试基准（`master/teamwork` M5 实测）：

```sh
cd <repo-root>
sh Tools/verify-local.sh                         # 一键跑完下方本地非 root 检查（或加 --skip-xcodebuild）
swift test                                       # 1,292 tests executed，2 个环境条件跳过，0 失败（覆盖 11 个 target）
sh Tools/qingzhou-guard/build-relay.sh           # 编译中继二进制到 Tools/qingzhou-guard/build/
sh Tools/check-scripts.sh                        # shell 脚本自检
python3 scripts/extract-geosite-cn.py --check    # 校验 geosite-cn.txt 与 geosite.dat 一致（domain=5675, full=40, regexp=3）
```

---

## 3. 分支与提交历史

- 当前集成分支：`master/teamwork`
  - 起点：`baseline/2026-11-24-build38`（`74fe8841`，在 `main` `f3925d6d` 之上含 `8bbe74c9` + `74fe8841`）
  - 合并来源：`feat/split-exit`（`c6a908e1`，在 `main` `f3925d6d` 之上共 29 个 commit）
  - 合并提交：`8f104bbd`（`git merge --no-ff feat/split-exit`，0 冲突）
  - 后续里程碑提交：`e0ee9ea5`（M1 P0 加固）、`8c3b6168`（M2 P1 隔离/本地化/规则/Tunnel）、`6af9d359`（M3 P2 去重/通用策略组/核心文件拆分）、`48cf4ef8`（M4 文档与验收脚本）、`21a84c1c` + Tier 5 加固（M5 E2E 套件与对抗探针加固）
- 本地构建与测试实况（M5 实测）：
  - `swift test`：`1,292` 项执行（覆盖 `11` 个 SPM target），`2` 项环境门控跳过，`0` 项失败（含 `QingzhouGuardRelayCoreTests` 24 项与 TSan 验证、`QingzhouE2ETests` 65 项）；
  - `xcodebuild`（`CODE_SIGNING_ALLOWED=NO`）：`Qingzhou-iOS`（iOS Simulator）与 `Qingzhou-macOS` 均 `** BUILD SUCCEEDED **`；
  - `xcstringstool compile`：20/20 `OK`；`extract-geosite-cn.py --check`：退出码 `0`。

`feat/split-exit` 关键基础提交（合并前历史）：

```
c6a908e1  docs: 交接文档（分流方案 + 断网开关 + 6 个根因级 bug 与踩坑档案）
f782c6ff  中继控制端口：App 经 TCP 让 root 改系统时区（绕开 TCC）
881d5a92  短用户名≠home 目录名（dscl 修三处）
6bdd32dd  跟随出口地区改全局系统时区（guard root 自动切）
5e3586c9  设置页「断网开关」命令面板（状态 + 一键复制）
d6e64c49  中继出站完整绕开 TUN（自解析 + 绑物理口）★根因级修复
1ee0581a  install.sh bootout→bootstrap 竞态
33c5e343  经中继时 direct 不得 ForceIP（假 IP 死循环）★根因级修复
c444e187  enable.sh 两道前置检查（配置含 relay + 中继有流量）
96326dc2  pf 校验误判（block drop）+ 名单入口
086dcd07  代理出站真正串到 root 中继
83f7270c  名单可查看 + 远程规则翻页
4a86fc7c  Loyalsoldier 名单是 rule-provider 格式
d9fcc303  SOCKS5 四段式 host:port:user:pass
21fc2180 / 326e3e03 / 25fd358f / bbeeeadc / 192473d1   分流与 guard 主体
```

---

## 4. `feat/split-exit` 修掉的 6 个真 bug（每条都有根因和证据）

### 4.1 pf 校验误判 —— 规则加载成功却被判失败
`pfctl -s rules` 会把 `block out quick all` **规范化**成 `block drop out quick all`。
原代码 grep `block out quick all` 永远不匹配 → 判定失败 → 清空锚点退出。
**修**：改成"锚点里有规则 + 含 `block (drop )?out`"；同时**不再吞 pfctl 的 stderr**。
提交 `96326dc2`（M1 已进一步将 `off.sh` 改为仅清锚点 + `pfctl -X "$TOKEN"`）。

### 4.2 假 IP 死循环 —— 开启中继后整机断网
`direct` 出站带 `sockopt.domainStrategy=ForceIP`：xray 拨号前先把域名解析成 IP，
而解析走自己的 DNS（fakedns）→ 返回假 IP → SOCKS5 CONNECT 带假 IP 交给中继
→ root 从物理网卡拨一个只存在于 TUN 里的地址 → 包绕回 TUN → 再进 xray → 死循环。
证据：中继日志里 `CONNECT 198.19.x.x:443` 刷屏（28 条/秒）。
**修**：经中继时 `direct` 去掉 ForceIP（域名原样交给中继）。提交 `33c5e343`。

### 4.3 中继出站绕回自己的隧道 —— 第二层死循环，最隐蔽
中继是**独立 root 进程**，没有 NE 扩展进程"系统豁免它进自己 TUN"的待遇。
它的拨号走默认路由 = utun → 回到 xray → 分流模式下 direct 又经 dialerProxy 交回中继
→ 无限递归（微信 1 秒重连 17 次）。
**修**（两半都必须）：
1. `NWParameters.requiredInterface = 物理网卡`（裸 IP 已能绕开）；
2. **域名必须自解析**：系统解析走 TUN 里的 DNS，海外域名返回 fakedns 假 IP →
   连假 IP 又绕回 TUN。改用自己的 UDP DNS（223.5.5.5 / 119.29.29.29，socket 绑 en0，60s 缓存）。
验证手法：让中继 CONNECT `dns.google:53` 发 DNS TXT 查询 `o-o.myaddr.l.google.com`，
Google 看到的来源 IP = 家宽公网 IP（非 VPN 出口）→ 证明绕开 TUN。
提交 `d6e64c49`（M1 已进一步将 `RelayDNS` 阻塞 `recv()` 下沉至独立 `dnsQueue`、使用 connected UDP socket、校验 TXID/QR/RCODE/label `<=63` 并加上界缓存 `maxEntries=1024`）。

### 4.4 launchd 竞态 —— 服务静默消失
`install.sh` 里 `launchctl bootout` 是异步的，紧接着 `bootstrap` 会撞车失败，
服务静默消失 → 中继没人拉起 → 凡走中继的流量全死。
**修**：等 `launchctl print` 查不到服务再 bootstrap，失败重试 3 次，最终失败非零退出。
提交 `1ee0581a`。

### 4.5 短用户名 ≠ home 目录名
开发机实测曾遇短名 `<short-user>`、home 目录为 `/Users/<home-dir>` 的情况。脚本里 `eval echo ~$TARGET_USER`
展开成不存在的 `/Users/<short-user>` → 三个脚本（guard-run / enable / install）路径全错，
**且静默跳过**（`[ -f ]` 判假）。
**修**：用 `dscl . -read /Users/<短名> NFSHomeDirectory` 查真实 home。
提交 `881d5a92`。

### 4.6 名单解析全废 —— 设置页显示"解析结果为空"
Loyalsoldier 的 release 分支是 Clash **rule-provider** 格式（`payload:` + `- '+.domain'`），
不是 `DOMAIN-SUFFIX,x`。而且 109688/110202 条带 `+.` 前缀（含子域语义），
只剥 `*.` 导致 11 万条只剩 562 条。
**修**：支持 payload 格式、剥 `+.`/`*.`、单标签后缀（`+.app`）归域名而非关键字
（关键字是子串匹配，`app` 会命中 happy/apple）。
超限截断从"取前 N 条"改为**等距抽样**（源名单按字母序，取前缀等于只保留 a–c）。
M3（`6af9d359`）已在此基础上新增 **`GeoSiteCNMatcher` 前置去重**（`geosite-cn.txt` 5,718 条），先剔除已被 `geosite:cn` 覆盖的域名再按 `30,000 / 2,000 / 8,000` 抽样。
提交 `4a86fc7c` / `6af9d359`。

---

## 5. 历史预合并宿主机快照（2026-11-25 05:07，`feat/split-exit` 原生状态，仅供对照）

> ⚠️ 本节记录的是 **M1–M4 合并前** 宿主机上的瞬时快照（当时尚未运行 M1 新版 `install.sh`）。目标机在重装前仍可能处于旧二进制状态，请以 `sudo sh Tools/verify-guard-e2e.sh --yes-i-know` 或 `diagnose.sh` 实查为准。

```
系统时区      Asia/Shanghai（CST +0800）
guard 目录    /Library/Application Support/qingzhou-guard  存在（预合并旧版）
enabled 标记  存在（pf 拦截处于启用状态）
10808 中继    在听（旧版单凭据二进制）
10809 控制口  未监听 ← 旧版二进制不含 M1 加固与新控制协议
守护进程      com.sbraveyoung.qingzhou.guard 已加载
```

---

## 6. M1–M3 已完成加固与剩余待办

### P0 —— 时区跟随、凭据分离与 `pf` 加固（代码与本地单测已完成；待目标机 `sudo` 部署与 E2E）

M1（`e0ee9ea5`）已完成全部代码侧 P0 修复并通过 `QingzhouGuardRelayCoreTests`（含 TSan）、`GuardRelayCredentialsTests`、`ControlClientTests`：
- `TimeZoneController` 将 `SET-TZ` 目标时区与 `currentTimeZone()` 比对（而非 `tzOrigPath`），切回原时区可正常生效；`uninstall.sh` 第 `2/5` 步先校验并还原 `timezone-orig` 再删除 `$BASE`。
- `ClientSession` 与 `ControlSession` 改用每会话独立串行 `DispatchQueue` 与幂等 `close()`；`ControlSession` 增加 1024 字节行上限（`ERR too-long`）。
- `RelayDNS` 下沉阻塞 `recv()` 至 `dnsQueue`、使用 connected UDP socket、校验 TXID/QR/RCODE/`qdcount<=16`/label `<=63`、加上界缓存（`maxEntries=1024`）。
- `RelayLogger` 用 `NSLock` + 复用单一 `ISO8601DateFormatter` + `0600` 权限 + 5 MiB 轮转（`.log.1`）。
- 转发凭据（`forward:`）与控制凭据（`control:`）在 `relay-auth`、`guard-relay.json`、`GuardRelayCredentials`、`RelayAuthCredentials` 严格分离。
- `AppState+ExitRegion.sendControlCommand` 移除死代码 `_ = request`，增加 `SO_SNDTIMEO`，严格要求单行响应 `OK`。
- `guard-run.sh` 在无 `utun` 启动/重连窗口加载 fail-closed 基础规则并 `<= 1s` 轮询；`off.sh` 仅清 `com.apple/qingzhou_guard` 锚点并释放自身 `pf-token`；`enable.sh` 修复 `2/4 -> 2/5` 编号并用 Python 结构化校验 `xray-config.json`。

目标机部署与实机验收命令（需用户 `sudo` 确认，详见 `docs/ACCEPTANCE-CHECKLIST-teamwork.md`）：

```sh
cd <repo-root>
sudo sh Tools/verify-guard-e2e.sh --yes-i-know
# 或分步部署：
sh Tools/qingzhou-guard/build-relay.sh
sudo sh Tools/qingzhou-guard/install.sh
```

**仍需目标机 E2E 验证项**：
- `root` 下运行 `systemsetup -settimezone` 的真实 `SET-TZ` → 切回原时区 → `RESTORE` 与 `uninstall.sh` 还原；
- 真实 VPN 连接/断开/重连时 `guard-run.sh` 的 `<= 1s` `utun` 切换与断网不漏规则、`off.sh` 不误伤其它 `pf` 状态。

### P1 —— 跨平台隔离、本地化、Tunnel/规则修复与 UDP 缺口
- **已完成（M2 `8c3b6168`）**：
  - macOS 专属 `SettingsSplitExitSection` / `SettingsGuardSection` / `guard*` 等已全部用 `#if os(macOS)` 隔离；
  - 4 语 `*.xcstrings`（`zh-Hans` / `en` / `ja` / `zh-Hant`）补全与 `LocalizedStringKey` 修复（`xcstringstool compile` 20/20 `OK`）；
  - `PacketTunnelProvider+SplitExit.composeSplitExit` 已传入 `blockQUIC: self.blockQUIC`，移除冗余 `.prefix`；
  - `Rule.noResolve` 独立解析、保留 `,no-resolve`，`RoutingRuleConverter` 对 `PROCESS-NAME` / `USER-AGENT` / `no-resolve` 输出显式诊断（`ConversionReport`）与 UI 徽标。
- **未决产品决策（UDP `CMD=3` 缺口）**：
  中继只做 TCP（SOCKS5 `CONNECT`），`CMD=3`（`UDP ASSOCIATE`）直接拒绝。
  后果：分流+中继模式下**国内 UDP 应用不通**（游戏联机、语音、部分 QUIC）。
  两条路：(a) 中继实现 `UDP ASSOCIATE`；(b) 用 xray 的 UDP-over-TCP（`uot`）出站接同一个中继。先做需求判断，再写代码。

### P2 —— 优化、重构与真机 50 MiB 实测
- **已完成（M3 `6af9d359`）**：
  - `GeoSiteCNMatcher` + `geosite-cn.txt` 前置去重（及 `GeoSiteCNParityTests` 与 `geosite.dat` 一致性测试）；
  - 通用 `SplitExitPolicyGroup` 替代硬编码站点规则；
  - `AppState.swift`、`PacketTunnelProvider.swift`、`SettingsView.swift` 拆分为聚焦扩展与子视图，并更新 `Apps/project.yml`。
- **仍待真机实测**：
  - `SplitExitListsLimits`（域名 `30,000` / 关键字 `2,000` / 网段 `8,000`，经 `geosite:cn` 去重后）尚未做真机 50 MiB NE jetsam `phys_footprint` 实测。可在设置页「诊断」观察扩展内存读数，见 `docs/ACCEPTANCE-CHECKLIST-teamwork.md`。
  - 设置页「断网开关」命令面板的四条命令都可复制，但 `install`/`enable`/`off`/`uninstall` 均需 `root`，保留终端粘贴执行。

---

## 7. 踩坑档案（省下几小时的清单）

1. **`curl --noproxy '*'` 会连 `--proxy` 一起绕过。** 曾因此得出"中继没生效"的错误结论。
   测中继用裸 SOCKS5（python 手写握手）或去掉 `--noproxy`。
2. **TCC 会拦 launchd 进程读 App Group。** 手动 `sudo` 继承用户授权能读，
   launchd 起的守护进程不能。`guard-run.sh` 在「完全磁盘访问权限」列表里**是灰的、选不了**
   （macOS 不给 shell 脚本授权）。→ 所以 App→root 的通信改成**回环 TCP 控制端口 `10809`**（网络不受 TCC 限制）。
3. **沙箱 App 的数据不在 `~/Library/Application Support/`。** 在
   `~/Library/Containers/com.sbraveyoung.qingzhou.mac/Data/...`。
   别去读 `~/Library/Application Support/VPN/state.json`（那是早期非沙箱遗留，会误导）。
4. **xray 自己的出站不会绕回 TUN**，因为它在 NE 扩展进程里、系统豁免。**独立进程没有这个豁免。**
   这条是 4.3 的全部根因。
5. **Network.framework 会自己解析 hostname**，`requiredInterface` 管不了"解析出假 IP"这件事。
   要绕开必须自己解析再拨裸 IP。
6. **`ControlSession` 必须被强引用**，否则 `newConnectionHandler` 返回后 ARC 立刻回收，
   receive 回调永不触发（现象：连接建立成功但收不到任何数据）。
7. **iOS/macOS 的 `Data.removeFirst` 后 startIndex 仍是 0**，但切片区间要用当时的索引算，
   别把旧索引套到新缓冲区。
8. **shell 里 `$VAR` 紧跟中文**（`$TS（`）会被当成变量名一部分，`set -u` 下崩、
   `set +u` 下静默变空串。用 `${VAR}`。有 `Tools/check-scripts.sh` 兜底。
9. **launchd `bootout` 是异步的**，紧接着 `bootstrap` 会失败。要等 `print` 查不到再引导。
10. **pf 规则输出会被规范化**（`block` → `block drop`），别按原文案 grep。
11. **`systemsetup` 需要 root**；时区合法性校验看 `/usr/share/zoneinfo/<id>` 是否存在且头 4 字节为 `TZif`
    （同时挡住 `../` 与 `posixrules` 注入）。

---

## 8. 文件地图（M1–M5 更新后）

```
Tools/
  verify-local.sh                       非 root 本地一键验证脚本（支持 --skip-xcodebuild）
  verify-guard-e2e.sh                   需 sudo + 显式确认的断网开关端到端验收脚本
  install-app.sh                        App 构建→备份→替换→验收→失败自动回滚（用户执行）
  check-scripts.sh                      shell 自检（$VAR 紧跟非 ASCII）
  qingzhou-guard/
    build-relay.sh                      编译 Sources/QingzhouGuardRelayCore/*.swift + relay/main.swift
    install.sh                          装中继+plist+脚本；生成分离 forward:/control: 凭据；bootstrap 重试
    enable.sh                           开拦截（5 步，Python 结构化校验 xray-config.json + 日志流量）
    off.sh / uninstall.sh               锚点级急停（pfctl -X） / 时区还原与彻底卸载
    diagnose.sh                         只读体检（状态、路由、uid、pf）
    guard-run.sh                        root 守护：fail-closed 无 utun 基础规则 + <=1s 轮询
    pf/qingzhou-guard.conf              pf 规则模板（__TUN_DEV__ 占位，故意不放行 fc00::/7）
    relay/main.swift                    中继薄 CLI 入口
    README.md                           组件设计说明
Sources/QingzhouGuardRelayCore/
  RelayConfig.swift / RelayServer.swift / ClientSession.swift / ControlSession.swift
  RelayDNS.swift / RelayLogger.swift / RelayAuthCredentials.swift / TimeZoneController.swift
Sources/XrayConfig/
  SplitExitPlan.swift                   ★ 分流配置生成（exit→hop→relay、direct→relay、SplitExitPolicyGroup、UseIPv4）
  XrayConfigComposer.swift              普通模式配置生成（build 38 双栈 FakeDNS + UseIP + ForceIP/happyEyeballs）
  RoutingRuleConverter.swift            规则转换与 PROCESS-NAME/USER-AGENT/no-resolve 诊断
Sources/QingzhouApp/
  AppState.swift + AppState+{AccessLog,AutoSelect,ExitRegion,Failover,Rules,Schedulers,SplitExit,Subscriptions,TrafficStats,Tunnel}.swift
  SettingsView.swift + Settings/Settings{AutoSelect,Cloud,Diagnostics,GeoAndRules,Guard,Region,SplitExit}Section.swift
  SplitExitListsUpdater.swift           每日名单拉取/geosite:cn 前置去重/等距抽样
  SplitExitListsView.swift              名单查看器
Sources/QingzhouCore/
  ExitRegionProfile.swift               出口地区画像（时区/语言映射/系统命令）
  GuardRelayCredentials.swift           中继凭据（分离转发与 controlPort = 10809 控制凭据）
  SplitExitLists.swift                  名单模型 + 解析 + 等距抽样 + 上限（30000/2000/8000）
  SplitExitPolicyGroup.swift            通用自定义分流策略组模型
  GeoSiteCNMatcher.swift + Resources/geosite-cn.txt   主 App 轻量化 geosite:cn 匹配器
Apps/Tunnel-Shared/
  PacketTunnelProvider.swift + PacketTunnelProvider+{Bridge,Control,Probing,SplitExit,Stats}.swift
Tests/
  QingzhouGuardRelayCoreTests/          Relay/Control/DNS/Auth/Drain/TSan 回归测试（24 项）
  QingzhouE2ETests/                     ★ 4 层黑盒本地 E2E 测试套件（65 项，覆盖 F1–F5 与平台隔离）
scripts/
  extract-geosite-cn.py                 从 geosite.dat 提取/校验 Sources/QingzhouCore/Resources/geosite-cn.txt
docs/
  SPLIT-EXIT.md                         分流方案文档
  ACCEPTANCE-CHECKLIST-teamwork.md      真机/特权/ASC 验收与 git push 操作清单
```

---

## 9. 各层怎么验（照着做就能定位到层）

| 层 | 命令 | 期望 |
|---|---|---|
| 中继活着 | `nc -z 127.0.0.1 10808` | 在听 |
| 中继走物理口 | `sudo tail -20 /var/log/qingzhou-relay.log` | `CONNECT 域名:443 → 真实IP`，无 198.19.x.x（fakedns 段） |
| 控制口 | `nc -z 127.0.0.1 10809` | 在听 |
| 分流生效 | `curl -s -o /dev/null -w '%{http_code}\n' https://www.gstatic.com/generate_204` | 204 |
| 出口是住宅 | `curl -s https://api.ipify.org` | 住宅 IP，不是节点 IP |
| pf 已拦 | 退出 App 后再 curl | 超时；同时 `ping 192.168.124.1` 通 |
| pf 状态 | `sudo pfctl -s rules -a com.apple/qingzhou_guard` | 有 block 规则（不是空） |

**急停**：`sudo sh "/Library/Application Support/qingzhou-guard/off.sh"`（停拦截、仅清轻舟锚点、不杀中继、VPN 不断）。

---

## 10. 给接手者的第一条命令

```sh
cd <repo-root>
git log --oneline baseline/2026-11-24-build38..HEAD
sh Tools/verify-local.sh
```

确认本地基线全绿后，再按 [docs/ACCEPTANCE-CHECKLIST-teamwork.md](ACCEPTANCE-CHECKLIST-teamwork.md) 推进真机 / `sudo` / App Store Connect 验收与远端推送。

**最后一句**：这个项目吃过的亏，基本都是"看起来该对、实际静默错"的环境假设
（`~user`、TCC、pf 规范化、`--noproxy`、ARC、`$VAR` 中文、同线程阻塞 `recv()`）。
改动前先问一句"这条路径在真机上真的会被走到吗"，能省很多轮。
