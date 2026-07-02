import Foundation
@preconcurrency import NetworkExtension
import QingzhouCore
import QingzhouLogging

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
    private let providerBundleId = "com.sbraveyoung.qingzhou.ios.tunnel"
    #else
    private let providerBundleId = "com.sbraveyoung.qingzhou.mac.tunnel"
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
    ///
    /// `rules`：用户规则（自定义 + 远程，自定义在前），压缩后内联进 providerConfiguration；
    /// 超大规则集降级为写 App Group 文件传路径（见 makeRulesPayload）。
    public func configure(
        node: Node,
        mode: ProxyMode,
        shareLink: String,
        rules: [Rule] = [],
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
        var providerConfig: [String: Any] = [
            "nodeJSON": nodeJSON,
            "shareLink": shareLink,  // fallback 通道
            "nodeId": node.id.uuidString,
            "nodeName": node.name,
            "proxyMode": mode.rawValue
        ]
        // 用户规则：压缩内联（Data 是合法 plist 类型）；超大时写 App Group 文件传路径。
        switch makeRulesPayload(rules) {
        case .inline(let gz):  providerConfig["userRulesGZ"] = gz
        case .file(let path):  providerConfig["userRulesPath"] = path
        case .none:            break
        }
        proto.providerConfiguration = providerConfig

        manager.protocolConfiguration = proto
        manager.localizedDescription = description
        manager.isEnabled = true

        // On-Demand：让隧道在 App 被用户从后台划掉 / 进程被系统回收后，仍由系统独立保持并
        // 自动重连（NEPacketTunnelProvider 本就是独立进程，不该随主 App 生死）。
        // NEOnDemandRuleConnect 无 interfaceTypeMatch → 匹配所有网络（Wi-Fi / 蜂窝）。
        // ⚠️ 只在这里（=启动/连接路径）开启；用户主动关 VPN 时必须调 setOnDemandEnabled(false)
        // 并落盘，否则 On-Demand 会在 stop 后立刻把隧道拉回来，用户永远关不掉。
        manager.isOnDemandEnabled = true
        manager.onDemandRules = [NEOnDemandRuleConnect()]

        do {
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()  // 重读，否则 connection 是旧的
            logger?.info("Saved tunnel configuration: \(node.name)", category: "tunnel")
        } catch let error as NSError {
            throw Self.translate(error)
        }
    }

    /// 原地无感重配：给**运行中**的扩展发新配置，扩展只重启 xray（不重连 VPN、不动 TUN）。
    /// 用于切代理模式 / 切节点时避免整条隧道 stop→start 造成的断连。
    /// 失败（拿不到会话 / 扩展报错 / 超时）时 throws —— 调用方据此回退到全量重启。
    public func reconfigureInPlace(node: Node, mode: ProxyMode, shareLink: String, rules: [Rule] = []) async throws {
        guard let session = manager?.connection as? NETunnelProviderSession else {
            throw TunnelError.managerNotLoaded
        }
        var msg: [String: String] = [
            "command": "reconfigure",
            "nodeJSON": Self.encodeNodeJSON(node),
            "shareLink": shareLink,
            "nodeName": node.name,
            "proxyMode": mode.rawValue
        ]
        // 消息体是 JSON（[String: String]），二进制走 base64；超大规则集同样降级为文件路径
        switch makeRulesPayload(rules) {
        case .inline(let gz):  msg["userRulesGZ"] = gz.base64EncodedString()
        case .file(let path):  msg["userRulesPath"] = path
        case .none:            break
        }
        let data = try JSONSerialization.data(withJSONObject: msg)

        let reply: Data? = try await withCheckedThrowingContinuation { cont in
            let once = TunnelOnce()
            do {
                try session.sendProviderMessage(data) { replyData in
                    once.run { cont.resume(returning: replyData) }
                }
            } catch {
                once.run { cont.resume(throwing: error) }
                return
            }
            // 扩展崩了 / 卡住不回执时的兜底：超时即当失败，让上层回退到全量重启。
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                once.run { cont.resume(throwing: TunnelError.underlying(
                    NSError(domain: "qingzhou.tunnel", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "原地重配超时"]))) }
            }
        }
        // 扩展回执：{ok: false, error: ...} 表示重配失败（xray 没起来），抛错让上层回退。
        if let reply,
           let obj = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
           obj["ok"] as? Bool == false {
            throw TunnelError.underlying(NSError(
                domain: "qingzhou.tunnel", code: -2,
                userInfo: [NSLocalizedDescriptionKey: (obj["error"] as? String) ?? "扩展重配失败"]))
        }
    }

    // MARK: - 用户规则 payload

    private enum RulesPayload {
        case inline(Data)
        case file(String)
        case none
    }

    /// 压缩后 ≤ 该阈值直接内联。providerConfiguration 落 VPN preferences plist、
    /// sendProviderMessage 走 XPC，都不适合塞太大；200KB 压缩后 ≈ 数万条规则，日常远达不到。
    private static let inlineRulesLimit = 200 * 1024
    /// 超限降级写到 App Group 容器的文件名（主 App 写、隧道扩展读，同一容器）。
    private static let rulesFileName = "user-rules.gz"

    /// [Rule] → 传输 payload。编码失败 / 无处可写时返回 .none 并记日志 ——
    /// 规则传不过去只是分流退化为内置规则，绝不能阻断 VPN 启动。
    private func makeRulesPayload(_ rules: [Rule]) -> RulesPayload {
        guard !rules.isEmpty else { return .none }
        let gz: Data
        do {
            gz = try RulesTransport.encode(rules)
        } catch {
            logger?.warn("encode user rules failed: \(error) — tunnel will use built-in rules only", category: "tunnel")
            return .none
        }
        if gz.count <= Self.inlineRulesLimit {
            return .inline(gz)
        }
        // 超大规则集：写 App Group 文件传路径（扩展与主 App 共享同一容器）
        guard let url = AppGroupStorage.containerURL?.appendingPathComponent(Self.rulesFileName) else {
            logger?.warn("user rules too large (\(gz.count)B) and App Group unavailable — dropped", category: "tunnel")
            return .none
        }
        do {
            try gz.write(to: url, options: [.atomic])
            logger?.info("user rules payload \(gz.count)B exceeds inline limit — wrote to App Group file", category: "tunnel")
            return .file(url.path)
        } catch {
            logger?.warn("write user rules file failed: \(error) — dropped", category: "tunnel")
            return .none
        }
    }

    private static func encodeNodeJSON(_ node: Node) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(node)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
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

    /// 开 / 关 On-Demand 并落盘。
    ///
    /// **用户主动关 VPN 前必须先 `setOnDemandEnabled(false)`** —— 否则 On-Demand 的
    /// connect 规则会在 `stop()` 之后立刻把隧道重连回来，用户永远关不掉。
    /// 落盘（saveToPreferences）后重读，保持 connection 引用最新。
    public func setOnDemandEnabled(_ enabled: Bool) async throws {
        if manager == nil { try await load() }
        guard let manager = manager else { throw TunnelError.managerNotLoaded }
        manager.isOnDemandEnabled = enabled
        do {
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
            logger?.info("On-Demand \(enabled ? "enabled" : "disabled")", category: "tunnel")
        } catch let error as NSError {
            throw Self.translate(error)
        }
    }

    public var status: NEVPNStatus { manager?.connection.status ?? .invalid }
}

/// 保证回调只跑一次 —— sendProviderMessage 回执与超时兜底二者互斥、但用它防重复 resume。
private final class TunnelOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ block: () -> Void) {
        lock.lock(); let first = !done; done = true; lock.unlock()
        if first { block() }
    }
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
