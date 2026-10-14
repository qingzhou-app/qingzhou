import Foundation
import Network

/// 只观察系统路径是否变化，不采集 SSID / BSSID，不保存路径地址。
/// VPN 可能隐藏部分底层变化，因此这是保守的路径会话隔离，不是 Wi-Fi 身份识别。
@MainActor
final class MeasurementNetworkObserver {
    private var monitor: NWPathMonitor?
    private var previous: NWPath?
    private var generation = UUID()

    func start(onChange: @escaping @MainActor @Sendable () -> Void) {
        stop()
        let token = generation
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, self.monitor != nil else { return }
                guard self.previous != path else { return }
                self.previous = path
                onChange()
            }
        }
        monitor.start(queue: DispatchQueue(label: "qingzhou.measurement-network"))
    }

    func stop() {
        generation = UUID()
        monitor?.cancel()
        monitor = nil
        previous = nil
    }
}
