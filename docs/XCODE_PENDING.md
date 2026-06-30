# Xcode / 真机待办（攒批统一验证）

> 这几轮在命令行把**能编译验证的都做了**（188 测试全过）。下面是必须在 Xcode build +
> 真机才能验证/完成的部分，攒成一批一起做。每项都标了已写好的代码位置和验证步骤。

---

## 1. a1 — 真实流量波形（代码已写，待真机验证）

**已写**：
- `Apps/Tunnel-Shared/PacketTunnelProvider.swift` — 两个 socketpair 拷贝循环按 unfair-lock 数字节，`DispatchSource` 定时器每秒算 delta 速率 → `TunnelAppGroup.writeTrafficStats`。
- `Sources/XrayCore/TunnelAppGroup.swift` — `writeTrafficStats(_:)`。
- `Sources/VPNApp/AppState.swift` — `trafficPollingLoop` 每秒读 App Group，新鲜样本(≤3s)接管波形。

**验证**：Xcode build `VPN-Tunnel-*` target → 真机连节点 → 首页「流量统计」波形应显示**真实**上下行速率（之前是采样驱动）。

**前提**：App Group entitlement `group.com.sbraveyoung.qingzhou` 两个 target 都要配（主 App + Tunnel）。

---

## 2. 连接列表真实数据（access log 管道，待实现 + 验证）

解析器 `AccessLogParser`（`Sources/VPNCore/`，8 测试）和 `DomainAnalyzer`（域名分析，9 测试）都就绪，**只差把真实 access log 喂进来**：

- [ ] `XrayConfigComposer.compose` 的 `log` 段加 `"access": <App Group 路径>`（现在只有 `loglevel`）。建议给 compose 加一个可选 `accessLogPath` 参数。**可编译。**
- [ ] appex `bringUpXray` 里把 App Group 的 access.log 路径传进 compose。**appex，需真机。**
- [ ] 主 App 轮询读该文件 → `AccessLogParser.parse` → 更新 `AppState.connections`（替换 `sampleConnectionsLoop`）。**可编译。**

接通后：连接页 + 域名分析自动吃真实数据，无需改它们。

---

## 3. c — Widget target + 接线（需 Xcode 新 target）

**已写好引擎**（编译通过）：
- `Sources/VPNApp/TunnelIntents.swift` — `Start/Stop/ToggleVPNIntent` + `QingzhouAppShortcuts`。
- `Sources/VPNApp/AppLaunchWatcher.swift` — macOS 开 App 自动连。
- `Sources/VPNCore/Settings.swift` — `autoConnectOnAppLaunch` + `autoConnectApps`。

**待做**：
- [ ] **App Intents 验证**：Xcode build 后打开「快捷指令」app，应能看到「开启/关闭/切换轻舟」，Siri 也能调。若 `AppShortcutsProvider` 没被扫描到，把 `QingzhouAppShortcuts` 在 app target 里再 `typealias` 暴露一次。
- [ ] **iOS 开 App 自动连**：用户在 快捷指令 → 自动化 → App → 已打开/已关闭 → 运行 `StartVPNIntent`/`StopVPNIntent` + 勾「立即运行」。写进用户文档即可，无需改代码。
- [ ] **Widget target**：`project.yml` 加 widget extension（见下），Widget 用 `Button(intent: ToggleVPNIntent())` 做交互开关 + 状态显示。
- [ ] **macOS 接线**：`VPNMacApp` 持有 `AppLaunchWatcher`，按 `settings.autoConnectOnAppLaunch/autoConnectApps` 启停（见下片段）。
- [ ] **自动连设置 UI**：macOS 设置页加「打开这些 App 时自动连」+ `NSOpenPanel` 选 .app 拿 bundle id。可在 `Sources/VPNApp/SettingsView.swift` 做，**可编译**。

### project.yml — widget target 片段（参考）
```yaml
  VPN-Widget-iOS:
    type: app-extension
    platform: iOS
    sources: [Apps/Widget]
    dependencies:
      - target: VPNApp
    settings:
      PRODUCT_BUNDLE_IDENTIFIER: com.sbraveyoung.qingzhou.ios.widget
    info:
      path: Apps/Widget/Info.plist
      properties:
        NSExtension:
          NSExtensionPointIdentifier: com.apple.widgetkit-extension
```

### VPNMacApp 接线 AppLaunchWatcher（参考）
```swift
#if os(macOS)
let watcher = AppLaunchWatcher(
    onActivate:   { Task { try? await appState.tunnelManager.load(); try? await appState.tunnelManager.start() } },
    onDeactivate: { appState.tunnelManager.stop() }
)
// 在设置变化时：
if appState.settings.autoConnectOnAppLaunch {
    watcher.start(triggers: appState.settings.autoConnectApps)
} else { watcher.stop() }
#endif
```

---

## 命令行已完成（无需 Xcode，已 commit + 测试）

- hy2 不通修复、订阅清理悬空选中、切模式自动重启、连接来源展示
- (a) 流量地基 `TrafficStats`/`TrafficHistory`、access log 解析器、波形图 UI、appex 字节上报
- (b) 静海蓝图标整套 asset
- (c) App Intents + macOS 自动连监听 + 配置字段
- (E) 域名分析引擎（聚合/每日/建议）+ 三视图 UI
