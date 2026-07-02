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
        /// 扩展预检（testNode）明确判定配置非法 —— 与「预检本身没跑成」（超时/无会话）
        /// 区分开：前者应中止热切换保住在跑的隧道，后者尽力而为继续切。
        case configRejected(String)
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
            case .configRejected(let msg):
                return "节点配置预检未通过：\(msg)"
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
    ///
    /// `autoStopSeconds`：定时自动关闭（防忘关），秒，0 = 不启用。倒计时在扩展进程里生效
    /// —— iOS 主 App 随时会被系统回收，主 App 侧 Timer 靠不住。
    public func configure(
        node: Node,
        mode: ProxyMode,
        shareLink: String,
        rules: [Rule] = [],
        autoStopSeconds: TimeInterval = 0,
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
            "proxyMode": mode.rawValue,
            // 定时自动关闭（秒，0=不启用）。**始终写**（而不是 >0 才写）——
            // 覆盖掉上一次连接残留的旧值，否则关掉定时后旧配置还会到点断 VPN。
            "autoStopSeconds": autoStopSeconds
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
        //
        // ⚠️ 定时关闭（autoStopSeconds > 0）时**本次连接不开 On-Demand**：扩展到点
        // cancelTunnelWithError(nil) 自停后，扩展进程改不了主 App 的 manager 配置，
        // On-Demand 的 connect 规则会立刻把隧道拉回来 —— 定时就永远关不掉。
        // 代价（如实告知）：定时会话期间若扩展异常退出（崩溃 / 内存超限），系统不会自动重连，
        // 需要用户手动重开。定时本来就是「这段时间后我不要 VPN」，这个取舍成立。
        manager.isOnDemandEnabled = autoStopSeconds <= 0
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
        try await sendCommand(msg, timeoutSeconds: 5, timeoutLabel: "原地重配超时", failureLabel: "扩展重配失败")
    }

    /// 给**运行中**的扩展重设定时关闭（从现在起按新时长重新计时；0 = 取消定时）。
    /// 不重启隧道、不断流。失败（拿不到会话 / 超时）throws —— 调用方降级为「下次连接生效」。
    /// 注意：这只改扩展进程里的计时器；On-Demand 开关由调用方另行经 setOnDemandEnabled 落盘。
    public func setAutoStop(seconds: TimeInterval) async throws {
        try await sendCommand(
            ["command": "setAutoStop", "seconds": String(seconds)],
            timeoutSeconds: 3, timeoutLabel: "定时设置超时", failureLabel: "扩展定时设置失败"
        )
    }

    /// 「经代理延迟」：让**运行中**的扩展给指定节点起临时 xray 实例、真实走该节点测一次
    /// HTTP 延迟（扩展 handleAppMessage "pingNode"）。返回毫秒数。
    /// VPN 没开（拿不到会话）/ 扩展回错 / 超时都 throws —— 调用方降级为直连 TCP 测速。
    /// 超时给足 timeout+启动余量：临时实例启动 <1s + HTTP 最长 timeout 秒 + 串行排队缓冲。
    public func pingNode(node: Node, timeoutSeconds: Int = 5) async throws -> Int {
        let reply = try await sendCommandForReply(
            [
                "command": "pingNode",
                "nodeJSON": Self.encodeNodeJSON(node),
                "timeout": String(timeoutSeconds)
            ],
            timeoutSeconds: Double(timeoutSeconds) + 8,
            timeoutLabel: "经代理测速超时", failureLabel: "经代理测速失败"
        )
        guard let ms = (reply["delayMs"] as? NSNumber)?.intValue else {
            throw TunnelError.underlying(NSError(
                domain: "qingzhou.tunnel", code: -3,
                userInfo: [NSLocalizedDescriptionKey: "扩展回执缺少 delayMs"]))
        }
        return ms
    }

    /// 配置预检：让**运行中**的扩展用与真实连接同款的 compose+xray 构建流程校验节点配置
    /// （扩展 handleAppMessage "testNode"）。
    /// - 扩展明确回「配置非法」→ 抛 `TunnelError.configRejected(可读错误)`；
    /// - 预检本身没跑成（无会话 / 超时）→ 抛其他错误 —— 调用方应视为「无法预检」尽力继续。
    public func testNodeConfig(node: Node, mode: ProxyMode, shareLink: String, rules: [Rule] = []) async throws {
        var msg: [String: String] = [
            "command": "testNode",
            "nodeJSON": Self.encodeNodeJSON(node),
            "shareLink": shareLink,
            "proxyMode": mode.rawValue
        ]
        switch makeRulesPayload(rules) {
        case .inline(let gz):  msg["userRulesGZ"] = gz.base64EncodedString()
        case .file(let path):  msg["userRulesPath"] = path
        case .none:            break
        }
        let reply = try await sendCommandForReply(
            msg, timeoutSeconds: 8,
            timeoutLabel: "配置预检超时", failureLabel: "配置预检失败",
            rejectionAsConfigError: true
        )
        _ = reply
    }

    /// 系统记录的最近一次隧道断开原因（含扩展 startTunnel completionHandler 带回的错误）。
    /// 连接失败时主 App 靠它拿到可读错误文本 —— NE 不会把 start 失败直接回给 startVPNTunnel。
    public func lastDisconnectError() async -> String? {
        guard let conn = manager?.connection else { return nil }
        return await withCheckedContinuation { cont in
            conn.fetchLastDisconnectError { error in
                cont.resume(returning: error?.localizedDescription)
            }
        }
    }

    /// 向运行中的扩展发一条 JSON 命令并等回执。超时 / 回执 {ok:false} 都抛错。
    private func sendCommand(
        _ msg: [String: String],
        timeoutSeconds: Double,
        timeoutLabel: String,
        failureLabel: String
    ) async throws {
        _ = try await sendCommandForReply(
            msg, timeoutSeconds: timeoutSeconds,
            timeoutLabel: timeoutLabel, failureLabel: failureLabel
        )
    }

    /// 同 sendCommand，但把扩展回执解析成字典返回（无回执时空字典）。
    /// `rejectionAsConfigError`：{ok:false} 回执抛 `.configRejected`（预检语义），
    /// 否则抛 `.underlying`（一般命令失败语义）。
    @discardableResult
    private func sendCommandForReply(
        _ msg: [String: String],
        timeoutSeconds: Double,
        timeoutLabel: String,
        failureLabel: String,
        rejectionAsConfigError: Bool = false
    ) async throws -> [String: Any] {
        guard let session = manager?.connection as? NETunnelProviderSession else {
            throw TunnelError.managerNotLoaded
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
            // 扩展崩了 / 卡住不回执时的兜底：超时即当失败，让上层走降级路径。
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                once.run { cont.resume(throwing: TunnelError.underlying(
                    NSError(domain: "qingzhou.tunnel", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: timeoutLabel]))) }
            }
        }
        guard let reply,
              let obj = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
            return [:]
        }
        // 扩展回执：{ok: false, error: ...} 表示执行失败，抛错让上层降级。
        if obj["ok"] as? Bool == false {
            let message = (obj["error"] as? String) ?? failureLabel
            throw rejectionAsConfigError
                ? TunnelError.configRejected(message)
                : TunnelError.underlying(NSError(
                    domain: "qingzhou.tunnel", code: -2,
                    userInfo: [NSLocalizedDescriptionKey: message]))
        }
        return obj
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
