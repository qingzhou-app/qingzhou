# 架构

## 总览

代码按职责切成 7 个 Swift Package 库 + 1 个 SwiftUI UI 库：

```
┌─────────────────────────────────────────────────────────┐
│ App Targets (iOS / macOS — Xcode 项目里)                │
│   ├─ Packet Tunnel Provider Extension (阶段 2)          │
│   └─ Widget Extension (阶段 2)                          │
└────────────────────┬────────────────────────────────────┘
                     │ 依赖
┌────────────────────▼────────────────────────────────────┐
│ QingzhouApp  (SwiftUI 视图 + AppState 协调器)                │
└────┬────────┬────────┬─────────┬────────┬──────────┬────┘
     │        │        │         │        │          │
     ▼        ▼        ▼         ▼        ▼          ▼
┌────────┐┌─────────────┐┌─────────┐┌──────────┐┌─────────┐
│QingzhouCore ││QingzhouProtocols ││QingzhouRules ││VPNSpeed- ││VPNLog-  │
│模型    ││链接解析     ││引擎     ││Test 探针 ││ging     │
└────────┘└─────────────┘└─────────┘└──────────┘└─────────┘
              ▲
              │
        ┌─────┴───────┐
        │VPNSubscrip- │
        │tion 拉取    │
        └─────────────┘
```

依赖方向只能从上往下；同层之间不互相依赖。`QingzhouCore` 是唯一被所有模块引入的基础库。

## 各模块职责

### QingzhouCore
- **职责**：协议无关的领域模型 —— `Node`、`Subscription`、`Rule`、`Connection`、`Settings`。
- **不包含**：任何 IO、SwiftUI、协议解析逻辑。
- **重要类型**：
  - `Node`：节点身份指纹（`identityFingerprint`）用于订阅刷新去重 / 保留测速结果。
  - `Rule`：源文本形式由 `lineForm` 渲染，与 `RuleParser.parseLine` 是 round-trip。
  - `Subscription`：流量 / 到期由 `SubscriptionUserInfo` 在 QingzhouSubscription 写入。

### QingzhouProtocols
- **职责**：节点链接 ↔ `Node` 互转。
- 单一入口 `ProxyURLParser.parse(_:)`，按 URL scheme 分发到 `TrojanParser` / `ShadowsocksParser` / `VMessParser` / `VLESSParser` / `Hysteria2Parser`。
- Shadowsocks 同时支持 SIP002（user-info base64 + host:port）和 legacy（整段 base64）两种格式；
  base64 解码允许无 padding 和 URL-safe (`-_`)。
- VMess 解析鲁棒对待 port / aid 既可为 number 又可为 string 的现实。
- **Clash YAML 配置导入**：`ClashConfigParser` 通过 [Yams](https://github.com/jpsim/Yams) 解析 YAML，把 `proxies:` 和 `proxy-providers.*.payload:` 都映射成 `[Node]`；不支持的协议类型（snell / ssr / http / socks5...）静默跳过，不算错误。

### QingzhouSubscription
- **职责**：拉取订阅 → 解析为节点列表 + 流量元数据。
- `HTTPClient` 是 protocol，默认实现 `URLSessionHTTPClient`；单测里用 `MockHTTPClient` 避免真实出网。
- `SubscriptionParser` 是纯函数（无 IO），便于离线测试；`SubscriptionFetcher` 是 actor，把网络 + 解析 + 日志串起来。
- `SubscriptionUserInfo` 解析 `Subscription-Userinfo` 响应头，分隔符兼容 `;` 和 `,`，字段缺失时部分填充。

### QingzhouRules
- **职责**：规则源文本 → 结构化规则 → 匹配引擎。
- `CIDR.swift` 是自包含的 IPv4 / IPv6 CIDR 实现 —— 不调 `inet_pton`，便于 Linux 跨平台。
- IPv6 解析支持 `::` 缩写；不支持 IPv4-mapped 混合写法（这个在主流规则集里也罕见）。
- `GeoIPResolver` 是 protocol，生产环境注入 MaxMind / mmdb 实现；默认 `NoopGeoIPResolver` 让 GEOIP 规则永远不命中（不会误判）。
- 匹配按规则顺序遍历，命中即返回；没有 `FINAL` 时默认 `DIRECT`（保守策略，避免意外把所有流量推到代理）。

### QingzhouSpeedTest
- **职责**：URL 延迟探测 + 节点择优。
- `LatencyProber` 是 protocol，默认实现用 `URLSession.HEAD`。
- `SpeedTestRunner` 把多个目标并发跑（`withTaskGroup`），结果按传入顺序返回，便于 UI 渲染。
- `NodeSelector.measure` 用同样的探针测每个非排除节点的 host:port 连接耗时（不是端到端通过代理的速度 —— 后者要等阶段 2 接入 PacketTunnel 才能做）；`pickBest` 在结果里挑延迟最低的。

### QingzhouLogging
- **职责**：分级日志 + 环形缓冲 + 文件落盘 + 订阅事件。
- 用 `NSLock`，不用 actor。原因：日志器经常被同步上下文调用（包括未来的 PacketTunnel 包回调），让 `log()` 变 async 会传染整个调用链。
- 环形缓冲达到容量后丢最老 —— UI 展示用；归档要走文件 sink。
- 文件 sink 是简单 append-only，每行一条 ISO8601 时间戳 + level + category + message。

### QingzhouApp
- **职责**：SwiftUI 视图层 + `AppState` 协调器。
- `AppState` 用 `@Observable` 宏（iOS 17 / macOS 14 起的现代 Observation 框架）；`@MainActor` 标记，避免后台线程改 UI 状态。
- `TunnelSessionCoordinator`（build22）拥有实际配置、预期requestID/切换回执、被流量心跳否定的配置与启动时间下限。它是无IO的值类型，由`AppState`持有；界面选择仍在`AppState`，VPN系统操作仍由`VPNTunnelManager`执行。只满足系统连接态、时间下限、请求/回执及心跳证据的扩展会话才能被采认；停止清理确认状态，主App重开可采认仍在运行的会话。这是协调器拆分的第一步，异步启停、节点择优和云同步编排仍待后续迁移。
- 视图按业务划分：`HomeView` / `NodesView` / `SubscriptionsView` / `RulesView` / `ConnectionsView` / `LogsView` / `SettingsView`，外加 macOS 专属的 `StatusBarMenu`。
- 跨平台靠 `#if os(iOS)` / `#if os(macOS)`，主要分歧只在 `RootView`（iOS 用 TabView，macOS 用 NavigationSplitView）和 SettingsView 里的「系统代理」「开机自启」选项。

## 阶段划分

### 阶段 1 — 当前已完成
- 7 个核心库 + UI 骨架，全部跨平台编译通过；
- 73 项单测通过，覆盖所有有逻辑分支的路径。

### 阶段 2 — 真隧道（已代码完成，剩真机验证）
1. **集成 xray-core 作为协议核心（通过 libXray）**。使用预编译的 `Frameworks/LibXray.xcframework`（binary xcframework，无需自己 `gomobile bind`），新建 `XrayCore` 模块作为 Swift 与 Go 的胶水层（`Sources/XrayCore/`）。
   > 注：早期设计曾计划用 sing-box，最终采用 xray-core / libXray；本项目**不使用 sing-box**。
2. **Packet Tunnel Provider**。新建 `Network Extension` target；继承 `NEPacketTunnelProvider`；通过 App Group 共享配置文件和共享内存（连接列表）。
3. **主 App ↔ Extension 通信**。`NETunnelProviderManager` 启动隧道；自定义 control message（`sendProviderMessage`）实时拉取连接、流量、当前规则命中。
4. **macOS 系统代理 / 开机自启**。前者改 `networksetup -setwebproxy`；后者用 `SMAppService.mainApp` (macOS 13+)。
5. **Widget / 状态栏开关**。Widget 用 App Intents 直接 toggle `NETunnelProviderManager.isEnabled`；状态栏的 `StatusBarMenu` 已经预留接口。

### 阶段 3 — 完善
- 自定义规则可视化编辑（替代裸文本）；
- Clash / Mihomo / Shadowrocket / Surge 配置导入；
- iOS 端二维码扫描（`AVCaptureMetadataOutput`）；
- iCloud 同步订阅 / 节点；
- 国际化（zh-Hans / zh-Hant / en / ja 字符串资源）；
- 自动化 UI 测试（XCUITest）。

## 取舍记录

| 决策 | 理由 |
|---|---|
| 用 SPM 而非 CocoaPods/Carthage | iOS/macOS 现代标准，跨平台库自然支持 Linux 编译；和 Xcode 集成无缝。 |
| 用 XCTest 而非 Swift Testing | XCTest 在 SPM 下开箱可用，CI 兼容性最好。Swift Testing 计划在阶段 3 引入做 UI 测试。 |
| 唯一第三方依赖：Yams | 写一个能容错 YAML 1.1 的 parser 是个 weekend project，bug 多；Yams 是 SwiftLint 也在用的标准方案，BSD 协议，无 transitive deps。 |
| GEOIP 走 protocol 注入 | MaxMind DB 体积大且授权敏感，不放进库；UI 可选导入数据。 |
| 自实现 CIDR 而非用 `inet_pton` | 让核心库可以在 Linux 上编译（未来跑 CI 或服务端复用规则解析时方便）。 |
| 日志用 `NSLock` 而非 actor | 避免污染同步调用链。性能敏感路径不接受 await。 |
| `Node.id` 改成 `var` | 订阅刷新时同身份指纹的节点会沿用旧 id，让 SwiftUI 的 `ForEach` 不闪 + 保留测速结果。 |
| 不在 App 入口处理 NetworkExtension | NE 需要 entitlements，无法在 SPM 里编译；放进 App Target 后续单独处理。 |
| `Settings` 自定义 `init(from:)` 而不是用合成 | 用户从旧版本升级时 `state.json` 不会带新字段，自定义解码给每个新字段 fallback default，避免升级即丢配置。 |
| i18n：只接 Locale 不内置翻译 | Locale 切换立即生效（数字 / 日期 / 相对时间），但 UI 字符串翻译走 `Localizable.xcstrings` 社区贡献入口；项目自带繁中 / 英 / 日的完整翻译要花数百小时且我做不了原生 native 质量。 |
