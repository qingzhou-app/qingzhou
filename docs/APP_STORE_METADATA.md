# App Store 元数据（B.5，2026-07-11 草稿）

> 上架文案的权威草稿。粘贴进 App Store Connect 前在这里改定稿——改这里，别只改 ASC（留痕）。
> 敏感词纪律：不出现「翻墙 / 绕过审查 / 科学上网 / GFW」等词——国际区也不用，审核安全边际。

## 通用定位

一句话：**轻舟——把你自己的节点用到极致的 VPN 客户端。**
模型：BYO（Bring Your Own）——App 不内置、不销售任何节点/服务器；用户自备订阅或分享链接。免费、无广告、无账号。

---

## iOS（ASC 已有记录：轻舟）

### 副标题（≤30 字符）

- zh-Hans：`自备节点的智能 VPN 客户端`
- en：`Smart client for your own nodes`

### 推广文本（≤170 字符，可随时改不用送审）

- zh-Hans：`多维打分自动择优、零断流换节点、规则分流、广告拦截、流量与域名分析。你的节点，用到极致。`
- en：`Multi-dimensional node scoring, seamless switching, smart rules, ad blocking, traffic insights. Your nodes, used to their fullest.`

### 描述（zh-Hans）

```
轻舟是一款把「你自己的节点」用到极致的 VPN 客户端。它不提供任何服务器——导入你的订阅或分享链接，剩下的交给轻舟。

【为什么选轻舟】
• 多维打分择优：延迟、稳定性、带宽、成本（倍率）四个维度综合打分，自动选出真正好用的节点，而不是瞬时 ping 最低的那个；每个选择都能看到「为什么选它」的评分构成
• 零断流换节点：切换节点毫秒级热替换，图标不闪、连接不断
• 三档择优预设：速度优先 / 均衡 / 省流量，一键切换算法性格
• 节点故障提醒：节点在使用中挂掉时收到通知，一键切换到最优替代（可选开启）

【协议与订阅】
• 支持 trojan / vmess / vless（含 REALITY）/ shadowsocks / hysteria2
• 订阅管理：标准订阅、SIP008、Clash YAML 导入，自动识别倍率标签
• 二维码 / 分享链接 / 剪贴板导入

【分流与洞察】
• 规则分流：域名 / IP / geo 规则，国内直连、国外代理，可自定义
• 广告与追踪拦截：内置广告 / 追踪域名规则，命中即拒——App 内弹窗广告、埋点更少，页面更清爽、更省流量
• 智能 QUIC 策略：自动为不同协议选择 HTTP/3 放行或回退，兼顾速度与兼容性
• 实时流量波形、代理 / 直连占比、连接列表、域名分析与规则建议（可按直连 / 代理 / 拒绝筛选）

【系统集成】
• 主屏 / 锁屏 / 控制中心小组件，实时显示隧道真实转发状态
• 快捷指令 + Siri、专注模式联动、实时活动（灵动岛）
• iCloud 同步配置（可选），多设备无缝
• 简体中文 / 繁體中文 / English / 日本語

【隐私承诺】
• 无账号体系、无遥测、无第三方 SDK
• 所有配置与统计数据只存在你的设备和你的 iCloud
• 流量分析全部在设备端完成

重要说明：轻舟是网络工具客户端，不提供任何 VPN 节点服务，需要你自备服务器或订阅。
```

### 描述（en）

```
Qingzhou is a VPN client that makes the most of YOUR nodes. It ships with no servers — import your subscription or share links, and let Qingzhou do the rest.

WHY QINGZHOU
• Multi-dimensional node scoring: latency, stability, bandwidth and cost are scored together to pick the node that is actually good — not just the lowest instant ping. Every pick comes with a transparent "why chosen" score breakdown
• Seamless switching: nodes are hot-swapped in milliseconds with zero downtime
• Three presets: Speed / Balanced / Data-saver — switch the algorithm's personality in one tap
• Node failure alerts: get notified when the current node dies mid-use and switch to the best alternative in one tap (opt-in)

PROTOCOLS & SUBSCRIPTIONS
• trojan / vmess / vless (incl. REALITY) / shadowsocks / hysteria2
• Subscriptions: standard, SIP008, Clash YAML import, automatic rate-multiplier parsing
• Import via QR code, share links, or clipboard

ROUTING & INSIGHTS
• Rule-based routing: domain / IP / geo rules, fully customizable
• Ad & tracker blocking: built-in ad / tracker domain rules — matched requests are rejected, so in-app pop-up ads and telemetry get cut for cleaner, lighter browsing
• Smart QUIC policy: automatically allows HTTP/3 or falls back per protocol, balancing speed and compatibility
• Live traffic waveform, proxy/direct split, connection list, domain analytics with rule suggestions (filterable by direct / proxy / reject)

SYSTEM INTEGRATION
• Home Screen / Lock Screen / Control Center widgets showing the tunnel's real forwarding state
• Shortcuts + Siri, Focus filters, Live Activities
• Optional iCloud sync across devices
• English / 简体中文 / 繁體中文 / 日本語

PRIVACY
• No accounts, no telemetry, no third-party SDKs
• Your configs and stats live only on your device and your iCloud
• All traffic analysis happens on-device

Note: Qingzhou is a client tool. It does not provide any VPN service — you need your own servers or subscription.
```

### 关键词（≤100 字符/语言，逗号分隔不加空格）

- zh-Hans：`vpn,代理,proxy,trojan,vmess,vless,shadowsocks,hysteria2,clash,订阅,分流,规则,去广告,测速`
- en：`vpn,proxy,trojan,vmess,vless,shadowsocks,hysteria2,clash,subscription,rules,xray,adblock`

### What's New（1.0）

- zh-Hans：`轻舟 1.0 首航。多协议支持、多维打分择优、零断流切换、规则分流、广告拦截、流量与域名分析、小组件全家桶。`
- en：`Maiden voyage. Multi-protocol support, smart node scoring, seamless switching, rule-based routing, ad blocking, traffic insights, and a full set of widgets.`

### App Review 备注（送审信息 → 备注栏）

```
This is a BYO (bring-your-own-server) VPN client built on the open-source xray-core.
- The app ships with NO servers and sells NO service. Users import their own subscription/nodes.
- No account system; no IAP; free app.
- Uses NEPacketTunnelProvider (Network Extension entitlement approved on this team).
- For review, use the test subscription below (a private test server we operate solely for review):
  [用户 TODO：提供一条稳定的测试订阅 URL 或 3 个测试节点分享链接]
- Steps: 添加订阅 → 选择节点 → 开启开关 → Safari 打开任意网页验证连通。
- Privacy: no data collected (matches App Privacy declaration).
```

### App Privacy / 其他

- App Privacy：**Data Not Collected**（无账号/无遥测/无三方 SDK，如实勾选）
- 年龄分级 4+；类目：工具 Utilities（副类目 生产力 可选）
- EU DSA：非交易商（首发不勾欧盟分发，已拍板）
- 隐私政策 URL：GitHub Pages 的 PRIVACY.md（**待部署**，用户侧 TODO）

---

## macOS（新记录待创建，「轻舟」名已被占）

- Bundle ID：`com.sbraveyoung.qingzhou.mac`
- **App 名称候选**（ASC 全球唯一，建议按序试）：
  1. `轻舟 VPN`（最直白，检索友好）
  2. `轻舟 Qingzhou`（双语并置，品牌一致）
  3. `轻舟·自航`（品牌向，需教育成本）
  4. `Qingzhou VPN`（纯英文兜底）
- 副标题/描述/关键词：**复用 iOS 文案**，另加一段 macOS 专属功能：

```
【macOS 专属】
• 打开指定 App 自动连接、全部退出自动断开
• 来源 App 标注：看清每条连接来自哪个应用（可选开启，系统扩展）
• 菜单栏 / 通知中心小组件
```

（en 对应：`MACOS EXTRAS: auto-connect when chosen apps launch; per-connection source-app attribution (opt-in, system extension); menu bar & Notification Center widgets`）

- 截图规格：16:10，2880×1800 或 2560×1600（**待截**，iOS v2 定稿后照做一套）

---

## 用户侧 TODO 清单（元数据相关）

1. 审核用测试订阅/节点（3 个稳定节点，审核期保活）→ 填进 Review 备注
2. PRIVACY.md 生效日期 + GitHub Pages 部署 → 得到隐私政策 URL
3. macOS ASC 记录创建（名字从候选里选）
4. Support URL（GitHub repo 或 Pages 均可）
