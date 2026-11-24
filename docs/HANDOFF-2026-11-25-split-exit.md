# 交接文档 —— 分流方案（split-exit）与断网开关（guard）

写于 2026-11-25 05:15（北京时间）。接手者请先读完"30 秒速览"和"纪律"两节，
其余按需查。**本文只写核实过的事实**，凡是推测都标了"未验证"。

---

## 1. 30 秒速览

**项目**：轻舟（Qingzhou），macOS/iOS 的代理客户端，Swift Package 结构，
自研 NE 隧道扩展 + libXray。仓库 `github.com/qingzhou-app/qingzhou`，
本地工作副本 `/Users/sbraveyoung/code/src/github.com/sbraveyoung/qingzhou-wt/split-exit`。

**本次会话做的事**（2026-11-24 18:30 → 2026-11-25 05:00，28 个 commit）：

1. 完成**分流方案**：国内(geosite:cn + 每日名单)直连、其余走"海外出口"（住宅 SOCKS5），
   出口自身的流量经"跳板"出去。
2. 完成**断网开关**（guard）：root 中继 + pf 锚点，隧道挂了普通程序无出口、局域网仍在。
3. 排查并修掉 6 个真 bug —— 全部由用户真机日志定位，非猜测（见 §4）。
4. 加了一堆诊断与防呆：验收脚本、脚本自检、App 内命令面板。

**现在的状态**：分流 + 断网开关**已跑通并验证**（海外 204、国内 200、中继日志带真实 IP）。
**时区跟随功能代码已完成但未部署**（机器上中继二进制是旧的，见 §6 P0）。

---

## 2. 纪律（很重要，违反会浪费几小时）

| 事项 | 说明 |
|---|---|
| **你不能跑 sudo** | 环境里 `sudo` 直接 `operation not permitted`。所有 root 操作写成脚本，让用户执行，并把命令贴全（绝对路径，用户可能在任意目录粘贴） |
| **你不能 build App** | `xcodebuild` 被沙箱拦。App 构建/安装靠 `sh Tools/install-app.sh`（用户执行）。但 `swift build` / `swift test` / `swiftc` **可以**用 |
| **不能读 TCC 保护路径** | `~/Library/Group Containers/...`、`~/Library/Containers/.../Data` 里读文件会 `Operation not permitted`（`ls -l` 拿 stat 可以，`cat`/`xxd`/python open 不行）。要用户 `sudo cat` 或让程序自己写 |
| **提交前跑脚本自检** | `sh Tools/check-scripts.sh` —— 专抓"`$VAR` 紧跟中文字符"，这类错今晚犯了 4 次，`set -u` 下直接 unbound variable 崩脚本 |
| **验证优先于推断** | 今晚多个误判都是"看起来该对"的假设造成的（见 §7）。任何结论都要有一条命令或一段日志支撑 |

构建/测试基准：

```sh
cd /Users/sbraveyoung/code/src/github.com/sbraveyoung/qingzhou-wt/split-exit
swift build                                    # 包编译（快，几秒）
swift test                                     # 419 tests，1 个 opt-in 跳过，必须全绿
sh Tools/qingzhou-guard/build-relay.sh         # 编译中继二进制到 build/
sh Tools/check-scripts.sh                      # shell 脚本自检
swiftc -typecheck Apps/Tunnel-Shared/PacketTunnelProvider.swift \
  -target arm64-apple-macos14.0 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -I .build/out/Products/Debug -F .build/out/Products/Debug/PackageFrameworks \
  -F .build/out/Products/Debug -swift-version 6    # 扩展不在 SPM 里，必须单独 typecheck
```

---

## 3. 分支状态

- 分支 `feat/split-exit`，HEAD `f782c6ff`，**与远端一致**，工作区干净。
- 基线 `f3925d6`（main，未动）。共 28 个 commit，全部可回溯。
- 没有 PR。合并到 main 前建议先跑一次真机验收（§6）。

关键提交（按时间）：

```
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

## 4. 今晚修掉的 6 个真 bug（每条都有根因和证据）

### 4.1 pf 校验误判 —— 规则加载成功却被判失败
`pfctl -s rules` 会把 `block out quick all` **规范化**成 `block drop out quick all`。
原代码 grep `block out quick all` 永远不匹配 → 判定失败 → 清空锚点退出。
**修**：改成"锚点里有规则 + 含 `block (drop )?out`"；同时**不再吞 pfctl 的 stderr**。
提交 `96326dc2`。

### 4.2 假 IP 死循环 —— 开启中继后整机断网
`direct` 出站带 `sockopt.domainStrategy=ForceIP`：xray 拨号前先把域名解析成 IP，
而解析走自己的 DNS（fakedns）→ 返回假 IP → SOCKS5 CONNECT 带假 IP 交给中继
→ root 从物理网卡拨一个只存在于 TUN 里的地址 → 包绕回 TUN → 再进 xray → 死循环。
证据：中继日志里 `CONNECT 198.19.x.x:443` 刷屏（28 条/秒）。
**修**：经中继时 `direct` 去掉 ForceIP（域名原样交给中继）。提交 `33c5e343`。

### 4.3 中继出站绕回自己的隧道 —— 第二层死循环，最隐蔽
中继是**独立 root 进程**，没有 NE 扩展进程"系统豁免它进自己 TUN"的待遇。
它的拨号走默认路由 = utun6 → 回到 xray → 分流模式下 direct 又经 dialerProxy 交回中继
→ 无限递归（微信 1 秒重连 17 次）。
**修**（两半都必须）：
1. `NWParameters.requiredInterface = 物理网卡`（裸 IP 已能绕开）；
2. **域名必须自解析**：系统解析走 TUN 里的 DNS，海外域名返回 fakedns 假 IP →
   连假 IP 又绕回 TUN。改用自己的 UDP DNS（223.5.5.5 / 119.29.29.29，socket 绑 en0，60s 缓存）。
验证手法：让中继 CONNECT `dns.google:53` 发 DNS TXT 查询 `o-o.myaddr.l.google.com`，
Google 看到的来源 IP = 家宽公网 IP（非 VPN 出口）→ 证明绕开 TUN。
提交 `d6e64c49`。

### 4.4 launchd 竞态 —— 服务静默消失
`install.sh` 里 `launchctl bootout` 是异步的，紧接着 `bootstrap` 会撞车失败，
服务静默消失 → 中继没人拉起 → 凡走中继的流量全死。
**修**：等 `launchctl print` 查不到服务再 bootstrap，失败重试 3 次，最终失败非零退出。
提交 `1ee0581a`。

### 4.5 短用户名 ≠ home 目录名
本机短名 `sbrave`，home 是 `/Users/sbraveyoung`。脚本里 `eval echo ~$TARGET_USER`
展开成不存在的 `/Users/sbrave` → 三个脚本（guard-run / enable / install）路径全错，
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
现在：110202 域名 / 9665 网段，抽样注入 30000 / 8000，UI 显示"实收/源"。
提交 `4a86fc7c`。

---

## 5. 机器当前状态（2026-11-25 05:07 核实）

```
系统时区      Asia/Shanghai（CST +0800）
guard 目录    /Library/Application Support/qingzhou-guard  存在
enabled 标记  存在（pf 拦截处于启用状态）
10808 中继    在听
10809 控制口  未监听 ← 中继二进制是旧版
守护进程      com.sbraveyoung.qingzhou.guard 已加载
中继二进制    与仓库 build/qingzhou-relay 不一致 ← 需要重跑 install.sh
已装 App      CDHash 28f87cdf…，装于 2026-11-24 22:54（早于 TCP 客户端改动）
```

**含义**：分流 + 断网开关有效；**时区跟随尚未部署**（App 侧是旧版、中继侧是旧版）。

---

## 6. 待办

### P0 —— 部署并验证时区跟随（代码已完成，只差部署）

```sh
cd /Users/sbraveyoung/code/src/github.com/sbraveyoung/qingzhou-wt/split-exit
sudo sh Tools/qingzhou-guard/install.sh          # 装新中继（含控制端口）+ 重启守护
sudo launchctl kickstart -k system/com.sbraveyoung.qingzhou.guard
sh Tools/install-app.sh                          # 装带 TCP 客户端的 App
```

然后 App 里重连 VPN，验证：

```sh
nc -z 127.0.0.1 10809 && echo "控制口在听"
tail -20 /var/log/qingzhou-relay.log | grep -E "controller listening|记录原时区|系统时区"
date                                             # 期望 EST（美国出口）
```

**未验证项**（不要当成已完成）：
- 控制端口的 `SET-TZ` 只在**非 root** 环境测过协议层（认证/注入/未知命令都通过），
  `systemsetup` 真正执行需要 root，**尚未在真机上端到端验证过**。
- 断开 VPN 后 `RESTORE` 还原是否生效，未验证。
- 还原依赖 `/Library/Application Support/qingzhou-guard/timezone-orig`（首个 SET-TZ 写入）。

### P1 —— UDP 缺口的决策
中继只做 TCP（SOCKS5 CONNECT），`CMD=3`（UDP ASSOCIATE）直接拒绝。
后果：分流+中继模式下**国内 UDP 应用不通**（游戏联机、语音、部分 QUIC）。
两条路：(a) 中继实现 UDP ASSOCIATE；(b) 用 xray 的 UDP-over-TCP（uot）出站接同一个中继。
先做需求判断，别直接写代码。

### P2 —— 收尾
- `/Library/Application Support/qingzhou-guard/timezone-follow.sh` 是旧方案残留
  （仓库里已删除），`install.sh` 不再覆盖它，只有 `uninstall.sh` 会随目录一起删。
- 未做真机内存实测：`SplitExitListsLimits`（域名 30000 / 关键字 2000 / 网段 8000）
  是按 NE 50 MiB 预算给的保守值。设置页「诊断」有扩展内存读数，可据此调。
- 设置页「断网开关」命令面板的四条命令都可复制，但 install/enable/off/uninstall
  都需 root，无法做成 App 内一键（sudo 密码框不允许预填）。

---

## 7. 踩坑档案（省下几小时的清单）

1. **`curl --noproxy '*'` 会连 `--proxy` 一起绕过。** 今晚因此得出过"中继没生效"的错误结论。
   测中继用裸 SOCKS5（python 手写握手）或去掉 `--noproxy`。
2. **TCC 会拦 launchd 进程读 App Group。** 手动 `sudo` 继承用户授权能读，
   launchd 起的守护进程不能。`guard-run.sh` 在「完全磁盘访问权限」列表里**是灰的、选不了**
   （macOS 不给 shell 脚本授权）。→ 所以 App→root 的通信改成**回环 TCP 控制端口**（网络不受 TCC 限制）。
3. **沙箱 App 的数据不在 `~/Library/Application Support/`。** 在
   `~/Library/Containers/com.sbraveyoung.qingzhou.mac/Data/...`。
   别去读 `~/Library/Application Support/VPN/state.json`（那是 7 月的非沙箱遗留，会误导）。
4. **xray 自己的出站不会绕回 TUN**，因为它在 NE 扩展进程里、系统豁免。**独立进程没有这个豁免。**
   这条是 4.3 的全部根因。
5. **Network.framework 会自己解析 hostname**，`requiredInterface` 管不了"解析出假 IP"这件事。
   要绕开必须自己解析再拨裸 IP。
6. **`ControlSession` 必须被强引用**，否则 `newConnectionHandler` 返回后 ARC 立刻回收，
   receive 回调永不触发（现象：连接建立成功但收不到任何数据）。
7. **iOS/macOS 的 `Data.removeFirst` 后 startIndex 仍是 0**，但切片区间要用当时的索引算，
   别把旧索引套到新缓冲区。
8. **shell 里 `$VAR` 紧跟中文**（`$TS（`）会被当成变量名一部分，`set -u` 下崩、
   `set +u` 下静默变空串。用 `${VAR}`。有自检脚本兜底。
9. **launchd `bootout` 是异步的**，紧接着 `bootstrap` 会失败。要等 `print` 查不到再引导。
10. **pf 规则输出会被规范化**（`block` → `block drop`），别按原文案 grep。
11. **`systemsetup` 需要 root**；时区合法性校验看 `/usr/share/zoneinfo/<id>` 是否存在
    （同时挡住 `../` 注入）。

---

## 8. 文件地图

```
Tools/install-app.sh                  App 构建→备份→替换→验收→失败自动回滚（用户执行）
Tools/check-scripts.sh                shell 自检（$VAR 紧跟中文）
Tools/qingzhou-guard/
    install.sh                        装中继+plist+脚本；同步凭据给 App；bootstrap 带重试
    enable.sh                         开拦截（5 步，含两道前置证据检查）
    off.sh / uninstall.sh             急停 / 彻底卸载
    diagnose.sh                       只读体检（状态、路由、uid、pf）
    guard-run.sh                      root 守护：起中继 + 每 10s 补 pf 规则
    qingzhou-guard.conf               pf 规则模板（__TUN_DEV__ 占位）
    relay/main.swift                  ★ root 中继（SOCKS5 转发 + 控制端口 + 自解析 + 绑物理口）
    README.md                         组件的设计说明
Sources/XrayConfig/
    SplitExitPlan.swift               ★ 分流配置生成（出站链 exit→hop→relay、路由、DNS）
    XrayConfigComposer.swift          普通模式配置生成
Sources/QingzhouApp/
    SettingsView.swift                设置页（分流方案 / 断网开关命令面板 / 跟随出口地区）
    AppState.swift                    requestSystemTimeZone 等（TCP 控制客户端在这）
    SplitExitListsUpdater.swift       每日名单拉取/解析/抽样
    SplitExitListsView.swift          名单查看器
Sources/QingzhouCore/
    ExitRegionProfile.swift           出口地区画像（时区/语言映射/系统命令）
    GuardRelayCredentials.swift       中继凭据（含 controlPort = 10809）
    SplitExitLists.swift              名单模型 + 解析 + 抽样 + 上限
docs/SPLIT-EXIT.md                    分流方案文档（格式与抽样说明已更新）
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

**急停**：`sudo sh "/Library/Application Support/qingzhou-guard/off.sh"`（停拦截、不杀中继、VPN 不断）。

---

## 10. 给接手者的第一条命令

```sh
cd /Users/sbraveyoung/code/src/github.com/sbraveyoung/qingzhou-wt/split-exit
git log --oneline f3925d6..HEAD | head -30
swift test 2>&1 | tail -3
sh Tools/check-scripts.sh
```

三件事确认基线没坏（测试全绿、脚本自检干净、28 个提交都在），再动 P0。

**最后一句**：这个项目今晚吃过的亏，基本都是"看起来该对、实际静默错"的环境假设
（`~user`、TCC、pf 规范化、`--noproxy`、ARC、`$VAR` 中文）。
改动前先问一句"这条路径在真机上真的会被走到吗"，能省很多轮。
