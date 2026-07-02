#if os(macOS)
import Foundation
import QingzhouCore
import os.log

/// 主 App 侧 XPC 客户端：向内容过滤系统扩展查询「源端口 → bundle id」。
/// 见 QingzhouCore/FilterIPC.swift 说明 —— 扩展以 root 跑，App Group 文件不通，故走 XPC。
final class FilterControlClient: @unchecked Sendable {
    private let log = OSLog(subsystem: "com.sbraveyoung.qingzhou.app", category: "FilterXPC")
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    /// 拿到（必要时新建）到扩展的连接。连接失效时自动置空，下次重建。
    private func currentConnection() -> NSXPCConnection {
        lock.lock(); defer { lock.unlock() }
        if let c = connection { return c }
        let c = NSXPCConnection(machServiceName: FilterIPC.machServiceName, options: [])
        c.remoteObjectInterface = NSXPCInterface(with: FilterControlProtocol.self)
        c.invalidationHandler = { [weak self] in self?.reset() }
        c.interruptionHandler = { [weak self] in self?.reset() }
        c.resume()
        connection = c
        return c
    }

    private func reset() {
        lock.lock(); connection = nil; lock.unlock()
    }

    /// 查询当前端口→App 映射。扩展没装 / 没启用 / 连不上时返回 nil（静默降级，不打扰用户）。
    func fetchPortMap() async -> [String: String]? {
        let conn = currentConnection()
        let log = self.log
        return await withCheckedContinuation { (cont: CheckedContinuation<[String: String]?, Never>) in
            let once = Once()
            let proxy = conn.remoteObjectProxyWithErrorHandler { err in
                os_log("XPC error: %{public}@", log: log, type: .error, "\(err)")
                once.run { cont.resume(returning: nil) }
            } as? FilterControlProtocol
            guard let proxy else {
                os_log("XPC proxy nil", log: log, type: .error)
                once.run { cont.resume(returning: nil) }; return
            }
            proxy.fetchPortMap { map in
                once.run { cont.resume(returning: map) }
            }
            // 超时兜底：filter 扩展没在跑时 errorHandler 不一定触发（launchd 按需拉起失败
            // 的语义不可依赖），reply 可能永远不来。2 秒没回就当 nil，Once 防重入。
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                once.run { cont.resume(returning: nil) }
            }
        }
    }
}

/// 保证回调只跑一次 —— XPC 的 errorHandler 与 reply 互斥触发，但用它兜底防重入 resume。
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ block: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { block() }
    }
}
#endif
