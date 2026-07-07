# Roadmap

> 这是 commercial App Store VPN 产品的 6 个月 part-time 路线图。MVP 目标是 W9-10 上架。

## 已锁定的决策（不再讨论）

| 维度 | 决策 | 理由 |
|---|---|---|
| License | **MIT** | App Store 兼容；不混入任何 GPL 代码 |
| 内核 | **xray-core**（MPL-2.0） | MPL 是 file-level copyleft，App Store 合规且免费 |
| 内核 binding | **libXray**（xtlsapi/libXray） | 专为移动端封装，省去自己 gomobile bind 大段调试 |
| MVP 协议 | **trojan / vmess / vless / ss** | xray-core 全部覆盖；hy2 后置 |
| 桥接代码 | **自写最小 PlatformInterface** | 不 vendor sing-box-for-apple（避免 GPL 污染） |
| MVP 平台 | **iOS only** | App Store 主战场；macOS S6 跟上 |
| 订阅 / 节点 / UI | **复用 phase 1.5+** | 已经做好，不重写 |
| 上架主体 | ~~个人开发者账号~~ → **组织版 Apple Developer 账号**（2026-07-03 注册完成） | Guideline 5.4 强制 VPN 类必须 Org；一人独立开发不变 |

## 12 Sprint 路线图（每 sprint 2 周）

| Sprint | 周次 | 主题 | Definition of Done |
|---|---|---|---|
| **S0** | 已完成 | Foundation | 订阅 / 节点 / 规则 / UI / 测试 113 项 ✅ |
| **S1** | 已完成 | 内核集成 | libXray.xcframework 编通 → XrayCore 模块 → 3 项 XrayCore 测试通过 → macOS app 启动并 link libxray ✅ |
| **S2** | 代码完成 | Tunnel 接通 | PacketTunnelProvider 接 xray-core + xrayJSON 通过 `providerConfiguration` 传给 Extension + geo 文件内嵌 Extension Resources。无 App Group → 不弹「访问其他 App 数据」隐私警告。iOS + macOS + Tunnel.appex 都编通。**剩下：真机测一次** —— 见 [S2-TESTING.md](S2-TESTING.md) |
| **S3** | 已完成 | Node→Config | ✅ trojan/vmess/vless/ss 4 协议→xray JSON 转换器 + 单测（VLESS+REALITY 也已支持） |
| **S4** | W7–8 | App Store 准备 | Privacy Policy / 应用信息 / 截图 / TestFlight 内测 1 周无 crash |
| **S5** | W9–10 | 🚀 **MVP 上架** | App Store 提交 → 通过审核 → 公开上架 |
| **S6** | 大部分已就位 | macOS port | macOS 版本（共用 Tunnel 桥接代码）已基本可用；macOS 系统扩展 / 内容过滤相关收尾中 |
| **S7** | 已完成 | 体验差异化 | ✅ 自动测速 + 自动择优（择优后 toast 提示）+ region prefer/exclude + 切模式自动重启隧道 |
| **S8** | 已完成 | hysteria2 | ✅ 原生 `Hysteria2Converter`（打包 xray-core 自带 hysteria 传输，无需单独 lib）。**v26.6.27 schema 完成**：端口跳跃 + salamander obfs + brutal 带宽/拥塞控制迁入 `finalmask.quicParams`；含 `XrayCore.testConfig` 真实配置预检集成测试 |
| **S9** | 进行中 | Widget + Shortcuts | Shortcuts / App-Intents 引擎已写好（`TunnelIntents.swift` + `AppLaunchWatcher.swift`）；**Widget 全家桶 + AppShortcutsProvider + GetVPNStatusIntent + macOS 自动连接线：并行实现中**（详见「当前状态」） |
| **S10** | 进行中 | Clash YAML | `ClashConfigParser` 已存在（trojan/vmess/vless/ss/hy2）；**剩下：vmess-snell/ssr/http/socks5 暂跳过** |
| **S11** | W21–22 | i18n + Polish | 简繁英日 + 暗色模式 + Onboarding |
| **S12** | W23–24 | v1.0 正式版 | 反馈修一遍，1.0 release |

## MVP 范围（S1–S5）—— 砍到见骨

**保留（必须有）**：
- 订阅 URL 添加 / 刷新（phase 1.5+ 已有）
- 单链接 trojan/vmess/vless/ss 添加
- 节点列表 + 简单延迟测试
- VPN 开关（真隧道）
- 规则代理模式 + 默认规则集
- 基础设置：端口、日志级别、主题

**砍掉（MVP 不做，等迭代）**：
- ✅ hysteria2 —— 已由原生 `Hysteria2Converter` 支持（提前于 S8 完成）
- ❌ macOS 版本（S6）
- ❌ Widget（S9）
- ❌ Apple Shortcuts（S9）
- ❌ Clash YAML 导入（S10）
- ❌ i18n（S11）—— 先简体中文一种
- ❌ QR 扫码（先粘贴链接就够）
- ❌ 自定义规则编辑器（先用默认规则集）
- ✅ 自动测速 + 自动择优（S7）—— 原计划 MVP 后做，现已完成
- ❌ macOS 系统代理 / 开机自启（macOS 没上 = 没意义）

## 每个 sprint 的关键技术任务

### S1：内核集成 ✅ 已完成
- [x] libXray repo clone + 摸清 gomobile bind 命令
- [x] 装标准 Apple gomobile（卸 sagernet fork）
- [x] gomobile bind → 产出 Frameworks/LibXray.xcframework
- [x] Package.swift 加 binaryTarget + 新 module Sources/XrayCore/
- [x] 写 XrayCore.swift：包装 LibXrayVersion()、LibXrayInit()
- [x] 在 macOS app 里 print 出版本号，证明链入成功
- [x] Apps/Tunnel-Shared/PacketTunnelProvider.swift 改：startTunnel 里调 LibXrayVersion()
- [x] commit checkpoint

### S2：Tunnel 接通（代码完成，剩真机测一次）
- [x] 设计 LibXrayPlatformInterface 接口（看 libXray 实际暴露什么）
- [x] Apple NEPacketFlow ↔ Go TUN 文件描述符桥接
- [x] 用一个**硬编码**的 trojan 节点 JSON 验证翻墙
- [ ] 实测：iPhone 真机 → 访问 google.com 成功 ← **S2 唯一未完成项**，见 [S2-TESTING.md](S2-TESTING.md)
- [x] 测试用例（虽然主要是 manual）

### S3：Node→Config 转换 ✅ 已完成
- [x] Sources/XrayConfig/ 模块
- [x] TrojanConverter / VMessConverter / VLESSConverter / ShadowsocksConverter（外加原生 Hysteria2Converter + VLESS+REALITY）
- [x] 每个 converter 单测（成功 + 各种字段缺失）
- [x] AppState.startTunnel() 改成：拿当前节点 → converter → 写到 AppGroup → 启动 tunnel

### S4：App Store 准备
- [ ] Privacy Policy 网页（GitHub Pages）
- [ ] App Store Connect：
  - [ ] Bundle ID 真实注册
  - [ ] App Privacy 详情填写
  - [ ] iPhone 6.7" / 6.5" / 5.5" 各 5 张截图
  - [ ] App 描述（中文）
  - [ ] 关键词
- [ ] TestFlight 内测组，5+ 名外部用户使用 1 周
- [ ] Crash-free 率 99%+

### S5：上架
- [ ] 提交审核（VPN apps Apple 会仔细审，准备解释材料：节点不预设、用户自带订阅、不绕过 App Store IAP 等）
- [ ] 等审核 + 处理 reject（VPN 类目首次提交常被 reject，准备 1-2 轮）
- [ ] 通过 → 上架
- [ ] 准备首批用户反馈渠道（GitHub Issues、Telegram、邮箱）

## 风险 & 缓解

| 风险 | 概率 | 影响 | 缓解 |
|---|---|---|---|
| libXray 在 iOS 上有 bug / 不维护 | 中 | 高 | 备选：自己 gomobile bind xray-core；再备选：自研 trojan client |
| App Store 拒审（VPN 类目敏感） | 高 | 中 | 准备好材料；引导用户自带订阅；不涉及任何中国敏感词 |
| Apple NE entitlement 等待 | 低 | 高 | 已经在路径 1 走通了（自助启用） |
| Personal Team 限制（无法 App Store 发布） | 低 | 高 | 你已经是付费 Apple Developer，不是问题 |
| Privacy Policy 起草 | 低 | 低 | 用模板（VPN apps 标准 Privacy Policy 框架） |
| 真机 Bug 调试慢（没 macOS 同步 build） | 中 | 中 | S2 之后保持每周至少 1 次真机回归 |

## 内核升级 (2026-07-07)

**xray-core v1.260327.0 → v26.6.27**（build 5，全量重测基线）。动因与逐条评估见
`xray-upgrade-eval.md`（会话产出）。关键：
- 收益：#6275 TUN 启动时序根因修复（我们崩溃循环的正修）、#5924/#5975 DomainMatcher/Geodata
  iOS 内存优化（直指 50MB 红线）、#6365 TUN nil panic 修复。
- libXray 同步升到 73bb811，遭遇上游 #132 Invoke API 大重构（逐函数导出 → 单一
  `Invoke(JSON)`，纯 JSON 信封，TunFd/geo 走 env，mph 缓存与 QueryStats 导出移除）。
  `XrayCore.swift` 整体迁移（对外 API 不变）；QueryStats 改 Foundation 原生 GET；
  mph 相关死代码已清。
- 本地补丁：fakedns nil 防护按新版重铺为瘦身版（根因上游已修，此为防御纵深，护 TUN
  之外的早查询路径）；SwitchOutbound wrapper 重写为新信封。构建脚本三处改造见脚本注释。
- **升级 xray-core/libXray 前必读**上面这段 + `xray-upgrade-eval.md`。

**节点择优算法**升到第 5 代多维打分（延迟/稳定性/带宽/成本四维锚点打分 + 分数黏性 +
burst 丢包率 + 经代理并入总分）。五代沿革见 `docs/NODE-SELECTION.md`，设计见 `docs/NODE-SCORING.md`。

## 当前状态 (2026-07-03)

**Sprint 进度**：S1 ✅ · S2 代码完成（真机翻墙日常在用，正式勾掉走 [ACCEPTANCE.md](ACCEPTANCE.md) §3）· S3 ✅ · S6 大部分已就位 · S7 ✅ · S8 ✅（提前）· S9 实现中（Widget 全家桶 + Shortcuts 全套并行开发）· S10 部分（ClashConfigParser 已存在）· **S11 英文 i18n 提前立项**（上国际区 App Store 需要，先做英文，简繁日照原计划）。剩下主线：S4/S5（App Store 上架，**组织账号已就位**）、S9 收尾、S11、S12 v1.0。

**⚠️ 待验收（统一清单见 [ACCEPTANCE.md](ACCEPTANCE.md)）**：2026-07-03 决策——组织账号已注册完成，
原「#11B 等 App Store 正式版再验收」策略**取消**，所有待验收项**现在就验收**（TestFlight / 开发版真机）。
涵盖：#11B 四项、流量波形 a1、S2 正式勾掉、iCloud 弹窗降噪、隧道状态采认，以及 Widget/Shortcuts 占位项。

**已完成并验证（206 单测全过）**：
- 协议转换器 trojan/vmess/vless/ss + hysteria2（原生 `Hysteria2Converter`）+ VLESS+REALITY
- 订阅添加 / 刷新；节点延迟测速；自动测速 + 自动择优（择优后 toast）；region prefer/exclude
- 切代理模式时自动重启隧道；刷新时清理悬空节点选中；首页双公网 IP 展示
- `LaunchScreen.storyboard`；iOS + macOS 静态「静海蓝」App 图标整套 asset

**本轮新完成（真隧道数据管道）**：
- **连接列表已改用真实数据**：走 xray `access.log`（旧的 `sampleConnectionsLoop` 已删）
- FakeDNS 反查：把 fake IP（198.18.x.x IPv4 + fc00::/18 IPv6）映射回域名
- 域名分析（聚合 + 每日摘要 + 规则建议）已在真实数据上工作

**#11B libXray 能力接入（2026-07-03）**：当时用户决定暂按通过、**已合 main**
（merge 1106005；合并后 526 单测全绿 + iOS/macOS 双平台编译通过，但四项功能都没在真机上人工验收过）。
四项 = **经代理延迟 / 配置预检 / 代理直连拆分 / 节点导出**。
验收策略已更新（2026-07-03）：不再等正式版，**立即用 TestFlight / 开发版真机验收**，
逐项步骤与验收要点（含扩展内存 footprint 别逼近 40MB 等）见 [ACCEPTANCE.md](ACCEPTANCE.md) §1。

**本轮新完成（已修复、待验收，见 [ACCEPTANCE.md](ACCEPTANCE.md) §4–§5）**：
- **iCloud 恢复弹窗降噪**（54aae48）：内容哈希一致时静默采认不弹窗；「暂不恢复」按云端 revision
  持久化；只有云端真有用户内容变化才再弹
- **启动时采认在跑的隧道**（e1f9df6）：主 App 被杀重开 / Xcode 替换安装后，开关与系统
  `NEVPNStatus` 对齐（显示开 + 时长正确），不再假显示「关闭」

**geo 数据闭环 ✅ 已全部完成（2026-07-03，从待办移入）**：
- **规则模式启动提速**：内置改为 v2fly `geoip-only-cn-private.dat`（224KB，
  `scripts/update-geoip.sh` 更新），非 cn/private 的用户 GEOIP 规则转换层跳过 + RulesView 提示
- **完整版 geo 下载已实现**（之前记的「待做」过时了）：`GeoDataManager.downloadFullGeoIP`——
  双源（主源 qingzhou-app/geo-data releases + 备源 v2fly 官方）+ sha256 校验不过**绝不落盘**；
  RulesView 已接一键下载 UI + GEOIP 三态提示（完整版就位 / 需下载 / 精简版说明）

**仍待办（真机 / target 层面）**：
- **无感换节点已实现，待真机验收**（2026-07-06）：libXray 本地扩展 `SwitchOutbound`
  （`scripts/patches/libxray/qingzhou_switch*.go`）在运行中的 xray 实例上热替换 "proxy"
  outbound handler —— 换节点不再 stop→start 整条隧道，零断流、图标不闪。主 App 走
  `performReapply` 的 nodeOnly 快路径（择优/手动选节点），失败自动回退全量重启；
  切模式/规则仍全量重启（低频）。**验收**：真机开 VPN 持续 ping → 择优/手动切节点
  → 图标不闪、丢包 0~秒级；日志页出现 "In-place switched outbound to …"；规则模式
  连续切 20 次无卡死。同批带上：择优黏性滞后（新最优须快 ≥50ms 且 ≥30% 才切）、
  切换窗口关 On-Demand、计划外断开诊断日志（区分「扩展死亡重启」vs「择优切换」）。
  旧的「恢复 reconfigureInPlace（整实例 stop→run）」降级为兜底方案，仅在想给模式/规则
  切换也做无感时再评估（fakedns Close 竞态崩溃已 backport 修复，可能就是当年卡死的根因之一）
- 流量波形（a1）真机验证一次 → 走 [ACCEPTANCE.md](ACCEPTANCE.md) §2
- S2 真机测试正式勾掉 → 走 [ACCEPTANCE.md](ACCEPTANCE.md) §3（日常已在用，确认即关闭）
- **S9 并行实现中**（实现完成后按 [ACCEPTANCE.md](ACCEPTANCE.md) §6 验收）：
  - Widget 全家桶：主屏 systemSmall 开关、iOS 锁屏 accessory、iOS 18 控制中心 ControlWidget、
    macOS 通知中心
  - AppShortcutsProvider（快捷指令拿来即用 + Siri 短语）
  - GetVPNStatusIntent（自动化条件分支）
  - macOS「打开指定 App 自动开 VPN / 全部退出自动关」（`AppLaunchWatcher` 接线 + 设置 UI）
- App Store 上架（见 [APP_STORE.md](APP_STORE.md) §10 step-by-step）——~~硬阻塞：组织账号~~
  ✅ **组织账号已注册完成（2026-07-03）**；剩：identifier 在新 org team 下重建、1024 图标导出、
  `PRIVACY.md` 生效日期填写 + GitHub Pages 部署、截图、TestFlight、审核测试节点准备

**机场兼容性审计（2026-07-05）—— 已全部收口**（P0/P1 已修：ss-2022 明文 userinfo、
Clash vless+reality 参数、一枝红杏 `:倍率` 格式）：
- ✅ **零节点可见错误**：`SubscriptionPayload.formatRecognized` 区分「空」vs「格式不识别」，
  AppState.refreshSubscription 据此 toast（891b649）
- ✅ **SIP008 (JSON) 订阅格式**：`SIP008Parser` + SubscriptionParser 分支识别 `servers` 数组（891b649）
- ✅ **hysteria2 salamander obfs**：已修（v26.6.27 schema，obfs 走 `finalmask.udp` salamander mask）
- ✅ **裸 UTF-8 fragment 兜底**：`ProxyURLParser.fragmentEncoded` 预编码 + malformedURL 重试。
  实测 iOS17+/macOS14+ 的 Foundation 已宽松到裸 emoji/中文 fragment 不返回 nil，此兜底主要保严格
  Foundation（Linux swift-corelibs）不丢节点；happy path 零行为变化
- ✅ **SSR / TUIC 协议**：评估结论 = xray-core v26.6.27 无二者出站实现（SSR=auth_chain/obfs 插件族、
  TUIC=QUIC 系 sing-box 专属），加 converter 是死代码，故**不加协议**，改为 `unsupportedProtocol(name:)`
  给清晰「暂不支持该协议」提示（非静默丢弃）

**排队立项（按优先级）**：
1. ✅ **英文 i18n**（2026-07-03 完成：Localizable/AppShortcuts/InfoPlist/Widget 全量目录，
   en 100%；语言选项只放简中/English，繁日暂缓）
2. ✅ **App 内自动化玩法引导页**（2026-07-03 完成：设置 → 自动化 → 自动化玩法指南）
3. **节点倍率（rate/multiplier）纳入择优**（用户 2026-07-04 提）：从节点名 / 订阅元数据
   解析倍率（如「2x」「0.5倍」），延迟接近时优先低倍率节点；解析出的倍率也在节点列表展示。
   需改 Node 模型（Codable 迁移）+ 解析器 + 择优 tiebreaker + iCloud normalizer + 宣发文案
4. **App 内更新提醒**（用户 2026-07-04 提）：iTunes lookup API 查 App Store 最新版本号，
   高于当前则提示。轻量、无需服务端
5. **端侧 AI 动态规则决策表**（用户 2026-07-04 提，长期）：端侧 AI 可用后，
   用 AI 根据域名访问情况 / 耗时情况**动态维护一条决策表**，自动决定每个域名走哪条规则
   （代理 / 直连 / 哪个出口）。现有域名分析 + 规则命中统计已经是它的数据底座
6. **国内社交平台隐秘分享 / 裂变**（用户 2026-07-04 提，需产品决策）：邀请码 / 去敏感化落地页 /
   口令分享等，规避国内平台对 VPN 类内容的审查。方案待定
7. **Clash 导入扩展**：现支持 trojan/ss/vmess/vless/hysteria2，补 http/socks5/ssr/snell 等；
   顺带做其他客户端迁移导入
8. **Live Activity**（灵动岛 / 锁屏实时活动显示连接状态与流量）
9. **Focus 联动**（专注模式切换联动 VPN 开关）
10. **繁体中文 / 日语本地化**（结构就绪，补翻译即可）

**来源 App 标注（macOS 内容过滤 + XPC）**：**已启用**——代码里 `FeatureFlags.sourceAppLabeling = true`
（此前文档写「已由 flag=false 搁置」有误，实际是 **opt-in**：设置 → macOS 集成一键启用 +
批准引导，不启用不打扰）。遗留 TODO 保留：关联键升级为**端口 + 时间窗**，进一步消除端口复用误标
（见 `FeatureFlags.swift` 注释）。

---

### S1 内核集成回顾 (2026-05-17)：
- `Frameworks/LibXray.xcframework`（379MB，3 个 slice：iOS device / iOS sim / macOS）
- `Sources/XrayCore/XrayCore.swift` Swift 包装层（version / isRunning / setTunFd / run / stop / convertShareLinks / ping）
- 3 项 XrayCoreTests 全过：libXray dlopen 成功、`XrayVersion()` 返回真版本、`ConvertShareLinksToXrayJson()` 真翻 trojan 链接成 xray JSON
- macOS App 链入 XrayCore、启动无 crash、首页系统卡显示 xray-core 版本
- `scripts/build-libxray.sh` 一键重建脚本
- 已经发现并规避 gomobile + Xcode 26 的 maccatalyst 重复 framework 路径 bug

📊 **当前规模**：
- Sources/XrayCore + Sources/XrayConfig 等多模块
- **206 单测全过**（当前）
- iOS + macOS 双平台编译通过
- 订阅 / 节点 / 规则 / 测速 / 日志 / 持久化 / QR / IP 信息 / macOS 系统集成

✅ **Apple 准备**：
- 付费 Apple Developer 账号
- Network Extensions capability 自助启用
- 4 个 Bundle ID 注册
- App Group `group.com.sbraveyoung.qingzhou` 创建并绑定到 4 个 ID

🎯 **S2 代码已完成 (2026-05-17)** —— 详细测试步骤见 [S2-TESTING.md](S2-TESTING.md)。
- `Sources/XrayCore/TunnelAppGroup.swift`：主 App ↔ Extension 共享 xray JSON 的 helper
- `Apps/Tunnel-Shared/PacketTunnelProvider.swift`：真接 xray-core
  - `setTunnelNetworkSettings(IP=10.0.10.1/24, DNS=8.8.8.8/1.1.1.1, MTU=1500)`
  - 从 NEPacketTunnelFlow 通过 KVC 拿 `socket.fileDescriptor`
  - `XrayCore.setTunFd(fd)` + `XrayCore.run(configJSON: ..., geoDir: ..., mphCachePath: ...)`
- `Sources/QingzhouCore/NodeEncoder.swift`：Node → 分享链接字符串
- `Sources/QingzhouApp/AppState.startTunnel()`：Node → share link → xray JSON → AppGroup → 启动 Extension
- 验证：iOS + macOS + Tunnel.appex 都 BUILD SUCCEEDED，206 单测全过

⏭️ **真机调试在你那边**：见 [S2-TESTING.md](S2-TESTING.md) 一步步跑。跑通了进 S3。
