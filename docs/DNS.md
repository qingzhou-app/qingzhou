# DNS 与防污染 —— 设计与踩坑（改 DNS/fakedns 前必读）

> 轻舟的 DNS 是「fakedns 分层 + 按域名分流 + 公共 DNS 上游强制直连」。改这里前先读本文 + `docs/IPV6.md`。
> 核心配置分别在 `Sources/XrayConfig/XrayConfigComposer.swift`（普通模式，build 38 起双栈）与
> `Sources/XrayConfig/SplitExitPlan.swift`（分流模式，刻意保持 `UseIPv4` + 单一 IPv4 FakeDNS 池）。

## 为什么需要 fakedns（分层查号）

规则模式要按**域名**分流（国内直连 / 国外代理），但连接建立时用的是 IP，路由只看到 IP 就
不知道是哪个域名了。fakedns 的巧计：app 查域名 → fakedns 发一个假 IP →
app 连假 IP → TUN 靠 sniffing 的 fakedns 反查回真域名 → 于是路由/access log 都拿到域名。

- **普通模式（`XrayConfigComposer.swift`，build 38 `8bbe74c9`）**：
  - fakedns **同时配置双池**：`198.18.0.0/15`（IPv4）+ `fc00::/18`（IPv6），`poolSize: 65535`；
  - `dns.queryStrategy: "UseIP"`（放开 A + AAAA）；
  - `direct` freedom 出站改为 `settings.domainStrategy: "AsIs"` + `sockopt.domainStrategy: "ForceIP"` + `happyEyeballs`（`prioritizeIPv6: true, tryDelayMs: 250, interleave: 1, maxConcurrentTry: 4`），使拨号层与入站假地址族解耦，避免仅 A 域名因假 IPv6 走死路（**代码与单测已合入，待真机实网终验**，见 `docs/IPV6.md` 与 `docs/ACCEPTANCE-CHECKLIST-teamwork.md`）。
- **分流模式（`SplitExitPlan.swift`，刻意区别于普通模式）**：
  - **仅配 IPv4 FakeDNS 池 `198.18.0.0/15`**（不配 `fc00::/18`）+ `queryStrategy: "UseIPv4"`；
  - 启用 root 中继（`relay != nil`）时，`direct` 去掉 `ForceIP`/`happyEyeballs`（保持 `AsIs` 将域名原样发往 `127.0.0.1:10808` 的 `RelayDNS`，后者仅解析 A 记录），且住宅 SOCKS5 出口多无 IPv6 并拒绝 UDP；
  - 启用 `relay != nil` 时，国内 DNS 解析器自动改写为 **`tcp://<ip>`**（如 `tcp://223.5.5.5`），避免 UDP 无法穿过仅支持 TCP `CONNECT` 的中继；
  - 启用的 `.direct` 自定义策略组（`SplitExitPolicyGroup`）域名也会注入国内解析器 `domains` 匹配列表。
- **海外域名的查询被 fakedns 接管** → 域名甩给海外出口解析（出口在干净环境，天然避污染）。所以海外域名不需要在本地查真实 DNS。

## 头号坑：DNS 上游查询绕代理（东方甄选案，2026-07-12 真机定位）

**症状**：规则模式下「东方甄选」等国内 app 首屏/直播/下单页必先慢或失败；切「直连」模式立刻全好。

**根因（铁证）**：fakedns 接不住的查询或漏网请求会 **fallthrough 到真实上游** `8.8.8.8` / `1.1.1.1`。
而这些上游查询**本身经过路由**：`8.8.8.8` 非国内 IP、不命中 `geoip:cn` → 落到 catch-all `tcp,udp→proxy` →
**被当海外流量踹去代理节点（英国）**。于是：
①DNS 绕地球半圈，几百 ms/超时；②从海外出口查国内域名，拿到「服务海外用户」的边缘 IP →
国内连它被风控/超时。app 每个请求前都要查号，DNS 一卡就全盘卡。

**判别实验**：切直连模式——还慢=非轻舟锅；立刻好=轻舟 DNS 环节。东方甄选=后者。

## 解法：DNS 第 3 档（防污染 + 强制直连，build 19 定案；build 38 精确入站拦截）

以 mihomo/sing-box 的成熟范式为参照，在 xray-core 上落地：

1. **DNS 模块上游查询用 `inboundTag` 捞出来直连，并把 `dns-out` 规则限定到 `inboundTag: ["tun-in"]`（`buildRouting` 首两条规则）**：
   - `buildDNS` 给 dns 段打 `"tag": "dns-module"`；
   - `buildRouting` `.rule` 模式**第一条**：`{"type": "field", "inboundTag": ["dns-module"], "outboundTag": "direct"}`（在 `SplitExitPlan` 中则拆成「国内解析器 IP → `direct`，其余 `dns-module` → `exit`」）；
   - **第二条（build 38 `8bbe74c9` 加固）**：`{"type": "field", "inboundTag": ["tun-in"], "port": 53, "network": "tcp,udp", "outboundTag": "dns-out"}`（三个模式及 `SplitExitPlan` 统一如此）。
   - **为什么要同时加 `inboundTag: ["tun-in"]` 并扩展到 `network: "tcp,udp"`**：
     - 限定 `inboundTag: ["tun-in"]` 确保仅 App 经 TUN 发来的 53 端口查询进入 `dns-out` / fakedns，彻底杜绝 `dns-module` 自己的 TCP/UDP 上游查询被误劫持重入；
     - 将 `"udp"` 扩展为 `"tcp,udp"` 覆盖大包截断或原生使用 TCP 53 的 DNS 查询，防止其绕过 `dns-out`。
   - ⚠️ **为什么必须 `inboundTag`、且 `dns-module` 规则必须在 `dns-out` 之前**（build 16~18 三次踩坑教训）：DNS 上游查询也是 `53` 端口，若排在 `port:53→dns-out` 之后会先撞上 `dns-out` 重入 dns 模块形成环，被踢去默认代理。纯 IP 规则（`8.8.8.8/1.1.1.1/223.5.5.5... → direct`）保留作**双保险**，位置在 `dns-out` 与 `blockQUIC` 之后。
2. **海外/漏网查询走 DoH 加密直连**（普通模式 `buildDNS`）：`https+local://dns.google/dns-query` + `https+local://cloudflare-dns.com/dns-query` 兜底。`https+local://` = 加密（GFW 看不到查询内容、无法投毒）+ `+local` 绕过路由直接 Freedom 直连。明文 `8.8.8.8/1.1.1.1` 作 DoH 被干扰时的兜底，由上面的 direct 规则保证也走直连。（注：在 `SplitExitPlan` 中，海外 DoH `https://1.1.1.1/dns-query` / `https://8.8.8.8/dns-query` 故意不带 `+local`，使其经 `dns-module` 走 `exit` 出口。）
3. **国内域名走阿里直连**：普通模式 `{223.5.5.5, domains:[geosite:cn]}`；分流模式则同时注入节点自身域名、`SplitExitLists` 与 `.direct` 策略组域名（启用中继时地址用 `tcp://<ip>`）。

## 刻意不做：GeoIP 回退校验（`expectIPs`）—— 会踩 cctv 坑

mihomo 的 `fallback-filter` 用 GeoIP 校验国内 DNS 的答案、非 CN IP 视为污染重查。xray 的对应物
是 `expectIPs: [geoip:cn]`。**但我们不用**：`buildDNS` 注释里记的央视案证明——国内 CDN
（`p.data.cctv.com` 等）的合法边缘 IP 常在**非 CN 注册段**（港澳/国际 CDN/IPv6），`geoip:cn`
校验会把它当污染丢弃 → fallthrough 到海外查 → 拿海外边缘 → 国内连它超时。**海外域名靠 fakedns+节点已经天然防污染，不需要这层校验。**

## xray-core 的 DNS 能力边界（换内核才能补的）

- ✅ 有：DoH（`https://`/`https+local://`）、DoQ（`quic+local://`）、per-server `domains`/
  `queryStrategy`/`skipFallback`、`expectIPs` GeoIP 过滤、DNS 定向出站（DNS tag + `inboundTag`
  路由 + `sendThrough`，维护者在 XTLS/Xray-core#6151 亲证）。
- ❌ 内核级限制：xray 内部 resolver **丢掉发起连接的 inboundTag** → DNS 无法按「哪个连接触发」
  路由（#6151、#4987 都 closed not planned）。轻舟不需要 per-connection DNS，不受影响。

## 验证纪律

- 改 `buildDNS`/`buildRouting` 或 `SplitExitPlan` 后跑 `DNSAntiPollutionPrecheckTests`、`SplitExitPolicyGroupPrecheckTests`（`XrayCore.testConfig` 真构建，datDir 指向 `Apps/Tunnel-Shared/Resources`）及 `XrayConfigComposerTests` —— **防「配置语法 xray 不认→真机隧道起不来→用户断网」**。
- ⚠️ **JSON 序列化把 `/` 转义成 `\/`**：断言 config 字符串时别用带 `/` 的整串（如 `https+local://dns.google/dns-query`），用不含 `/` 的片段（`dns.google` + `https+local`）。
- **必须真机三方回归**（此环境测不了真拨号）：①东方甄选类国内 app 恢复 ②央视/CN CDN（`cbs-u.sports.cctv.com`）在 build 38 双栈下不回归 ③`thiswebsiteisipv6only.com` / `order.yizhihongxing.club` / YouTube 等站点正常（详见 `docs/ACCEPTANCE-CHECKLIST-teamwork.md`）。
