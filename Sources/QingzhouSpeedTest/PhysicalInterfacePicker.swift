import Foundation
import Network

/// 接口候选的纯值描述 —— `NWInterface` 无法在单测里构造，所以把「名字 + 类型」抽出来，
/// 让选择逻辑成为可单测的纯函数（输入列表 → 输出下标）。
public struct ProbeInterfaceCandidate: Sendable, Equatable {
    public let name: String
    public let type: NWInterface.InterfaceType

    public init(name: String, type: NWInterface.InterfaceType) {
        self.name = name
        self.type = type
    }
}

/// 从 `NWPath.availableInterfaces` 里挑「非 utun 的物理接口」，供节点延迟探针
/// 通过 `requiredInterface` 绑定 —— VPN 开启时也测真实直连 RTT，而不是绕节点一圈的假延迟。
///
/// ⚠️ 历史教训（LatencyProber.swift 注释里的原坑）：不能按类型一刀切禁 `.other`——
/// iPhone USB 网络共享等场景下**唯一物理网卡的类型也是 `.other`**，禁掉就全超时。
/// 所以这里是「反向主动绑定」：
/// 1. 优先选类型明确的物理口（.wifi / .cellular / .wiredEthernet），保持系统偏好序取第一个；
/// 2. 没有，再在 `.other` 里按**名字**排除已知虚拟接口（utun/ipsec/ppp/awdl/llw/…），取第一个幸存者；
/// 3. 还没有 → 返回 nil，调用方**回退到无绑定**（宁可测到假延迟，也不能全超时）。
public enum PhysicalInterfacePicker {
    /// 类型即物理的接口 —— 无需看名字。
    private static let explicitPhysicalTypes: Set<NWInterface.InterfaceType> = [
        .wifi, .cellular, .wiredEthernet,
    ]

    /// `.other` 里按名字前缀排除的已知虚拟/不可出公网接口：
    /// utun（VPN TUN）、ipsec（IKEv2 VPN）、ppp（拨号 VPN）、tun/tap（第三方虚拟网卡）、
    /// awdl（AirDrop）、llw（低延迟 WLAN，随 awdl 出现）、lo（环回）、bridge（虚拟机桥接）。
    private static let virtualNamePrefixes: [String] = [
        "utun", "ipsec", "ppp", "tun", "tap", "awdl", "llw", "lo", "bridge",
    ]

    /// 返回应绑定的候选下标；nil = 没有合适的物理接口，调用方应回退到无绑定连接。
    public static func pickIndex(_ candidates: [ProbeInterfaceCandidate]) -> Int? {
        // 第一优先：类型明确的物理口。availableInterfaces 本身是系统偏好序，取第一个即最优。
        if let idx = candidates.firstIndex(where: { explicitPhysicalTypes.contains($0.type) }) {
            return idx
        }
        // 第二优先：.other 里名字不像虚拟接口的（USB 共享场景的 enX 落在这里）。
        return candidates.firstIndex { candidate in
            guard candidate.type == .other else { return false }
            let name = candidate.name.lowercased()
            return !virtualNamePrefixes.contains { name.hasPrefix($0) }
        }
    }
}

/// 拿「当前应绑定的物理接口」的运行时封装：一次性 `NWPathMonitor` 快照 + 短 TTL 缓存。
///
/// 生命周期设计（避免常驻 monitor 的泄漏 / 回调循环引用）：
/// - monitor 只活在单次快照里：start → 收到第一次 path 更新（通常 <10ms）→ cancel，
///   不设常驻 handler，也就没有 handler 强持有 monitor 的环；
/// - 500ms 兜底超时，保证系统不回调时也不会挂住探针（返回 nil → 无绑定回退）；
/// - 3 秒 TTL 缓存 + in-flight 去重：NodeSelector 一轮测几百个节点（并发 8），
///   同一轮里只做 1~2 次快照，不会每个探针都起一个 monitor。
actor DirectInterfaceResolver {
    static let shared = DirectInterfaceResolver()

    private var cached: (interface: NWInterface?, at: ContinuousClock.Instant)?
    private var inFlight: Task<NWInterface?, Never>?
    private let ttl: Duration = .seconds(3)
    private let clock = ContinuousClock()

    /// 当前应绑定的物理接口；nil 表示找不到（调用方回退到无绑定）。
    func currentPhysicalInterface() async -> NWInterface? {
        if let cached, clock.now - cached.at < ttl {
            return cached.interface
        }
        if let inFlight {
            return await inFlight.value
        }
        let task = Task { await Self.snapshotAndPick() }
        inFlight = task
        let picked = await task.value
        cached = (picked, clock.now)
        inFlight = nil
        return picked
    }

    private static func snapshotAndPick() async -> NWInterface? {
        let interfaces = await snapshotInterfaces()
        let candidates = interfaces.map { ProbeInterfaceCandidate(name: $0.name, type: $0.type) }
        guard let idx = PhysicalInterfacePicker.pickIndex(candidates) else { return nil }
        return interfaces[idx]
    }

    /// 一次性 monitor 快照当前可用接口。跟 TCPConnectLatencyProber.tcpConnect 一样的
    /// Box 守双 resume 手法：首次 path 更新 / 超时兜底两路都可能 resume。
    private static func snapshotInterfaces(timeout: TimeInterval = 0.5) async -> [NWInterface] {
        final class Box: @unchecked Sendable { var done = false }
        let box = Box()
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "vpn.path-snapshot", qos: .userInitiated)

        return await withCheckedContinuation { (cont: CheckedContinuation<[NWInterface], Never>) in
            queue.asyncAfter(deadline: .now() + timeout) {
                guard !box.done else { return }
                box.done = true
                monitor.cancel()
                cont.resume(returning: [])
            }
            monitor.pathUpdateHandler = { path in
                guard !box.done else { return }
                box.done = true
                monitor.cancel()
                cont.resume(returning: path.availableInterfaces)
            }
            monitor.start(queue: queue)
        }
    }
}
