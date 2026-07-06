# 轻舟 / Qingzhou — 关键约定（踩过的坑，别再踩）

iOS 17+ / macOS 14+ 的 VPN 客户端，基于 xray-core（经 libXray 的 Go binding）。
逻辑放 SPM 包（`Sources/`，`swift test` 可测），App / 扩展 target 放 Xcode 工程
（`Apps/`，XcodeGen 生成）。

## 构建 / 测试速查

```bash
./scripts/build-libxray.sh       # 首次必跑：构建 Frameworks/LibXray.xcframework（~10 分钟，
                                 # ~380MB，不入库）。没有它 XrayCore / Xcode 工程编不过
swift test                       # 纯 Swift 包（QingzhouCore/QingzhouApp/XrayConfig...），编不到 appex
swift test --filter XrayConfigTests           # 只跑一个测试 target
swift test --filter NodeConverterTests/testVMess  # 只跑单个用例
cd Apps && xcodegen generate     # 改了 project.yml / 加删源文件后重新生成工程
open Apps/Qingzhou.xcodeproj     # ⌘R 跑 Qingzhou-iOS（真机）或 Qingzhou-macOS
```

## ⚠️ 头号坑：改配置必须改 `project.yml`，不是改生成的文件

本项目用 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 管理工程，`Apps/project.yml` 是**权威源**。
每个 target 的 `entitlements.properties` 和 `info.properties` 会被 `xcodegen generate`
**每次都用来重新生成** `.entitlements` 和 `Info.plist` 文件。

**所以：直接改 `.entitlements` / `Info.plist` 文件，下一次 `xcodegen generate` 会把它覆盖掉，白改。**
要改这些，**改 `project.yml` 的 properties**。

反复踩过的实例（都浪费了很多轮才定位）：
- **App Group 每次 generate 后消失** → 因为只改了 4 个 `.entitlements` 文件，没写进 `project.yml` 的 `entitlements.properties`
- **Launch screen 配置丢失** → 只改了 `Info.plist`，没改 `project.yml` 的 `info.properties`

## 架构：两层结构 + 5 个 Xcode target

**SPM 包层**（`Sources/`，依赖只能自上而下，`QingzhouCore` 是唯一的公共底座）：

- `QingzhouCore` — 领域模型（`Node` / `Rule` / `Subscription` / `Connection` / `TrafficStats`），无 IO 无 UI
- `QingzhouProtocols` — 分享链接 ↔ `Node` 互转，入口 `ProxyURLParser.parse`；Clash YAML 导入（Yams，唯一第三方依赖）
- `QingzhouSubscription` / `QingzhouRules` / `QingzhouSpeedTest` / `QingzhouLogging` — 订阅拉取 / 规则引擎 / 测速 / 日志
- `QingzhouApp` — SwiftUI 视图 + `AppState`（`@Observable` + `@MainActor`）协调器，iOS/macOS 共用，靠 `#if os(...)` 分歧
- `XrayConfig` — `Node` → xray 完整配置 JSON（`XrayConfigComposer` + 各协议 Converter）。**纯 Swift、不依赖 LibXray**，所以主 App 和单测都能用
- `XrayCore` — LibXray.xcframework 的 Swift 胶水层，只有隧道扩展依赖它

**关键取舍：`QingzhouApp` 故意不依赖 `XrayCore`** —— xcframework 里 85MB Go runtime 会让
dyld 在 main() 前加载完，主 App 启动黑屏 1–3 秒。因此 share link → xray 配置的转换放在
扩展进程里做（`Apps/Tunnel-Shared/PacketTunnelProvider.swift`）。加新依赖时别破坏这个隔离。

**Xcode target 层**（`Apps/project.yml`）：

- `Qingzhou-iOS` / `Qingzhou-macOS` — 主 App，薄壳，UI 全在 QingzhouApp 包里
- `Qingzhou-Tunnel-iOS` / `Qingzhou-Tunnel-macOS` — packet tunnel appex，共享源码在 `Apps/Tunnel-Shared/`
- `Qingzhou-Filter-macOS` — **system extension**（不是 appex）形态的 content filter，只观测连接、
  给连接标注来源 App，不阻断。iOS 没有（需 MDM 监督）。激活坑全记录在 `project.yml` 该 target 的注释里
  （可执行名必须=bundle id、CFBundlePackageType=SYSX、用途说明主 App 和扩展都要写等）

主 App ↔ 隧道扩展的配置传递：`providerConfiguration["nodeJSON"]`（`VPNTunnelManager` → `PacketTunnelProvider`）。

## App Group —— appex ↔ 主 App 通信的地基

- id：`group.com.sbraveyoung.qingzhou`
- 配在 `project.yml` **4 个 target**（Qingzhou-iOS / Qingzhou-macOS / Qingzhou-Tunnel-iOS / Qingzhou-Tunnel-macOS）的 `entitlements.properties`
- 用途：流量统计（`traffic-stats.json`）+ xray access log 都靠它在扩展进程和主 App 之间共享
- **没配好 → 流量波形、连接列表、域名分析全部无数据**（appex 写不进、主 App 读不到，容器是 nil）
- Apple 后台还要：两个 App ID 都 **Edit/关联** 到这个 group，再刷新 provisioning profile
- 例外：**Filter-macOS 以 root 跑**，它的 App Group 容器和用户态主 App 不是同一个，
  来源 App 标注必须走 XPC（mach service `group.com.sbraveyoung.qingzhou.filter`），不能用共享文件

## appex 代码（`Apps/Tunnel-Shared/`）`swift build` 编不到

- `PacketTunnelProvider.swift` 等在 Xcode target 里，`swift build` / `swift test` **覆盖不到**，改了只能 Xcode 编
- **必须真机验证** —— VPN 扩展在模拟器跑不了
- ⌘R 跑 **Qingzhou-iOS** 会自动连带编译内嵌的 Qingzhou-Tunnel-iOS（`embed: true`），不用单独 build tunnel
- 装完要**关开一次 VPN**，运行中的旧扩展进程才会换成新代码
- Xcode 的 Swift 6 strict concurrency 比命令行严，容易在这里才暴露：闭包捕获可变变量、
  定时器和阻塞 read 循环共用一个串行队列被饿死（导致速率算错）等

## UI / 资源

- **Launch screen 用 `Apps/iOS/Resources/LaunchScreen.storyboard`**，别用 `Info.plist` 的
  `UILaunchScreen` dict —— 它的 `UIImageName` 会把图全屏拉伸，不可控。改了要删 app + 重启手机清缓存
- **toolbar 里别放 `NavigationLink`**（iOS 会渲染出双返回按钮），用 `.navigationDestination(isPresented:)`
- 图标：源在 `docs/icon/*.svg`，用 AppKit（`NSImage` 支持 SVG）渲染成各尺寸 asset PNG

## 数据来源（别再被示例数据坑）

真隧道数据都经 App Group 传：
- **流量统计**（波形 / 字节）：appex 在 TUN socketpair 层数字节 → `traffic-stats.json`
- **连接列表 / 域名分析**：xray `log.access` → access log 文件 → 主 App `AccessLogParser` 解析
- 早期的 `sampleConnectionsLoop` 示例数据（写死 google/baidu/github/...）**已删**

## 文档索引

架构细节 `docs/ARCHITECTURE.md`（含逐模块设计取舍表）、编译 / 签名 / 真机调试 `docs/BUILD.md`、
真机日志抓取 `docs/IOS-LOGS.md`、路线图 `docs/ROADMAP.md`、IPv6 设计边界（全链路 IPv4 的
取舍 / 调研 / 备用双栈方案，改 DNS/fakedns 前必读）`docs/IPV6.md`。
