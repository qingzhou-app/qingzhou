// macOS 内容过滤扩展（NEFilterDataProvider）—— 唯一目的：给每条连接标注「是哪个 App 发起的」。
//
// 为什么需要它：packet-tunnel 在 TUN 层只看到 IP 包，拿不到进程归属。content filter 的
// NEFilterFlow 能给出发起进程的 audit token，我们据此查出 bundle id。**只观测、一律放行**，
// 把「源端口 → bundle id」写进 App Group；主 App 用 access log 里的源端口反查是哪个 App。
//
// 注意 macOS 的 API 和 iOS 不同：来源 App 不能用 sourceAppIdentifier（macOS 不可用），
// 要用 sourceAppAuditToken + Security 框架的 SecCode 反查；端口用 localFlowEndpoint（Network 框架）。

import NetworkExtension
import Network
import Security
import os.log

final class FilterDataProvider: NEFilterDataProvider {
    private let log = OSLog(subsystem: "com.sbraveyoung.qingzhou.filter", category: "Filter")

    private let portToApp = OSAllocatedUnfairLock(initialState: [String: String]())
    private var flushTimer: DispatchSourceTimer?
    private let flushQueue = DispatchQueue(label: "com.sbraveyoung.qingzhou.filter.flush")

    private static let groupID = "group.com.sbraveyoung.qingzhou"
    private static var mapURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent("source-apps.json")
    }

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        os_log("startFilter", log: log, type: .default)
        let timer = DispatchSource.makeTimerSource(queue: flushQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.flush() }
        timer.resume()
        flushTimer = timer
        completionHandler(nil)
    }

    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        flushTimer?.cancel()
        flushTimer = nil
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        if let socketFlow = flow as? NEFilterSocketFlow,
           let port = localPort(of: socketFlow),
           let bundleID = bundleID(fromAuditToken: flow.sourceAppAuditToken) {
            portToApp.withLock { $0[port] = bundleID }
        }
        return .allow()                                       // 只观测，绝不阻断
    }

    /// 本地端点端口（App 建立连接时分配的源端口，与 access log 的 sourceAddress 端口一致）。
    private func localPort(of flow: NEFilterSocketFlow) -> String? {
        guard let ep = flow.localFlowEndpoint, case let .hostPort(_, port) = ep else { return nil }
        return "\(port.rawValue)"
    }

    /// 从 audit token 反查发起进程的签名标识（App Store app 里就等于 bundle id）。
    private func bundleID(fromAuditToken token: Data?) -> String? {
        guard let token else { return nil }
        var code: SecCode?
        let attrs = [kSecGuestAttributeAudit: token] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoIdentifier as String] as? String
    }

    private func flush() {
        let map = portToApp.withLock { $0 }
        guard !map.isEmpty, let url = Self.mapURL,
              let data = try? JSONEncoder().encode(map) else { return }
        try? data.write(to: url, options: [.atomic])
    }
}
