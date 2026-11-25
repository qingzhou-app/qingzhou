# 分流方案：国内直连、其余全走海外出口、断了也不漏

本文对应 `Sources/XrayConfig/SplitExitPlan.swift`。核心分流骨架（国内直连、海外走手选静态住宅 `exit` 且永不回落直连）是固定的，同时支持按顺序评估的通用自定义策略组 **`SplitExitPolicyGroup`**；实现状态和待验收项写在最后一节，别把「代码已完成」当成「真机终验已通过」。

## 出口形状

```
App → TUN → xray
              ├─ exit（静态住宅 SOCKS5）──dialerProxy──→ hop（跳板节点）[──dialerProxy──→ relay(root)] → 住宅入口
              ├─ direct（freedom）[──dialerProxy──→ relay(root)]
              └─ reject（blackhole）
```

- `exit` 是**唯一**的海外出口，协议是 `socks`，不可能落成 `freedom`。所以「海外出口组里没有 DIRECT」是结构性的，不靠某条规则写对。
- `hop` 只作为 `streamSettings.sockopt.dialerProxy` 的引用存在，**不作为任何路由规则的 outboundTag**。跳板坏了，海外整体不通，不会退化成直连。
- 没有 url-test、没有 fallback、没有自动换节点：出口是手选的，挂了就是断。
- 住宅代理自身地址也经跳板（`dialerProxy` 覆盖该出站的所有连接），否则国内连不上住宅入口，而且会把本机真实 IP 暴露给住宅服务商。
- 开启「经 root 中继出网」（`relay != nil`）时，`hop` 与 `direct` 都会挂载 `dialerProxy: "relay"`（`127.0.0.1:10808`），链路为 `exit → hop → relay` 与 `direct → relay`，满足 `pf` 只放行 `root` 出站时不切断代理与国内直连。

## 规则顺序（first-match，上→下即优先级）

`SplitExitPlan.routing()` 生成的实际规则顺序（`domainStrategy: "AsIs"`）：

| # | 匹配 | 出口 | 为什么在这个位置 |
|---|---|---|---|
| 0 | `inboundTag: ["dns-module"]` 且目标是 `domesticResolvers` IP | `direct` | 用出口去查国内 DNS 会拿到境外边缘 IP |
| 1 | `inboundTag: ["dns-module"]`（其余，即海外 DoH） | `exit` | 海外域名必须由海外 DNS 经海外出口解析 |
| 2 | `inboundTag: ["tun-in"]`, `port: 53`, `network: "tcp,udp"` | `dns-out` | fake-ip 在这里分配假地址 |
| 3 | `network: "udp"`, `port: 443`（受 `blockQUIC` 控制） | `reject` | `PacketTunnelProvider+SplitExit.swift` 已透传 `self.blockQUIC`；经 SOCKS5 出口的 QUIC 基本不通，默认强制回退 TCP |
| 4 | 用户启用的 `policyGroups`（`SplitExitPolicyGroup`，按配置顺序） | `.exit` / `.direct` / `.reject` | 替代旧版硬编码站点规则；按 `fullDomains` / `domains` / `keywords` / `geoSites`（白名单校验） / `cidrs` 评估，其中 `.exit` 遵守 `rejectOverseasUDP`（TCP 走 `exit`，UDP 走 `reject`） |
| 5 | 局域网与保留地址 `reservedCIDRs`（含 `100.64.0.0/10`） | `direct` | 内网、CGNAT/Tailscale 与保留网段固定直连 |
| 6 | `geosite:geolocation-!cn`（`tcp` → `exit`，`udp` → `reject`） | `exit` / `reject` | **必须排在国内名单之前**；出口无可用 UDP 时明确拒绝，不回退直连 |
| 7 | `geosite:cn` + 注入的国内域名/关键字；`geoip:cn` + 注入的国内 IP 段 | `direct` | `domainStrategy: AsIs` 保证不为 IP 匹配做本地 DNS 解析 |
| 8 | 兜底 `network: "tcp"` → `exit`，`network: "udp"` → `reject`（或当 `rejectOverseasUDP == false` 时 `exit`） | `exit` / `reject` | 其余未命中域名/IP 全部走海外出口；默认关闭海外 UDP |

> **为什么 `#6 geosite:geolocation-!cn` 必须排在 `#7` 国内名单之前**：Loyalsoldier 的国内域名名单里混着 `googletagmanager` / `doubleclick` 等海外公司的域名，如果国内名单先匹配，海外站点的统计/静态资源请求就会用国内 IP 出去。
>
> 特定站点（如需要固定走出口或固定直连的域名/关键字/geosite/CIDR）均通过 `#4` 的通用 **`SplitExitPolicyGroup`** 配置，代码中不再硬编码任何个人站点规则。

## DNS（刻意与普通模式双栈区分）

- **`SplitExitPlan` 保持 `queryStrategy: "UseIPv4"` + 单一 IPv4 FakeDNS 池（`198.18.0.0/15`）**：
  与普通模式 `XrayConfigComposer`（build 38 引入双栈 `UseIP` + `198.18.0.0/15` + `fc00::/18` + `ForceIP` + `happyEyeballs`）刻意区分，原因如下：
  1. 启用 root 中继（`relay != nil`）时，`direct` 出站**必须去掉 `ForceIP` 和 `happyEyeballs`**（`settings.domainStrategy: "AsIs"`），把原始域名交给 `127.0.0.1:10808` 的 `qingzhou-relay`；后者 `RelayDNS` 仅解析 IPv4 `A` 记录。若在 `direct` 开 `ForceIP`，xray 会先拿到 FakeDNS 假 IP 再交给中继拨号，导致从物理网卡拨向仅存在于 TUN 内的假地址，形成死循环。
  2. 静态住宅 SOCKS5 `exit` 普遍没有 IPv6 且拒绝 UDP（`rejectOverseasUDP = true`），若 `SplitExitPlan` 改用 `UseIP` 返回 `AAAA` 记录，会在没有 Happy Eyeballs 回退的 SOCKS5/中继链路上导致连接卡死。
  3. 当 `relay != nil` 时，国内 DNS 解析器自动改写为 **`tcp://<ip>`**（如 `tcp://223.5.5.5`），因为 `qingzhou-relay` 仅转发 TCP（SOCKS5 `CONNECT`），不支持 UDP。
- **国内域名、跳板域名、住宅域名、以及启用的 `.direct` 策略组域名** → 注入国内解析器 `domains` 匹配列表（走直连，拿到国内边缘 IP；节点自身域名若走出口解析会自指成环）。
- **其余域名** → 海外 DoH（`https://1.1.1.1/dns-query`、`https://8.8.8.8/dns-query`）。这些查询按第 1 条规则走 `exit`，出口挂了海外解析就失败，**不会**退回国内 DNS 拿到国内 IP。
- **TUN IPv6 防漏**：`PacketTunnelProvider.swift` 仍声明 `NEIPv6Settings`（`fd00:c0de::1`，捕获 IPv6 默认路由），防止系统绕过隧道直连物理网卡泄漏 IPv6；见 `docs/IPV6.md` 与 `docs/DNS.md`。

## 规则名单与 `geosite:cn` 前置去重

`SplitExitPlan.Lists` 接收国内域名 / 域名关键字 / 国内 IP 段。数据来自 Loyalsoldier/clash-rules 的 `release/direct.txt` 与 `release/cncidr.txt`，由 `SplitExitListsUpdater`（主 App）每天拉一次，写到 App Group 的 `xray-data/split-exit-lists.json`，隧道扩展启动时全量读取（`PacketTunnelProvider+SplitExit.swift` 已移除多余的 `.prefix(...)` 截断）。

**格式（实测）**：这两份文件是 Clash **rule-provider** 格式，不是规则行：

```
payload:
  - '+.2mdn-cn.net'
```

- `payload:` 是表头，跳过；
- `- '...'` 是列表项；
- `+.domain` / `*.domain` 表示"该域及其子域"，前缀要剥掉（xray 的 `domain:` 本身就是含子域）；
- 剥完只剩一个标签的（如 `+.app`）是**顶级域后缀**，归到域名而非关键字 —— 当关键字会变成子串匹配，`app` 会命中 happy/apple 之类。

**`geosite:cn` 前置去重与抽样（M3 优化）**：
源 `direct.txt` 约 110,202 条域名、`cncidr.txt` 约 9,665 条网段。若直接对 11 万条按 `30,000` 上限等距抽样，大量已被内置 `geosite:cn` 覆盖的域名会挤占名额（约 73% 丢弃率）。M3 新增如下机制：

1. **提取精简匹配表（保持 `QingzhouApp` 不依赖 `XrayCore`）**：`scripts/extract-geosite-cn.py` 从 `Apps/Tunnel-Shared/Resources/geosite.dat` 的 `CN` 分类提取出 `Sources/QingzhouCore/Resources/geosite-cn.txt`（共 5,722 行 / 5,718 条规则：`domain=5675, full=40, regexp=3`，`--check` 校验 100% 吻合）。
2. **主 App 前置过滤**：`QingzhouCore` 内的 `GeoSiteCNMatcher` 按与 xray-core 一致的语义（`full:` / `domain:` 子域后缀 / `regexp:`）判定覆盖关系。`SplitExitListsUpdater` 在解析验证非空后，**先**用 `!geoSiteCNMatcher.isCovered($0)` 剔除已被 `geosite:cn` 覆盖的域名，**再**按 `SplitExitListsLimits`（`domains = 30_000`、`keywords = 2_000`、`cidrs = 8_000`）对余集做等距抽样（避免字母序前缀截断）。
3. **UI 统计展示**：设置页与 `SplitExitListsView` 将去重后余集作为有效分母，并单列「`geosite:cn` 已去重」条目数，避免把已去重部分误判为抽样丢弃。

几条刻意的取舍：

- **两份都成功才更新**：只有域名没有 IP（或反之）会让国内直连出现看不见的缺口，比"这次不更新"危险得多。
- **失败保留旧名单**：拉不到 / 解析出 0 条 / 写盘失败 / 回读不一致，都不覆盖旧文件。
- **写完回读校验**：写得进去但读不回来，和没写是一回事。
- **关键字单独存**：`DOMAIN-KEYWORD,wechat` 这种不含点的条目如果加 `domain:` 前缀，就变成"以 `.wechat` 结尾"，等于把规则丢掉；它们按裸串（xray 的子串匹配）注入。
- **注入上限**：`SplitExitListsLimits` 为 **域名 30,000 / 关键字 2,000 / IP 段 8,000**；超出部分由内置 `geosite:cn` / `geoip:cn` 兜底（真机 50 MiB NE 内存实测列入验收清单）。

名单为空时仍是正确行为（只用内置 geosite/geoip），只是粒度粗一些。

## geosite 分类白名单

xray 遇到 routing 里引用了不存在的 geosite 分类会**直接启动失败**——一条手写错的规则就能让整机断网。所以 `GeoDataBundle.supportsGeoSite`（`Sources/QingzhouCore/TunnelMemoryStats.swift`）用白名单，只放行内置 dat 里核实过的分类；未知名与 `!cn` 这种反转写法一律跳过（xray 没有反转语义，透传会得到永不命中的规则）。
目前白名单共有 **21 个分类**（3 个分流骨架 + 3 个常见直连站点 + 2 个海外/拒绝 + 13 个常用站点分类；内置 dat 共 1,469 个，要引用其它分类需扩表并做一次真机启动验证）。

## 实现状态

已完成（有单测，含 M1–M3 加固与重构）：

- SOCKS5 协议解析 / 出站 / 分享链接编码 / Clash YAML 导入
- `dialerProxy` 链式出口（`exit → hop → relay`、`direct → relay`）、单出口 UDP 拒绝、`blockQUIC` 透传
- `GEOSITE` 规则类型与转换、21 项 geosite 白名单、`SplitExitPolicyGroup` 通用自定义策略组
- 上述规则顺序、DNS 结构、假 IP 结构、出口组结构的完整配置构造
- **接入 App（`#if os(macOS)` 平台隔离 + 4 语本地化）**：设置页 `SettingsSplitExitSection` / `SettingsGuardSection` 仅在 macOS 编译暴露，iOS 不会暴露 root/`sudo`/系统时区界面；`AppState.startTunnel` / `performReapply` 传参至扩展
- **国内名单每日更新与去重**：`SplitExitListsUpdater` + `GeoSiteCNMatcher` 前置去重 + 抽样写入 App Group，`PacketTunnelProvider+SplitExit` 启动读取
- **断网开关（`Tools/qingzhou-guard` + `Sources/QingzhouGuardRelayCore`）**：中继并发隔离、DNS/日志轮转加固、分离 `forward:`/`control:` 凭据、TCP `10809` 时区控制、`guard-run.sh` fail-closed 1s 轮询、锚点级 `off.sh`、5 步 `enable.sh`、`uninstall.sh` 时区还原均已完成并在本地通过非 root 单测 / TSan

接入时的几条硬约束（都有测试或显式分支）：

- 出口或跳板缺一个 → **不连接**并报原因，绝不退回单节点。回退等于让住宅代理从本机直连。
- 出口与跳板是同一节点 → 拒绝（会绕成死循环）。
- 分流开启期间**跳过自动择优**（否则会把 `currentNodeId` 改掉，等于自动换出口）。
- 分流开启时强制 `.rule` 模式（全局/直连那两套 routing 与它互斥）。
- 扩展内 `reconfigure` / `switchNode` 在分流模式下**明确回错**，让主 App 回退全量重启；否则会用旧节点套新配置，产生"半新半旧"的配置。
- 通用规则页的用户规则不混入分流规则顺序（否则破坏优先级保证）；需要额外分流规则时通过通用 **`SplitExitPolicyGroup`**（`policyGroups`）配置。

待真机 / 特权环境验收（见 `docs/ACCEPTANCE-CHECKLIST-teamwork.md`）：

1. **断网开关实机 E2E（需 `sudo`）**：`install.sh` / `enable.sh` / `guard-run.sh` 1s `utun` 切换与断网不漏 / TCP `10809` `SET-TZ` & `RESTORE` 调 `systemsetup` / `off.sh` 锚点清理 / `uninstall.sh` 卸载还原，使用 `sudo sh Tools/verify-guard-e2e.sh --yes-i-know` 在目标机执行。
2. **UDP `CMD=3` 产品决策**：当前中继仅支持 TCP `CONNECT`，分流 + 中继下国内 UDP 应用不通，待决定是实现 `UDP ASSOCIATE` 还是走 `uot`。
3. **Xcode 签名构建与真机隧道回归**：`Qingzhou-iOS`（Simulator）与 `Qingzhou-macOS` 的无签名构建（`CODE_SIGNING_ALLOWED=NO`，含 Tunnel 扩展）已在 M2/M3 及 `Tools/verify-local.sh` 验证通过；真机签名构建、安装及隧道启停仍需人工验收。
4. **NE 50 MiB 真机内存实测**：`SplitExitListsLimits`（`30,000` 域名 / `2,000` 关键字 / `8,000` 网段，经 `geosite:cn` 去重后）已在单元测试中校验内存/条目契约，需在真机运行中通过设置页「诊断」观察扩展 `phys_footprint` 是否安全低于 50 MiB jetsam 上限。
