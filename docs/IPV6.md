# IPv6 设计边界：全链路 IPv4 的取舍、依据与备用双栈方案

> 2026-07-06 定稿。结论：**轻舟当前全链路只走 IPv4**（DNS 不解析 AAAA、fakedns 只有
> IPv4 假 IP 池、direct 出站 UseIPv4），是刻意取舍而非疏漏。仅 IPv6 的站点直连不可达 ——
> 主 App 会探测并在连接页打「仅 IPv6」徽标 + 记日志，用户遇到时不黑盒。
> 若未来要支持仅 IPv6 站点，按 §4 的备用方案实施。

## 1. 为什么全链路 IPv4（cctv 案根因回顾）

fakedns 给**每个**域名的 A / AAAA 查询都分配假 IP。浏览器（Happy Eyeballs，IPv6 优先）
拿到假 IPv6 就优先用它连接。但很多国内域名**只有 A、没有真实 AAAA**（实测
`cbs-u.sports.cctv.com`，央视世界杯赛程 API）——旧配置下 freedom 出站（默认 AsIs）
跟随入站地址族尝试 IPv6、解析真实 AAAA 落空 → **整个域名在浏览器里连不上**
（curl 用 IPv4 一直正常，最初被误判成跨域/CORS 问题）。

修复（`XrayConfigComposer`，2b73801 + b7efbec）：
- fakedns 只保留 IPv4 池 `198.18.0.0/15`（删 `fc00::/18`）；
- DNS `queryStrategy: UseIPv4`（三种模式，不解析 AAAA）；
- direct 出站 freedom `domainStrategy: UseIPv4`。

真机验证：cbs-u 从 Failed to fetch → 200，世界杯赛程页完整渲染。

## 2. 代价与边界

| 站点类型 | 现实占比 | 当前行为 |
|---|---|---|
| 双栈（A + AAAA） | 绝大多数 | ✅ 走 IPv4，正常 |
| 仅 IPv4（无 AAAA） | 32%+（含 GitHub、大量国内 CDN） | ✅ 正常（本次修复的对象） |
| **仅 IPv6（无 A）** | **≤0.01%~0.5%（全是技术 demo 页）** | ❌ 直连不可达（走代理时由节点解析、或可用） |

为什么不能"都要"：fakedns 若不接管 AAAA（只配 v4 池时对 AAAA 落空、fallthrough 到真实
DNS），双栈站点的浏览器就会拿到**真实 IPv6** 直连 → 绕过 fakedns → 域名反查失效、
按域名分流失效、连接页变回裸 IP。保护 fakedns 完整性与放开 AAAA 在"只配 v4 池"的
前提下互斥 —— 除非按 §4 恢复双池并让出站按真实记录选族。

## 3. 调研依据（2026-07-06，多源对抗验证）

核实论断「仅 IPv6 的公众网站几乎不存在」→ **成立（高置信度）**：

- **Alexa Top 100 万**（PAM 2023, Streibelt et al.）：主动测量仅 **16 个域（≤0.01%）**
  只能经 IPv6 解析；对照 IPv4-only 占 ~32-33%。<https://arxiv.org/pdf/2302.11393>
- **全球 Verisign .com/.net**（Cui et al. 2022，联通流量研究）：IPv6-only 仅 **0.11%**；
  中国 IPv6 加速部署流量内也只有 2.44%。<https://arxiv.org/pdf/2204.09539>
- **Tranco top-100k 全域名爬取**（USC/ISI 2025.04）：最宽口径（含子域/第三方资源域）
  IPv6-only 上限 **1.7%**；站点级分类没有 IPv6-only 桶。<https://arxiv.org/html/2507.11678v1>
- **常见混淆**：「IPv6 支持率」29-43%（W3Techs / Cloudflare）全部是**双栈**，没有一个
  头条指标在测 IPv6-only。<https://blog.cloudflare.com/ipv6-from-dns-pov/>
- **中国国家 IPv6 战略明确是双栈**：网信办案例，阿里云 CDN（国内第一）改造 = 在 A 记录
  之上加 AAAA，不提供纯 IPv6 模式。<https://www.cac.gov.cn/2022-01/14/c_1643762443915417.htm>
- **现存 IPv6-only 站点**：专门目录只收得到 ~13 个，全是 demo/宣传页
  （如 thiswebsiteisipv6only.com）。没有任何主流服务。
- **反向才是大头**：GitHub 至 2026 仍无 AAAA；真实流量仅 13.2% 走 IPv6
  （去掉 Top 100 域名后 8%）。禁 v6 留 v4 站在坚固的一边；反过来会断 1/3 的网。

## 4. 备用双栈方案（搁置，需真机回归后才可启用）

若未来确需支持仅 IPv6 站点（有真实用户反馈具体站点时再做），方案：

1. **fakedns 恢复双池**：`198.18.0.0/15` + `fc00::/18` —— AAAA 查询也拿假 IP，
   fakedns 完整性保住（不会 fallthrough 泄真实 AAAA）；
2. **DNS `queryStrategy: UseIP`**（放开内部 AAAA 解析能力）；
3. **direct 出站 freedom `domainStrategy: UseIPv4v6`**（关键）：按域名**真实记录**选族 ——
   优先解析 A（保住 cctv 类纯 IPv4 站点，与当前行为一致），A 落空回退真实 AAAA
   （仅 IPv6 站点由此走通）。与入站假 IP 的地址族**解耦**，这正是 cctv 案里
   freedom AsIs「跟随假 IPv6 地址族」死路的对症解法。

预期效果：纯 IPv4 / 纯 IPv6 / 双栈全通且 fakedns 不破。**未真机验证的风险点**：
- freedom `UseIPv4v6` 对仅 IPv6 域名的"A 先失败再回退"时延；
- 双池恢复后 Happy Eyeballs 与假 v6 的交互（cctv 案的旧路径，须专项回归）；
- 设备无 IPv6 网络时假 v6 连接的行为。

回归清单：cbs-u（纯 v4）浏览器可达；thiswebsiteisipv6only.com（纯 v6）可达；
双栈大站正常；连接页域名反查完好；规则/全局/直连三模式各过一遍。

## 5. 「仅 IPv6」检测与标注（已实现）

- `QingzhouCore/IPv6OnlyClassifier`：DoH（dns-json）应答 → `hasIPv4 / ipv6Only /
  unresolvable`，纯逻辑有单测；
- `QingzhouApp/IPv6OnlyProber`：**经 DoH**（阿里 223.5.5.5 优先、Google 8.8.8.8 兜底，
  均为既有 DNS 名单成员）查真实 A/AAAA —— 必须走 DoH：主 App 的 53 端口查询会被
  隧道 fakedns 拦成假 IP，普通查询永远"有 A"；
- 调度：access log 轮询每 2 秒喂最多 3 个新域名，每域名会话内只查一次，
  会话上限 500，裸 IP 跳过；
- 呈现：连接页该域名行打橙色「仅 IPv6」徽标（hover 有解释），日志页记一条
  warn（含"走代理或可用"的说明与本文档指引）。
