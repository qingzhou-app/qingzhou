# 轻舟 · 宣发文稿 / Marketing Copy

> 一处集中放定位、核心叙事、slogan、社群短文、社交媒体 tagline。调性：轻盈、跨越、不张扬 ——
> "轻舟已过万重山"。
>
> ⚠️ **措辞分渠道**：谨慎使用「VPN / 翻墙 / 代理」字眼的规则**只适用于 App Store 文案**
> （名称/副标题/描述/关键词，见 [APP_STORE.md §3](APP_STORE.md)）。社区宣发
> （GitHub / Telegram / Reddit / V2EX 等）**可以直白**说代理、翻墙、proxy —— 用户搜的就是这些词。

---

## 0. 包装主题 / Positioning

> **AI 时代的全新网络代理工具，接入你的工作流 ——
> 全天候后台运行，或编入你的自动化流程。**

*A new-generation network proxy tool for the AI era — built into your workflow:
always-on in the background, or wired into your automations.*

三层含义，宣发时反复回扣：

1. **AI 时代**：AI 服务按出口地区放行/封禁，稳定、可控地区的出口成了生产力刚需，不再是"偶尔查资料"
2. **接入工作流**：不是"打开-用完-关掉"的工具，而是常驻的网络基础设施——自动测速、自动择优、
   自动刷新、定时关闭，全程无人值守
3. **编入自动化**：小组件 / 快捷指令 / Siri / 打开某 App 自动开——代理成为自动化流程里的一个原语

---

## 1. 一句话 Slogan

- 主：**轻舟已过万重山。** / *Lightweight. Private. Yours.*
- 备 1：你的节点，你的规则，什么都不离开这台设备。
- 备 2：零数据收集的原生网络配置工具。
- 备 3（英）：*Bring your own nodes. Nothing phoned home.*
- 备 4（工作流向）：全天候后台护航，或编入你的自动化 —— 网络这层，交给轻舟。

---

## 2. 核心叙事：卖点优先级（每条：痛点 → 轻舟怎么解）

> 按优先级排序，宣发素材（截图 caption、短文、视频脚本）从上往下取。
> 每条含英文版，供 Product Hunt / Reddit / HN 使用。

### ① 节点自动测速 · 批量测速 · 自动择优

**痛点**：手里几十上百个节点，哪个快全靠猜；网络环境一变，刚选的节点又慢了；
手动一个个点测速是体力活，测完还得自己比大小。

**轻舟**：一键批量并发测速；自动定时测速；测完**自动切到最优节点**（切换后 toast 告知，
不打断你手头的事）。网络变差时，它比你先发现、先处理。

**独有的「经代理延迟」双维度测速**：市面上多数客户端只测「设备到节点」的直连握手——
它只说明节点离你近，测不出出口绕路，更测不出**密码错误 / 已下线的假活节点**（直连延迟
照样漂亮）。轻舟额外提供全链路实测：VPN 运行中让 xray 携带完整协议**真实通过节点访问一次
google.com**，测出你实际上网的端到端耗时。两个数字并排一比：直连快、经代理慢 = 出口绕路；
直连快、经代理失败 = 节点根本不可用。**自动择优默认用它精选**——先按直连排序取前几名，
再逐个真实走一遍代理选真冠军，假好节点永远混不进你的「当前节点」。

*EN: Dual-dimension latency. Most clients only measure the TCP handshake to the node —
which says nothing about exit routing, and happily shows great numbers for dead or
misconfigured nodes. Qingzhou additionally measures **through-proxy latency**: while the
VPN is running, xray makes a real request to google.com through the node, capturing the
true end-to-end experience. Auto-select uses it to re-rank the top direct candidates, so
a "fast-looking" dead node never becomes your current node.*

### ② 定时关闭

**痛点**：临时开代理下载个更新，忘了关——流量在节点上白跑一整晚（按流量计费的订阅尤其肉疼），
还平白多一层暴露面。

**轻舟**：开启时顺手设个自动关闭（预设或自定义时长），到点自动断开。用完即走，不留尾巴。

*EN: Set an auto-stop timer when you connect — preset or custom duration. No more
"left the proxy on all night" traffic bills.*

### ③ 订阅自动刷新

**痛点**：服务商换节点、换域名，订阅不刷新就集体失联；总是在"连不上了"之后才想起手动刷新。

**轻舟**：按周期后台自动刷新订阅，节点变更静默同步，已失效的悬空选中自动清理。
订阅这件事，配置一次就不用再想。

*EN: Subscriptions refresh themselves on schedule; node changes sync silently, dangling
selections get cleaned up. Configure once, forget forever.*

### ④ 地区优先 / 排除 —— AI 时代刚需

**痛点**：越来越多 AI 服务按出口地区放行或封禁。自动择优只看延迟的话，可能把你切到
被封地区的出口——延迟最低，但 AI 服务直接 403。

**轻舟**：设定「地区优先 / 地区排除」，自动择优只在允许的地区池子里挑——
**锁定**能用 AI 服务的出口，**避开**被封的地区。速度与可用性兼得。

*EN: Region prefer/exclude — pin your exit to regions your AI services accept, or ban
regions they block. Auto-selection then picks the fastest node **within** your allowed
pool. Essential in the AI era, where access is gated by exit region.*

### ⑤ 域名分析 · 汇总 · 优化建议 —— 越用越智能

**痛点**：分流规则是死的，你的访问习惯是活的。哪些域名走了代理、哪些其实可以直连、
哪条自定义规则从来没命中过——一概不知，规则越堆越乱。

**轻舟**：基于真实连接日志的域名聚合、每日摘要与**规则优化建议**；自定义规则带命中计数，
长期零命中的会提示"可考虑删除"；追踪器域名自动识别并建议拒绝。你的规则集随使用越来越贴合你。

*EN: Per-domain analytics on real traffic: aggregation, daily digests, and rule
suggestions. Custom rules carry hit counters — dead rules get flagged. Your ruleset
gets smarter the more you use it.*

### ⑥ 本地 AI 能力接入（roadmap）

**方向**（规划中，措辞谨慎——不承诺时间）：探索用设备端模型对流量与域名画像做**本地**分析
与建议——一切计算留在设备上，与零收集原则一致。

*EN: On our roadmap: exploring on-device AI to analyze your traffic patterns and suggest
optimizations — locally, consistent with our zero-collection principle. No promises on
timing; no cloud, ever.*

### ⑦ 小组件 + 自动化：控制中心 / 锁屏 / 快捷指令 / Siri / 打开某 App 自动开

**痛点**：开个关代理要「解锁 → 找 App → 进首页 → 点开关」四步；自动化玩家想要
"打开 Slack 自动开、全部退出自动关、晚上 11 点定时断"，但多数客户端没给原语。

**轻舟**：主屏 / 锁屏小组件、iOS 18 控制中心一键开关、快捷指令拿来即用 + Siri 短语、
VPN 状态可做自动化条件分支、macOS 打开指定 App 自动开 VPN / 全部退出自动关。
代理成为你自动化流程里的一等公民。（部分能力实现中，发布文案以届时实际功能为准）

*EN: Home-screen & lock-screen widgets, iOS 18 Control Center toggle, ready-made
Shortcuts with Siri phrases, VPN-status conditionals for automations, and macOS
"auto-connect when app X launches". Your proxy becomes a first-class primitive in your
automation flows. (Some items in active development — align copy with shipped features.)*

### ⑧ TUN only 模式：告别系统代理的所有坑

**痛点**（系统代理模式的账，一笔笔算）：

- 终端要手动 `export http_proxy/https_proxy`，换个 shell、新开个 tmux pane 就漏了，
  `curl` 通了 `git` 又不通
- 浏览器要配端口转发；**无痕模式根本不吃系统代理**
- 不支持代理设置的 App —— 比如邮件客户端 —— 收发不了需要代理的邮件，无解
- 每个工具一套代理配置（Docker、ssh、包管理器……），配到怀疑人生

**轻舟**：TUN 模式在网络层全局接管——终端、无痕窗口、邮件客户端、任何进程，
一律无感生效，**零配置**。开了就是全通，关了就是全断，没有中间态的玄学。

*EN: TUN-only mode takes over at the network layer. No more `export http_proxy` in every
shell, no port-forwarding for browsers, no "incognito ignores system proxy", no
mail-client-can't-reach-server. Every process is covered, zero per-app config.*

### ⑨ 轻量：224KB 精简 geo + 秒开主 App

**痛点**：同类客户端动辄内置几十 MB 的 geo 数据库；主程序捆着庞大 runtime，点开图标黑屏几秒。

**轻舟**：内置精简 geo 仅 **224KB**（覆盖 cn/private，规则分流最常用的就这俩）；
需要全量国家码时**一键下载完整版**（双源 + sha256 校验，校验不过绝不落盘）。
主 App 刻意不链接 Go runtime（85MB 的核心只活在隧道扩展进程里），启动秒开。

*EN: Ships with a 224KB slim geo database; full version is one tap away (dual mirrors,
sha256-verified). The main app deliberately excludes the 85MB Go runtime — it lives only
in the tunnel extension — so the app launches instantly.*

### ⑩ 多平台 iOS / macOS + iCloud 配置同步（含历史版本找回）

**痛点**：iPhone 和 Mac 各配一遍，改了这边忘了那边；手滑删了订阅 / 规则，没有后悔药。

**轻舟**：iOS / macOS 同一套 App、同一套体验；订阅 / 节点 / 规则经 iCloud 保险柜同步，
**带历史版本**——误删误改可以回滚找回。换新设备，登录 iCloud 即恢复。

*EN: One app across iOS and macOS. Subscriptions, nodes, and rules sync via your own
iCloud — with version history, so a fat-fingered delete is recoverable. New device?
Sign in and restore.*

### ⑪ 协议支持广 → 从其他客户端快速迁移

**痛点**：换客户端最烦的是节点搬家——协议不全、链接格式不认、导出无门。

**轻舟**：trojan / vmess / vless / shadowsocks / hysteria2 / VLESS+REALITY 分享链接
直接粘贴；Clash YAML 一键导入；还能**反向导出**全部节点为标准分享链接。
从别的客户端来、往别的客户端去，都不锁你。

*EN: trojan / vmess / vless / shadowsocks / hysteria2 / VLESS+REALITY share links paste
right in; Clash YAML imports in one tap; and you can export every node back out as
standard links. Easy in, easy out — no lock-in.*

### ⑫ 数据 local only · 零收集 · 无第三方 SDK · MIT 开源可审计

**痛点**：代理客户端天然经手你最敏感的流量元数据。闭源客户端说"不收集"，你只能选择信。

**轻舟**：节点 / 订阅 / 规则 / 统计全部只存在你的设备上；零数据收集、无账号体系、
无任何第三方 SDK、无广告；**MIT 开源**——不用信我们的嘴，去读代码。

*EN: Everything stays on your device. Zero data collection, no accounts, no third-party
SDKs, no ads. MIT-licensed and fully auditable — don't trust our word, read the source.*

### 附加卖点（技术叙事，社区/技术渠道用）

- **50MB 内存工程 = 稳定不断流**：iOS 给 VPN 扩展进程的内存硬上限只有 50MB，超了系统直接
  杀进程——很多客户端"挂久了莫名断线"的真正原因。轻舟把扩展内存工程当第一优先级
  （精简 geo、按需统计、内存预算纪律），换来的是长时间挂着不断的稳。
  *EN: iOS kills VPN extensions above a hard 50MB memory cap — the real reason many
  clients "randomly drop" after hours. We treat extension memory as a first-class
  engineering constraint; the payoff is a tunnel that stays up.*
- **切换不断网**：切换到配置有问题的节点前先预检，失败则保持当前连接不变——
  一个坏节点不会把你现有的连接拖下水。
  *EN: Config preflight on switch — a broken node never tears down your working connection.*

---

## 3. 应用商店描述（精炼宣发版）

**中文（~90 字）：**
> 轻舟是一款原生、轻量、零数据收集的 iOS / macOS 网络配置工具。多协议节点订阅、自动测速择优、
> 地区优先、智能分流、域名分析、定时关闭、小组件与快捷指令自动化，一切只存在你的设备上。
> 开源可审计，不运营节点 —— 你自备节点，它负责优雅转发。

**English (~70 words):**
> Qingzhou is a native, lightweight, zero-data-collection network utility for iOS & macOS.
> Multi-protocol node subscriptions, auto latency-testing with best-node selection, region
> pinning, smart routing, per-domain analytics, auto-stop timers, and widget/Shortcuts
> automation — all stored only on your device. Open-source and auditable. Bring your own
> nodes; it just forwards, elegantly.

> App Store 正式文案（名称/副标题/关键词/4000 字描述）见 [APP_STORE.md §3](APP_STORE.md)，
> 那边遵守避敏感词规则。

---

## 4. 社群宣发短文（面向海外华人社区，可直白用「代理」）

**中文（~230 字）：**
> **轻舟 / Qingzhou — AI 时代的网络代理工具，接入你的工作流**
>
> 我们做了一款原生 iOS / macOS 代理客户端：不收集你任何数据，不接任何第三方 SDK，
> 节点 / 订阅 / 规则全部只存在你自己的设备上（iCloud 同步走你自己的账号，带历史版本找回）。
> 它**不提供节点** —— 节点你自己有，轻舟负责把流量按你的规则优雅转发。
>
> 顺手的地方：批量测速 + 自动择优、地区优先/排除（锁定能用 AI 服务的出口）、订阅自动刷新、
> 定时关闭、域名分析和规则优化建议（越用越懂你）、TUN 全局接管（终端/无痕/邮件客户端
> 全部无感生效）、小组件和快捷指令自动化。支持 trojan / vmess / vless / ss / hysteria2 /
> VLESS+REALITY 和 Clash 导入，也能整套导出——不锁你。
>
> App 代码 MIT 开源，你能看清它到底做了什么。名字取自"轻舟已过万重山"。
>
> 即将上架国际区 App Store。源码与进展：github.com/qingzhou-app/qingzhou

**English (~140 words):**
> **Qingzhou — a proxy client for the AI era, built into your workflow.**
>
> A native iOS / macOS client that collects **zero** data, embeds **no** third-party SDKs,
> and keeps your nodes, subscriptions, and rules **only on your device** (iCloud sync uses
> your own account, with version history). It runs no nodes — you bring your own; it
> forwards traffic by your rules, elegantly.
>
> The good parts: batch latency tests + auto best-node selection, region prefer/exclude
> (pin exits your AI services accept), auto-refreshing subscriptions, auto-stop timers,
> per-domain analytics with rule suggestions, TUN-mode full takeover (terminals, incognito,
> mail clients — all covered, zero config), plus widgets and Shortcuts automation.
> Supports trojan / vmess / vless / ss / hysteria2 / VLESS+REALITY and Clash import —
> and full export, so there's no lock-in. MIT-licensed and auditable.
>
> Coming soon to the international App Store. Source: github.com/qingzhou-app/qingzhou

---

## 5. 社交媒体 / 论坛 tagline

- **Product Hunt**: Qingzhou — a native, zero-data-collection proxy client for iOS & macOS.
  Auto best-node selection, region pinning for AI-era access, TUN-mode full takeover,
  widgets & Shortcuts automation. Bring your own nodes.
- **Twitter/X**: 零数据收集 · 开源 · 原生 SwiftUI。自动测速择优、地区锁定、TUN 全局接管、
  快捷指令自动化。你的节点，你的规则，什么都不离开设备。轻舟 → github.com/qingzhou-app/qingzhou
- **Reddit (r/iOSProgramming 等)**: I built a native, open-source, zero-telemetry proxy
  client for iOS/macOS — auto best-node selection, per-domain analytics, TUN mode, and a
  hard 50MB-memory-budget tunnel extension that doesn't randomly drop. BYO nodes.
- **Hacker News (Show HN)**: Show HN: Qingzhou — open-source iOS/macOS proxy client;
  the tunnel extension lives under iOS's 50MB memory cap by design (slim 224KB geo DB,
  on-demand stats), so it stays connected where others get OOM-killed.

---

## 6. 发布渠道建议（优先级）

1. **GitHub** — README + Release notes（首发主阵地，开源可信度）
2. **海外华人社群** — 电报群 / Discord / V2EX / 1point3acres（中文短文，可直白说代理）
3. **Product Hunt** — 上架日发，英文版（主打 native + privacy + open-source + automation）
4. **Reddit / Hacker News** — 技术向，强调零遥测 + 开源 + 50MB 内存工程 + NetworkExtension 架构
5. **小众科技博客 / Newsletter** — 投稿英文短文

> ⚠️ 不在中国大陆做 ASO / 推广（见 [APP_STORE.md §0.2](APP_STORE.md)）。
> App Store 文案避敏感词；社区渠道可直白。宣发所需截图 / 录屏素材清单见
> [APP_STORE.md §11](APP_STORE.md)。
