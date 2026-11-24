# 构建

## macOS覆盖安装后的扩展来源核验

同一bundle ID的旧App或DerivedData副本可能仍被系统选中。主App显示新版本，不代表Tunnel和Widget已经换新；典型症状是系统显示Connected，但首页一直确认实际连接，月度账本/内存文件停止更新。

```bash
pluginkit -m -A -D -v -i com.sbraveyoung.qingzhou.mac.tunnel
pluginkit -m -A -D -v -i com.sbraveyoung.qingzhou.mac.widget
ps -axo pid,comm | rg 'Qingzhou|VPN-Tunnel'
```

安装到`/Applications/Qingzhou.app`后，核对并记录每个同ID扩展路径。对确认属于旧构建的路径逐个执行`pluginkit -r "旧扩展绝对路径"`，仅撤销注册，不删除文件、配置或备份；不要处理其他产品的扩展。然后注册当前安装路径：

```bash
pluginkit -a /Applications/Qingzhou.app/Contents/PlugIns/Qingzhou-Tunnel-macOS.appex
pluginkit -a /Applications/Qingzhou.app/Contents/PlugIns/Qingzhou-Widget-macOS.appex
```

关开一次轻舟VPN，复核Tunnel进程来自安装目录，并检查实际配置回执和月度账本时间继续更新。再次构建或打开旧App可能重新注册副本，每次开发安装都应复核。2026-10-23实测清理14个旧注册后，3个进程均来自安装目录，账本与内存上报恢复；不要仅凭签名/安装成功宣称运行验收通过。

## 前置要求

| 工具 | 最低版本 | 备注 |
|---|---|---|
| macOS | 14.0 | 用于编译，跑 macOS 版 |
| Xcode | 16.0 | 提供 Swift 6 工具链 + iOS 17 / macOS 14 SDK |
| Swift | 6.0 | 包含在 Xcode 里 |

> 当前仓库由 Xcode 26.4.1 / Swift 6.3.1 验证通过。

## 编译核心库

```bash
swift build              # 默认 Debug
swift build -c release   # Release
```

输出在 `.build/<arch>-apple-macosx/<config>/`，每个库一个 `.swiftmodule` + `.o`。

## 跑测试

```bash
swift test               # 跑全部 73 个单测
swift test --filter QingzhouRulesTests          # 跑某个 target
swift test --parallel                      # 并行（默认就是并行）
```

## 跨平台编译

### 已安装 iPhone App 的交互验收

`Apps/DeviceAcceptance` 是独立 XCUITest 工程，按 bundle ID 打开手机上已安装的轻舟，不重新构建主 App 或替换配置。生成源为该目录的 `project.yml`。当前用例要求简体中文界面、已有本月流量记录；公网 IP 用例还要求 VPN 已连接，且测试线路的节点出口与物理出口不同。

系统验收包含真实网络操作：`testWiFiCellularRoundTrip` 要求初始Wi-Fi已连接，会切到蜂窝后恢复；`testLockScreenWidgetAndLiveActivityLifecycle` 要求已有锁屏矩形Widget、实时活动开启，会停止并重新连接VPN。仅做页面回归时使用 `-only-testing` 选择相应用例。临时系统界面探索与添加/移除控件脚本不纳入日常测试集，其执行成功不单独计功能通过。通知中心截图可能包含私人通知，应仅在本机检查与保存。

```bash
xcodegen generate --spec Apps/DeviceAcceptance/project.yml
xcodebuild -project Apps/DeviceAcceptance/QingzhouDeviceAcceptance.xcodeproj \
  -scheme QingzhouDeviceAcceptance -destination 'id=<设备 UDID>' \
  -derivedDataPath /private/tmp/qingzhou-device-acceptance \
  -resultBundlePath /private/tmp/qingzhou-device-acceptance.xcresult \
  -allowProvisioningUpdates -parallel-testing-enabled NO \
  -collect-test-diagnostics never test
```

结果路径每轮使用新目录。真机截图、界面树可能包含 IP、域名和节点信息，只保留本机，不提交到 Git。用例会重开主 App；VPN 扩展由系统独立管理。测试驱动安装成功或 `TEST BUILD SUCCEEDED` 不代表页面通过；若出现 `code 74 / IDE disconnection` 且尚未执行测试方法，应记录为测试通道阻塞、0 用例完成。2026-10-27 已在 iPhone 14 Pro 的 build36 上完成两条用例，0失败；具体证据见 `docs/ACCEPTANCE.md`。

若日志同时出现 `Results channel was never configured`，先核对有线连接、锁定状态和开发镜像，再检查 Mac CoreDevice 与手机 testmanagerd 的会话日志。本次仅重建 Mac 当前用户的 CoreDeviceService 后恢复，Mac VPN 保持开启也能完整通过。重建前必须核对进程所有者及可执行路径，只终止当前用户对应服务，随后确认新 PID 与设备连接状态；不要盲目杀全部同名服务或修改 VPN 路由。code74 本身不能证明 VPN、签名或轻舟业务代码存在问题。

### iOS（device + simulator）

```bash
xcodebuild -scheme Qingzhou-Package \
  -destination 'generic/platform=iOS' \
  -derivedDataPath .build/iOS-derived build

xcodebuild -scheme Qingzhou-Package \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/iOS-sim-derived build
```

### macOS

```bash
swift build              # 等价
```

### Linux（核心库部分）

`QingzhouCore` / `QingzhouProtocols` / `QingzhouSubscription` / `QingzhouRules` / `QingzhouSpeedTest` / `QingzhouLogging` 不依赖 SwiftUI 与 AppKit/UIKit，理论上能在 Linux 上编译（CI 用得到）。`QingzhouApp` 因为引入了 SwiftUI 不能在 Linux 上编译。

```bash
# 在 Linux 上需要修改 Package.swift，去掉 QingzhouApp target 和它的测试。
```

## 集成进 iOS / macOS App

仓库自带 `Apps/project.yml`，用 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 一条命令生成 `.xcodeproj`：

```bash
brew install xcodegen     # 一次性安装
cd Apps
xcodegen generate
open Qingzhou.xcodeproj        # iOS / macOS 两个 target 都在里面
```

Schemes：`Qingzhou-iOS`、`Qingzhou-macOS`。详细的真机调试 / 签名 / Bundle ID 修改步骤见 [../Apps/README.md](../Apps/README.md)。

## 启用真正的 VPN 隧道（阶段 2 工作）

### 4) 添加 Packet Tunnel Provider Extension

- `File → New → Target → Network Extension`
- Provider Type：`Packet Tunnel`
- 这会生成一个新 target（比如 `VPNTunnel`）和一个 `*.entitlements`。

### 5) 配置 entitlements

主 App target 和 Tunnel target 都要勾选以下 capabilities：

```
com.apple.developer.networking.networkextension = [packet-tunnel-provider]
com.apple.security.application-groups = ["group.com.you.vpn"]
```

> 个人开发者只能用 Personal VPN（`personal-vpn`），Packet Tunnel 需要企业账号或单独走 Apple 申请流程：
> <https://developer.apple.com/contact/request/networking-entitlement>

### 6) 集成 xray-core 作为协议核心（通过 libXray）

> 早期文档这里写的是 sing-box；实际项目采用 **xray-core**，通过 **libXray** 接入，**不使用 sing-box**。

项目直接使用预编译的 binary xcframework `Frameworks/LibXray.xcframework`（重建脚本 `scripts/build-libxray.sh`），
在 `Package.swift` 里以 `binaryTarget` 引入，`Sources/XrayCore/` 是 Swift 与 Go 的胶水层。
XcodeGen 生成的两个 Tunnel target 均已 link 它，无需手动拖入。

### 7) 在 PacketTunnelProvider 里桥接

```swift
import NetworkExtension
import QingzhouCore

final class PacketTunnelProvider: NEPacketTunnelProvider {
    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        // 1. 从 App Group 共享容器读取节点配置（xray JSON）+ 规则
        // 2. 用 XrayCore.setTunFd(fd) + XrayCore.run(configJSON:...) 起 xray-core
        // 3. 用 self.setTunnelNetworkSettings(...) 把虚拟接口配上
        // 4. NEPacketFlow ↔ Go TUN 文件描述符桥接，双向拷贝
    }
}
```

真正的桥接代码见 `Apps/Tunnel-Shared/PacketTunnelProvider.swift` 与 `Sources/XrayCore/`。

### 8) macOS 系统代理 + 开机自启

```swift
import ServiceManagement

// 开机自启（macOS 13+）
try SMAppService.mainApp.register()

// 系统代理：执行 networksetup 命令或用 SCDynamicStore API
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
task.arguments = ["-setwebproxy", "Wi-Fi", "127.0.0.1", "\(httpPort)"]
try task.run()
```

## 常见问题

### `dependency 'X' is not found`
- `swift package reset && swift package resolve`。

### iOS 模拟器跑不起来 Network Extension
- 真实的 Packet Tunnel **只能在真机上跑**，模拟器不会触发 VPN 框架。
- 模拟器里可以验证 UI 和所有非隧道功能。

### Xcode 抱怨 "Provisioning profile doesn't include packet-tunnel-provider"
- 去 Apple Developer 后台为对应 App ID 启用 Network Extensions capability。
- 个人账号只能用 Personal VPN（足够做 OpenVPN 类配置但不能写 PacketTunnel）。
