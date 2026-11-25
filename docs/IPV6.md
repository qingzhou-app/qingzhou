# IPv6 设计边界：普通模式双栈演进与分流模式 IPv4 约束

> **2026-11-25 更新（build 38 `8bbe74c9` + `master/teamwork`）**：轻舟目前存在**两套刻意分化的活跃策略**，请按模式区分：
> 1. **普通模式（`XrayConfigComposer.swift`，build 38 起）**：已切换为**双栈 FakeDNS**（`198.18.0.0/15` + `fc00::/18`）、`dns.queryStrategy: "UseIP"`、`direct` 出站 `settings.domainStrategy: "AsIs"` + `sockopt.domainStrategy: "ForceIP"` + `happyEyeballs`（`prioritizeIPv6: true, tryDelayMs: 250`）。该改动**已合入代码并通过单元测试（`XrayConfigComposerTests`、`DNSAntiPollutionPrecheckTests`），尚待真机实网终验**。
> 2. **分流方案（`SplitExitPlan.swift`）**：**刻意保持 `queryStrategy: "UseIPv4"` + 单一 IPv4 FakeDNS 池 `198.18.0.0/15`**；且当启用 root 中继（`relay != nil`）时，去掉 `direct` 的 `ForceIP` 与 `happyEyeballs`（保持 `AsIs` 把原始域名交给中继），国内解析器走 `tcp://<ip>`。
> 3. **TUN 路由防漏（双模式共用）**：`PacketTunnelProvider.swift` 在两种模式下均声明 `NEIPv6Settings(addresses: ["fd00:c0de::1"], networkPrefixLengths: [64])` 并接管 IPv6 默认路由（`NEIPv6Route.default()`），防止真实网络 IPv6 流量绕过隧道直连物理网卡泄漏。

## 1. 历史背景回顾（cctv 案与全链路 IPv4 阶段）

fakedns 给域名的 A / AAAA 查询分配假 IP。早期（build 19–37）曾采用「全链路 IPv4」定稿，根因如下：
浏览器（Happy Eyeballs，IPv6 优先）拿到假 IPv6 后优先用它连接。但很多国内域名**只有 A、没有真实 AAAA**（实测 `cbs-u.sports.cctv.com`，央视世界杯赛程 API）——旧配置下 freedom 出站（默认 `AsIs`）跟随入站假 IPv6 的地址族尝试解析真实 AAAA 落空 → **整个域名在浏览器里连不上**（curl 用 IPv4 一直正常，最初被误判成跨域/CORS 问题）。

彼时 `XrayConfigComposer` 通过「只留 IPv4 池 `198.18.0.0/15` + `queryStrategy: UseIPv4` + direct `domainStrategy: UseIPv4`」解决（cctv 从 `Failed to fetch` → `200`）。同时，若未来放开仅 IPv6 站点支持，必须把入站假地址族与直连出站解析解耦。

## 2. 普通模式双栈实现（build 38 `8bbe74c9`，待真机实网验收）

build 38 在 `Sources/XrayConfig/XrayConfigComposer.swift` 落地了双栈方案（替代早期「直接 `UseIPv4v6`」草稿）：

1. **fakedns 双池**：同时配置 `"198.18.0.0/15"` 与 `"fc00::/18"`（`poolSize: 65535`）。AAAA 查询同样获得假 IP，fakedns 完整性得以保全（不会 fallthrough 泄漏真实 AAAA 导致域名反查/分流失效）。
2. **DNS `queryStrategy: "UseIP"`**：在 `.global`、`.direct`、`.rule` 三种模式下均允许 A + AAAA 查询，并由 `inboundTag: ["tun-in"], port: 53, network: "tcp,udp"` 路由至 `dns-out`（保证 `dns-module` 自身的 TCP/UDP 上游查询不被重入劫持）。
3. **`direct` freedom 出站解耦（`AsIs` + `ForceIP` + `happyEyeballs`）**：
   - `"settings": ["domainStrategy": "AsIs"]`
   - `"streamSettings": ["sockopt": ["domainStrategy": "ForceIP", "happyEyeballs": ["prioritizeIPv6": true, "tryDelayMs": 250, "interleave": 1, "maxConcurrentTry": 4]]]`
   - 不在 `freedom.settings` 层提前把域名塌缩成单一 IP，而是在 socket 拨号层由 `ForceIP` + `happyEyeballs` 并发竞速真实 A 与 AAAA（优先 IPv6、250ms 后并发 IPv4），从而与入站假 IP 地址族彻底解耦：纯 IPv4 域名（`cbs-u.sports.cctv.com`）与纯 IPv6 域名（`thiswebsiteisipv6only.com`）在理论上均可走通。

**验证边界（务必看清）**：
- ✅ 单元测试已覆盖：`Tests/XrayConfigTests/XrayConfigComposerTests.swift`（`testDirectDialerCanRaceBothRealAddressFamilies`、`testDualStackDNSPreservesFakeAddressAttribution`、`testDNSInterceptionCannotRecaptureUpstreamQueries`）及 `Tests/XrayCoreTests/DNSAntiPollutionPrecheckTests.swift`。
- ⏳ **真机实网回归尚未完成**（见 `8bbe74c9` 提交说明与 `docs/ACCEPTANCE-CHECKLIST-teamwork.md`）：需在真机实测以下风险点与场景：
  - `cbs-u.sports.cctv.com`（仅 A 记录）浏览器可达、不回归；
  - `thiswebsiteisipv6only.com`（仅 AAAA 记录）可达；
  - `order.yizhihongxing.club` 直连可达性与双栈大站正常；
  - 无 IPv6 网络环境下假 v6 + Happy Eyeballs 250ms 回退行为；
  - `rule` / `global` / `direct` 三模式及连接页域名反查完好。

## 3. 分流模式（`SplitExitPlan.swift`）为什么刻意保持 `UseIPv4`

与 `XrayConfigComposer` 不同，`Sources/XrayConfig/SplitExitPlan.swift` **刻意保持** `queryStrategy: "UseIPv4"` 与单一 FakeDNS 池 `198.18.0.0/15`（不配 `fc00::/18`），原因如下：

1. **中继与无 `ForceIP` 约束**：启用 root 中继（`relay != nil`）时，`SplitExitPlan` 必须剥离 `direct` 出站的 `ForceIP` 和 `happyEyeballs`（保留 `AsIs` 把原始域名直接交给 `127.0.0.1:10808` 的 `qingzhou-relay`），而 `RelayDNS` 目前只解析 IPv4 `A` 记录。若在 `direct` 保留 `ForceIP`，xray 会拿到 FakeDNS 假 IP 再交给中继拨号，在物理网卡上形成死循环。
2. **静态住宅出口能力边界**：分流模式海外唯一出口是静态住宅 SOCKS5（且默认 `rejectOverseasUDP = true`），多数住宅代理节点无可用 IPv6 出口；若返回 `AAAA` 假地址，在无 Happy Eyeballs 回退的 SOCKS5/中继链路上会导致连接卡死。
3. **DNS 上游协议差异**：`relay != nil` 时，国内 DNS 解析器会改写成 `tcp://<ip>`（走 TCP `CONNECT` 过中继），而 `PacketTunnelProvider` 仍在 TUN 层捕获 IPv6 默认路由（`fd00:c0de::1`，处于 `fc00::/18` 之外），防止启用分流时 IPv6 流量泄漏到物理网卡（断网开关的 `pf` 规则亦仅放行 `fe80::/10` 与 `ff00::/8`，故意不放行 `fc00::/7`）。

> 结论：未来不要把 `SplitExitPlan` 盲目改成 `UseIP`（除非先在 `RelayDNS` 与住宅出口侧完整打通 IPv6），也不要把 `XrayConfigComposer` 的双栈配置误当成已真机终验通过。

## 4. 调研依据（2026-07-06，多源对抗验证）

核实论断「仅 IPv6 的公众网站极少、IPv4-only 仍占相当比例」：

- **Alexa Top 100 万**（PAM 2023, Streibelt et al.）：主动测量仅 **16 个域（≤0.01%）** 只能经 IPv6 解析；对照 IPv4-only 占 ~32-33%。<https://arxiv.org/pdf/2302.11393>
- **全球 Verisign .com/.net**（Cui et al. 2022，联通流量研究）：IPv6-only 仅 **0.11%**；中国 IPv6 加速部署流量内也只有 2.44%。<https://arxiv.org/pdf/2204.09539>
- **Tranco top-100k 全域名爬取**（USC/ISI 2025.04）：最宽口径 IPv6-only 上限 **1.7%**；站点级分类没有 IPv6-only 桶。<https://arxiv.org/html/2507.11678v1>
- **常见混淆**：「IPv6 支持率」29-43%（W3Techs / Cloudflare）全部是**双栈**，不是 IPv6-only。<https://blog.cloudflare.com/ipv6-from-dns-pov/>
- **中国国家 IPv6 战略明确是双栈**：网信办案例，阿里云 CDN（国内第一）改造 = 在 A 记录之上加 AAAA，不提供纯 IPv6 模式。<https://www.cac.gov.cn/2022-01/14/c_1643762443915417.htm>

## 5. 「仅 IPv6」检测与标注（已实现）

- `QingzhouCore/IPv6OnlyClassifier`：DoH（dns-json）应答 → `hasIPv4 / ipv6Only / unresolvable`，纯逻辑有单测；
- `QingzhouApp/IPv6OnlyProber`：**经 DoH**（阿里 223.5.5.5 优先、Google 8.8.8.8 兜底，均为既有 DNS 名单成员）查真实 A/AAAA —— 必须走 DoH：主 App 的 53 端口查询会被隧道 fakedns 拦成假 IP；
- 调度：access log 轮询每 2 秒喂最多 3 个新域名，每域名会话内只查一次，会话上限 500，裸 IP 跳过；
- 呈现：连接页该域名行打橙色「仅 IPv6」徽标（hover 有解释），日志页记一条 warn（含"走代理或可用"的说明与本文档指引）。

## 6. 节点服务器地址探测（2026-10-27）

上文约束的是 TUN/FakeDNS 及出站的目标地址策略，不代表代理服务器自身只能是 IPv4。
实测两条仅有 AAAA 记录的 Trojan 节点，真实代理请求成功，旧 TCP 探针因只查 A 误报 DNS 失败。
节点探针现先查 A，最多 200 毫秒后并发尝试同一总预算内的 AAAA（避免无 A 记录的系统查询耗尽整个预算），两种地址族必须完成 TCP 握手才采认成功（仅 DNS 快不能排除另一族），仍绑定同一物理接口、显式忽略系统代理。
