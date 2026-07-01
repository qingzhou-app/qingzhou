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
| 上架主体 | **个人开发者账号** | 一人独立开发 |

## 12 Sprint 路线图（每 sprint 2 周）

| Sprint | 周次 | 主题 | Definition of Done |
|---|---|---|---|
| **S0** | 已完成 | Foundation | 订阅 / 节点 / 规则 / UI / 测试 113 项 ✅ |
| **S1** | 已完成 | 内核集成 | libXray.xcframework 编通 → XrayCore 模块 → 3 项 XrayCore 测试通过 → macOS app 启动并 link libxray ✅ |
| **S2** | 代码完成 | Tunnel 接通 | PacketTunnelProvider 接 xray-core + xrayJSON 通过 `providerConfiguration` 传给 Extension + geo 文件内嵌 Extension Resources。无 App Group → 不弹「访问其他 App 数据」隐私警告。iOS + macOS + Tunnel.appex 都编通。**剩下：真机测一次** —— 见 [S2-TESTING.md](S2-TESTING.md) |
| **S3** | W5–6 | Node→Config | trojan/vmess/vless/ss 4 协议→xray JSON 转换器 + 30+ 单测 |
| **S4** | W7–8 | App Store 准备 | Privacy Policy / 应用信息 / 截图 / TestFlight 内测 1 周无 crash |
| **S5** | W9–10 | 🚀 **MVP 上架** | App Store 提交 → 通过审核 → 公开上架 |
| **S6** | W11–12 | macOS port | macOS 版本（共用 Tunnel 桥接代码） |
| **S7** | W13–14 | 体验差异化 | 自动测速 + 自动择优（用户最有感知的卖点） |
| **S8** | W15–16 | hysteria2 | ✅ 已提前完成：打包的 xray-core 自带 hysteria 传输，hy2 走原生 `Hysteria2Converter`（无需单独 lib） |
| **S9** | W17–18 | Widget + Shortcuts | iOS Widget 一键开关 + Apple Shortcuts |
| **S10** | W19–20 | Clash YAML | Clash / Mihomo 配置导入 |
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
- ❌ 自动测速 + 自动择优（S7）—— MVP 先纯手动
- ❌ macOS 系统代理 / 开机自启（macOS 没上 = 没意义）

## 每个 sprint 的关键技术任务

### S1：内核集成（你现在在这里）
- [ ] libXray repo clone + 摸清 gomobile bind 命令
- [ ] 装标准 Apple gomobile（卸 sagernet fork）
- [ ] gomobile bind → 产出 Frameworks/LibXray.xcframework
- [ ] Package.swift 加 binaryTarget + 新 module Sources/XrayCore/
- [ ] 写 XrayCore.swift：包装 LibXrayVersion()、LibXrayInit()
- [ ] 在 macOS app 里 print 出版本号，证明链入成功
- [ ] Apps/Tunnel-Shared/PacketTunnelProvider.swift 改：startTunnel 里调 LibXrayVersion()
- [ ] commit checkpoint

### S2：Tunnel 接通
- [ ] 设计 LibXrayPlatformInterface 接口（看 libXray 实际暴露什么）
- [ ] Apple NEPacketFlow ↔ Go TUN 文件描述符桥接
- [ ] 用一个**硬编码**的 trojan 节点 JSON 验证翻墙
- [ ] 实测：iPhone 真机 → 访问 google.com 成功
- [ ] 测试用例（虽然主要是 manual）

### S3：Node→Config 转换
- [ ] Sources/XrayConfig/ 模块
- [ ] TrojanConverter / VMessConverter / VLESSConverter / ShadowsocksConverter
- [ ] 每个 converter 至少 8 个单测（成功 + 各种字段缺失）
- [ ] AppState.startTunnel() 改成：拿当前节点 → converter → 写到 AppGroup → 启动 tunnel

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

## 当前状态 (S1 完成)

✅ **S1 内核集成完成 (2026-05-17)**：
- `Frameworks/LibXray.xcframework`（379MB，3 个 slice：iOS device / iOS sim / macOS）
- `Sources/XrayCore/XrayCore.swift` Swift 包装层（version / isRunning / setTunFd / run / stop / convertShareLinks / ping）
- 3 项 XrayCoreTests 全过：libXray dlopen 成功、`XrayVersion()` 返回真版本、`ConvertShareLinksToXrayJson()` 真翻 trojan 链接成 xray JSON
- macOS App 链入 XrayCore、启动无 crash、首页系统卡显示 xray-core 版本
- `scripts/build-libxray.sh` 一键重建脚本
- 已经发现并规避 gomobile + Xcode 26 的 maccatalyst 重复 framework 路径 bug

📊 **当前规模**：
- 5800+ 行 Swift 代码 + Sources/XrayCore
- **116 单测全过**（XrayCore 增加 3 项）
- iOS + macOS 双平台编译通过
- 订阅 / 节点 / 规则 / 测速 / 日志 / 持久化 / QR / IP 信息 / macOS 系统集成

✅ **Apple 准备**：
- 付费 Apple Developer 账号
- Network Extensions capability 自助启用
- 4 个 Bundle ID 注册
- App Group `group.com.sbraveyoung.vpn` 创建并绑定到 4 个 ID

🎯 **S2 代码已完成 (2026-05-17)** —— 详细测试步骤见 [S2-TESTING.md](S2-TESTING.md)。
- `Sources/XrayCore/TunnelAppGroup.swift`：主 App ↔ Extension 共享 xray JSON 的 helper
- `Apps/Tunnel-Shared/PacketTunnelProvider.swift`：真接 xray-core
  - `setTunnelNetworkSettings(IP=10.0.10.1/24, DNS=8.8.8.8/1.1.1.1, MTU=1500)`
  - 从 NEPacketTunnelFlow 通过 KVC 拿 `socket.fileDescriptor`
  - `XrayCore.setTunFd(fd)` + `XrayCore.run(configJSON: ..., geoDir: ..., mphCachePath: ...)`
- `Sources/VPNCore/NodeEncoder.swift`：Node → 分享链接字符串
- `Sources/VPNApp/AppState.startTunnel()`：Node → share link → xray JSON → AppGroup → 启动 Extension
- 验证：iOS + macOS + Tunnel.appex 都 BUILD SUCCEEDED，116 单测全过

⏭️ **真机调试在你那边**：见 [S2-TESTING.md](S2-TESTING.md) 一步步跑。跑通了进 S3。
