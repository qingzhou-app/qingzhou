import Foundation
import NetworkExtension
import VPNCore
import VPNLogging

/// 包装 `NETunnelProviderManager`，提供干净的启停 API。
///
/// 设计：
/// - **错误兜底**：没有 NE entitlement 时 `saveToPreferences` / `startVPNTunnel` 都会失败 ——
///   全部 throws，主 app 的 toggle 拿到错误显示给用户，不 crash；
/// - **状态推送**：通过 `statusStream` 把 NEVPNStatus 变化（disconnected → connecting → connected）
///   推给 UI，UI 用 AsyncStream 订阅；
/// - **MainActor**：所有读写都在主线程，避免 NEVPNManager 的 KVO 同步问题。
@MainActor
public final class VPNTunnelManager {

    public enum TunnelError: LocalizedError {
        case entitlementMissing
        case managerNotLoaded
        case noCurrentNode
        /// 系统拒绝了 VPN 配置写入（ad-hoc 签名 / 用户未授权 / Bundle ID 不符 entitlement）
        case configurationPermissionDenied
        case configurationStale
        case configurationDisabled
        case underlying(Error)

        public var errorDescription: String? {
            switch self {
            case .entitlementMissing:
                return "缺少 Network Extension entitlement —— provisioning profile 没带这个 capability，或者 app 是 ad-hoc 签名的（必须用 Apple Developer 真签）。"
            case .managerNotLoaded:
                return "VPN 配置未加载。"
            case .noCurrentNode:
                return "没选中节点。"
            case .configurationPermissionDenied:
                return """
                permission denied —— macOS 拒绝写入 VPN 配置。最常见原因：
                1. app 是 ad-hoc 签名（用 install.sh 装的）。改用 Xcode ⌘R 启动；
                2. 「系统设置 → 隐私与安全性」最下面有「VPN 配置已被阻止」红字，点「允许」；
                3. 你没在弹出的「允许 VPN 配置」密码框里输入 Mac 登录密码。
                """
            case .configurationStale:
                return "VPN 配置过期了。先在系统设置里把旧 VPN 删掉重试。"
            case .configurationDisabled:
                return "VPN 配置被禁用了（系统设置里 toggle 是关闭状态）。"
            case .underlying(let e):
                return e.localizedDescription
            }
        }
    }

    private let logger: Logger?
    private(set) public var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?

    // Extension 的 Bundle Identifier，必须和 project.yml 里 VPN-Tunnel-* target 的 PRODUCT_BUNDLE_IDENTIFIER 一致
    #if os(iOS)
    private let providerBundleId = "com.sbraveyoung.vpn.ios.tunnel"
    #else
    private let providerBundleId = "com.sbraveyoung.vpn.mac.tunnel"
    #endif

    public init(logger: Logger? = nil) {
        self.logger = logger
    }

    // 不在 deinit 里 removeObserver：Swift 6 严格并发禁止 nonisolated deinit 访问
    // 非 Sendable 属性。我们的 observer 闭包是 `[weak self]`，VPNTunnelManager 走的是
    // app 单例生命周期 —— deallocate 时机和 app 退出对齐，由系统回收即可。

    /// 从系统偏好里加载（或创建）VPN 配置。
    public func load() async throws {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            // 同一 providerBundleId 只保留一份；多了清理掉
            let mine = managers.filter {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerBundleId
            }
            self.manager = mine.first ?? NETunnelProviderManager()
            // 监听状态变化
            if let conn = manager?.connection {
                observer = NotificationCenter.default.addObserver(
                    forName: .NEVPNStatusDidChange,
                    object: conn,
                    queue: .main
                ) { [weak self] _ in
                    self?.logger?.info("Tunnel status: \(conn.status.description)", category: "tunnel")
                }
            }
        } catch {
            throw TunnelError.underlying(error)
        }
    }

    /// 把当前选中节点的配置写入 system preferences。
    ///
    /// 把 Node 本身（JSON 编码）+ share link 都塞进 providerConfiguration。Extension
    /// 优先用 Node 跑纯 Swift 的 NodeConverter（XrayConfig 模块），share link 作 fallback。
    /// 主 App 既不 link LibXray.xcframework 也不 link XrayConfig —— 启动时不会被任何额外
    /// 动态库拖慢。
    public func configure(
        node: Node,
        mode: ProxyMode,
        shareLink: String,
        description: String = "VPN"
    ) async throws {
        if manager == nil { try await load() }
        guard let manager = manager else { throw TunnelError.managerNotLoaded }

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = providerBundleId
        // serverAddress 只是给系统设置 UI 用的 display 字段，不参与真实连接
        proto.serverAddress = node.host

        // 把 Node 序列化成 JSON 字符串 —— providerConfiguration 是 plist 字典，不接受
        // 任意 Swift Codable。先 encode 到 Data 再转 String。
        let nodeJSON: String
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(node)
            nodeJSON = String(data: data, encoding: .utf8) ?? ""
        } catch {
            // 极少触发 —— Node 的字段都是基础类型。真出错就只走 shareLink 路。
            logger?.warn("encode node failed: \(error); falling back to shareLink only", category: "tunnel")
            nodeJSON = ""
        }

        // 把启动信息塞进 providerConfiguration —— 系统保存在 VPN preferences 里，
        // Extension 启动时通过 protocolConfiguration.providerConfiguration 读出来。
        // 不再需要 App Group 共享存储，因此不会触发「访问其他 App 数据」隐私弹窗。
        proto.providerConfiguration = [
            "nodeJSON": nodeJSON,
            "shareLink": shareLink,  // fallback 通道
            "nodeId": node.id.uuidString,
            "nodeName": node.name,
            "proxyMode": mode.rawValue
        ]

        manager.protocolConfiguration = proto
        manager.localizedDescription = description
        manager.isEnabled = true

        do {
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()  // 重读，否则 connection 是旧的
            logger?.info("Saved tunnel configuration: \(node.name)", category: "tunnel")
        } catch let error as NSError {
            throw Self.translate(error)
        }
    }

    /// 把系统抛的 NSError 翻译成更可定位的 TunnelError 枚举。
    private static func translate(_ error: NSError) -> TunnelError {
        // NEVPNErrorDomain: VPN 框架自身错误（很少见到）
        if error.domain == NEVPNErrorDomain {
            return .entitlementMissing
        }
        // NEConfigurationErrorDomain: 系统配置错误 —— permission denied 通常在这里
        if error.domain == "NEConfigurationErrorDomain" {
            switch error.code {
            case 1: return .configurationStale
            case 2: return .configurationDisabled
            case 5: return .configurationPermissionDenied
            default: return .underlying(error)
            }
        }
        // POSIX EACCES = 13
        if error.domain == NSPOSIXErrorDomain, error.code == 13 {
            return .configurationPermissionDenied
        }
        // localizedDescription 含 "permission denied" 也兜住
        if error.localizedDescription.lowercased().contains("permission denied") {
            return .configurationPermissionDenied
        }
        return .underlying(error)
    }

    public func start() async throws {
        if manager == nil { try await load() }
        guard let manager = manager else { throw TunnelError.managerNotLoaded }
        do {
            try manager.connection.startVPNTunnel()
            logger?.info("Tunnel start requested", category: "tunnel")
        } catch let error as NSError {
            throw Self.translate(error)
        }
    }

    public func stop() {
        manager?.connection.stopVPNTunnel()
        logger?.info("Tunnel stop requested", category: "tunnel")
    }

    public var status: NEVPNStatus { manager?.connection.status ?? .invalid }
}

extension NEVPNStatus {
    var description: String {
        switch self {
        case .invalid:       return "invalid"
        case .disconnected:  return "disconnected"
        case .connecting:    return "connecting"
        case .connected:     return "connected"
        case .reasserting:   return "reasserting"
        case .disconnecting: return "disconnecting"
        @unknown default:    return "unknown(\(rawValue))"
        }
    }
}
