import Foundation
import Network

/// 物理出口接口监控器。
///
/// 中继自己的拨号绝不能走默认路由（分流模式下默认路由指向 TUN，会造成无限递归）。
/// 通过 `NWPathMonitor` 跟踪可用物理接口，并在回调与读取间加锁同步。
public final class PhysicalEgress: @unchecked Sendable {
    private let lock = NSLock()
    private var iface: NWInterface?
    private var logged = false
    private var monitor: NWPathMonitor?
    private let logger: RelayLogger?

    public init(logger: RelayLogger? = nil) {
        self.logger = logger
    }

    public func start() {
        lock.lock()
        if monitor != nil {
            lock.unlock()
            return
        }
        let m = NWPathMonitor()
        monitor = m
        lock.unlock()

        m.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let physical = path.availableInterfaces.first {
                $0.type == .wifi || $0.type == .wiredEthernet || $0.type == .cellular
            }
            self.lock.lock()
            let old = self.iface?.name
            self.iface = physical
            let first = !self.logged
            self.logged = true
            self.lock.unlock()

            if first {
                self.logger?.log("物理出口接口：\(physical?.name ?? "未知 —— 拿不到就拒绝拨号")")
            } else if old != physical?.name {
                self.logger?.log("物理出口接口切换：\(old ?? "?") → \(physical?.name ?? "?")（旧连接会断，新连接用新口）")
            }
        }
        m.start(queue: .global(qos: .utility))
    }

    public func stop() {
        lock.lock()
        let m = monitor
        monitor = nil
        lock.unlock()
        m?.cancel()
    }

    public func current() -> NWInterface? {
        lock.lock()
        defer { lock.unlock() }
        return iface
    }
}
