// macOS 内容过滤扩展（NEFilterDataProvider）—— 唯一目的：给每条连接标注「是哪个 App 发起的」。
//
// 为什么需要它：packet-tunnel 在 TUN 层只看到 IP 包，拿不到进程归属。content filter 的
// NEFilterFlow 能给出发起进程的 audit token，我们据此查出 bundle id。**只观测、一律放行**，
// 维护「源端口 → bundle id」映射，主 App 用 access log 里的源端口反查是哪个 App。
//
// IPC 用 **XPC 不用 App Group 文件**：本扩展是 system extension，以 root 运行，它的 App Group
// 容器（/var/root/...）和主 App（用户身份，~/Library/...）不是同一目录，共享文件互不可见。
// 所以出让一个 XPC 服务，主 App 连上来查 map。mach service 名在 Info.plist 的
// NetworkExtension.NEMachServiceName 声明，必须以 App Group 为前缀（沙箱 App 才能查找）。
//
// 注意 macOS 的 API 和 iOS 不同：来源 App 不能用 sourceAppIdentifier（macOS 不可用），
// 要用 sourceAppAuditToken + Security 框架的 SecCode 反查；端口用 localFlowEndpoint（Network 框架）。

import NetworkExtension
import Network
import Security
import os.log

final class FilterDataProvider: NEFilterDataProvider, NSXPCListenerDelegate, FilterControlProtocol {
    private let log = OSLog(subsystem: "com.sbraveyoung.qingzhou.filter", category: "Filter")

    private let portToApp = OSAllocatedUnfairLock(initialState: [String: String]())
    private var listener: NSXPCListener?

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        os_log("startFilter, vending XPC %{public}@", log: log, type: .default, FilterIPC.machServiceName)
        let l = NSXPCListener(machServiceName: FilterIPC.machServiceName)
        l.delegate = self
        l.resume()
        listener = l
        completionHandler(nil)
    }

    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        listener?.invalidate()
        listener = nil
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        if let socketFlow = flow as? NEFilterSocketFlow,
           let port = localPort(of: socketFlow),
           let bundleID = bundleID(fromAuditToken: flow.sourceAppAuditToken) {
            // 值 = 最近 ≤3 条 "bundleID\t<unix秒>" 记录（\n 分隔，新的在后）：主 App 按
            // 「端口 + 时间最近邻」认领 —— 保留多条是为了端口在窗口内被两个 App 先后
            // 复用时也能各认各的。解码侧在 QingzhouCore/SourceAppMap.swift，两侧格式
            // 必须同步改；无 \t 的旧格式主 App 仍认（纯端口匹配）。
            let entry = "\(bundleID)\t\(Int(Date().timeIntervalSince1970))"
            portToApp.withLock { map in
                var lines = map[port].map { $0.split(separator: "\n").map(String.init) } ?? []
                lines.append(entry)
                if lines.count > 3 { lines.removeFirst(lines.count - 3) }
                map[port] = lines.joined(separator: "\n")
            }
        }
        return .allow()                                       // 只观测，绝不阻断
    }

    // MARK: - XPC（主 App 来查端口→App 映射）

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: FilterControlProtocol.self)
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }

    func fetchPortMap(reply: @escaping ([String: String]) -> Void) {
        reply(portToApp.withLock { $0 })
    }

    // MARK: - 取端口 / 反查 bundle id

    /// 本地端点端口（App 建立连接时分配的源端口，与 access log 的 sourceAddress 端口一致）。
    /// localFlowEndpoint 需 macOS 15；macOS 14 拿不到端口 → 返回 nil，来源 App 标注在 14 上不生效。
    private func localPort(of flow: NEFilterSocketFlow) -> String? {
        guard #available(macOS 15.0, *) else { return nil }
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
}
