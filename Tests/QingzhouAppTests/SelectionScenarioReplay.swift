import Foundation
import QingzhouCore
import QingzhouSpeedTest
@testable import QingzhouApp

/// 测试侧事件回放：真实App编排 + 注入的时钟/探针/VPN应用记录器。无网络、无系统VPN操作。
/// 输入只含符号ID和观测，不能传入真实节点地址/凭据；不打包进App。
@MainActor
enum SelectionScenarioReplay {
    struct Spec: Codable, Sendable {
        var id: String
        var udp: Bool? = nil
        var aliasOf: String? = nil
        var rate: Double? = nil
        var excluded: Bool? = nil
    }
    struct Probe: Codable, Sendable, Equatable {
        var ms: Int? = nil
        var failure: String? = nil
        static func success(_ ms: Int) -> Self { .init(ms: ms) }
        static let failed = Self(failure: "probeFailed")
    }
    struct Frame: Codable, Sendable {
        var at: Double
        var directMs: [String: Int]? = nil
        var directFailures: [String]? = nil
        var primary: [String: Probe]? = nil
        var backup: [String: Probe]? = nil
        var primaryDefault: Probe? = nil
        var backupDefault: Probe? = nil
        var networkChanged: Bool? = nil
        var changeNetworkDuringProxy: Bool? = nil
        var manual: Bool? = nil
        var vpnRunning: Bool? = nil
        /// 仅用于评估，绝不提供给策略。nil=未知，[]=所有出口不可用。
        var available: [String]? = nil
        /// 场景作者给定的可接受选择集，缺失时不推断哪次切换是错误的。
        var acceptable: [String]? = nil
        var outageStartedAt: Double? = nil
    }
    struct Scenario: Codable, Sendable {
        var name: String
        var nodes: [Spec]
        var initialChoice: String?
        var frames: [Frame]
    }
    struct Detail: Codable, Equatable {
        var at: Double
        var selected: String?
        var reason: String
        var directRequests: Int
        var directIdentities: Int
        var directReused: Int
        var directDeferred: Int
        var proxyRequests: Int
        var confirmations: Int
        var cooldownCount: Int
        var cooling: [String]
        var usedBackup: Bool
        var proxyNodes: [String]
    }
    struct Report: Codable, Equatable {
        var name: String
        var rounds: [Detail]
        var switchCount: Int
        var evaluatedSwitchCount: Int
        var unacceptableSwitchCount: Int
        var recoveryDecisionSeconds: [Double]
        var unresolvedOutages: Int
        var directRequests: Int { rounds.reduce(0) { $0 + $1.directRequests } }
        var proxyRequests: Int { rounds.reduce(0) { $0 + $1.proxyRequests } }
    }
    enum InputError: Error { case invalidScenario, missingProxyObservation }
    private final class Clock { var date = Date(timeIntervalSince1970: 1_800_000_000) }
    private actor Direct: LatencyProber {
        var values: [String: Int] = [:]
        var calls: [String] = []
        func set(_ values: [String: Int]) { self.values = values; calls = [] }
        func probe(_ url: URL, timeout: TimeInterval) async -> LatencyResult {
            let host = url.host ?? ""; calls.append(host)
            return .init(url: url, latencyMs: values[host])
        }
        func requests() -> [String] { calls }
    }
    private final class Proxy: ProxiedLatencyProbing {
        var frame = Frame(at: 0)
        var calls: [String] = []
        var missing = false
        var ids: [UUID: String] = [:]
        var networkChange: (() -> Void)?
        func pingNode(node: Node, targetURL: String?, timeoutSeconds: Int) async throws -> Int {
            guard let id = ids[node.id] else { throw InputError.invalidScenario }
            calls.append(id)
            if let change = networkChange { networkChange = nil; change() }
            let primary = targetURL == ConnectivityProbe.defaultProxiedTarget
            guard let result = (primary ? frame.primary?[id] : frame.backup?[id])
                ?? (primary ? frame.primaryDefault : frame.backupDefault) else {
                missing = true; throw InputError.missingProxyObservation
            }
            if let ms = result.ms { return ms }
            throw ProxyProbeError(kind: ProxyProbeFailure(rawValue: result.failure ?? "") ?? .unavailable,
                                  message: "scenario probe")
        }
    }

    static func run(_ scenario: Scenario) async throws -> Report {
        let keys = scenario.nodes.map(\.id), valid = Set(keys)
        func symbol(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.count <= 64 && value.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
            }
        }
        guard symbol(scenario.name), !keys.isEmpty, keys.count <= 2000, valid.count == keys.count,
              keys.allSatisfy(symbol), scenario.frames.count <= 10000,
              scenario.initialChoice.map(valid.contains) ?? true else { throw InputError.invalidScenario }
        var lastTime = -Double.infinity
        for frame in scenario.frames {
            guard frame.at.isFinite, frame.at >= lastTime,
                  frame.directMs?.allSatisfy({ valid.contains($0.key) && (0..<10_000).contains($0.value) }) ?? true,
                  (frame.directFailures ?? []).allSatisfy(valid.contains),
                  (frame.available ?? []).allSatisfy(valid.contains),
                  (frame.acceptable ?? []).allSatisfy(valid.contains),
                  frame.outageStartedAt.map({ $0.isFinite && $0 <= frame.at }) ?? true else { throw InputError.invalidScenario }
            for table in [frame.primary, frame.backup] {
                guard table?.keys.allSatisfy(valid.contains) ?? true else { throw InputError.invalidScenario }
            }
            for probe in Array((frame.primary ?? [:]).values) + Array((frame.backup ?? [:]).values)
                + [frame.primaryDefault, frame.backupDefault].compactMap({ $0 }) {
                guard (probe.ms != nil) != (probe.failure != nil),
                      probe.ms.map({ (0..<10_000).contains($0) }) ?? true,
                      probe.failure.map({ ProxyProbeFailure(rawValue: $0) != nil }) ?? true else { throw InputError.invalidScenario }
            }
            lastTime = frame.at
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("selection-replay-\(UUID().uuidString)")
        let clock = Clock(), direct = Direct(), proxy = Proxy()
        let app = AppState(persistence: Persistence(directory: directory), nodeSelector: NodeSelector(prober: direct),
                           proxiedProber: proxy, measurementNow: { clock.date })
        app.settings.iCloudSyncEnabled = false
        app.settings.autoSelectUsesProxiedLatency = true
        app.settings.proxiedTestTarget = ConnectivityProbe.defaultProxiedTarget
        app.isVPNRunning = true
        defer { app.persistence.waitForPendingWritesForTesting(); try? FileManager.default.removeItem(at: directory) }
        var byKey: [String: Node] = [:]
        for (index, spec) in scenario.nodes.enumerated() {
            let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", index + 1))!
            var node: Node
            if let alias = spec.aliasOf {
                guard let original = byKey[alias] else { throw InputError.invalidScenario }
                node = original; node.id = id; node.name = spec.id
            } else {
                node = Node(id: id, name: spec.id, protocolType: spec.udp == true ? .hysteria2 : .trojan,
                            host: "node\(index).invalid", port: 443, password: "synthetic")
            }
            if let rate = spec.rate {
                guard rate.isFinite, rate > 0 else { throw InputError.invalidScenario }
                node.parameters["rate"] = String(rate)
            }
            node.isExcluded = spec.excluded ?? false
            byKey[spec.id] = node
        }
        app.nodes = keys.compactMap { byKey[$0] }
        app.currentNodeId = scenario.initialChoice.flatMap { byKey[$0]?.id }
        proxy.ids = Dictionary(uniqueKeysWithValues: byKey.map { ($0.value.id, $0.key) })
        var report = Report(name: scenario.name, rounds: [], switchCount: 0, evaluatedSwitchCount: 0,
                            unacceptableSwitchCount: 0, recoveryDecisionSeconds: [], unresolvedOutages: 0)
        var outageStart: Double?
        let aliasGroups = Dictionary(grouping: keys, by: { byKey[$0]!.identityFingerprint })
        for originalFrame in scenario.frames {
            var frame = originalFrame
            clock.date = Date(timeIntervalSince1970: 1_800_000_000 + frame.at)
            if frame.networkChanged == true { app.measurementNetworkDidChange() }
            if let running = frame.vpnRunning { app.isVPNRunning = running }
            var directValues: [String: Int] = [:]
            for group in aliasGroups.values {
                if let available = frame.available, group.contains(where: available.contains) {
                    frame.available = Array(Set(available + group)).sorted()
                }
                let explicit = Set(group.compactMap { frame.directMs?[$0] })
                let failed = group.contains { (frame.directFailures ?? []).contains($0) }
                guard explicit.count <= 1, !(failed && !explicit.isEmpty) else { throw InputError.invalidScenario }
                if !failed { directValues[byKey[group[0]]!.host] = explicit.first ?? 50 }
                // 代理候选也已按身份去重：任一别名的显式观测对整组生效，冲突必须拒绝。
                for isPrimary in [true, false] {
                    var table = (isPrimary ? frame.primary : frame.backup) ?? [:]
                    let values = group.compactMap { table[$0] }
                    guard values.allSatisfy({ $0 == values.first }) else { throw InputError.invalidScenario }
                    if let value = values.first { for key in group { table[key] = value } }
                    if isPrimary { frame.primary = table } else { frame.backup = table }
                }
            }
            await direct.set(directValues)
            proxy.frame = frame; proxy.calls = []; proxy.missing = false
            proxy.networkChange = frame.changeNetworkDuringProxy == true ? { app.measurementNetworkDidChange() } : nil
            let before = app.currentNodeId.flatMap { proxy.ids[$0] }
            if let available = frame.available, let before, !available.contains(before), outageStart == nil {
                outageStart = frame.outageStartedAt ?? frame.at
            }
            // 只替换VPN提交IO，其余所有选择分支/测量回调/缓存/冷却均执行生产代码。
            await app.autoSelectBestNode(origin: frame.manual == true ? .manual : .scheduled, applySelection: {})
            guard !proxy.missing, let evidence = app.lastSelectionReport else { throw InputError.missingProxyObservation }
            let selected = app.currentNodeId.flatMap { proxy.ids[$0] }
            if selected != before, before != nil {
                report.switchCount += 1
                if let acceptable = frame.acceptable {
                    report.evaluatedSwitchCount += 1
                    if selected.map({ !acceptable.contains($0) }) ?? true { report.unacceptableSwitchCount += 1 }
                }
            }
            if let start = outageStart, let selected, frame.available?.contains(selected) == true {
                report.recoveryDecisionSeconds.append(frame.at - start); outageStart = nil
            }
            if outageStart == nil, let selected, let available = frame.available, !available.contains(selected) {
                // 旧选择可用、却误切入不可用出口：故障从这次决定开始，不能回溯到输入的旧故障时间。
                outageStart = frame.at
            }
            let directCalls = await direct.requests()
            report.rounds.append(.init(at: frame.at, selected: selected, reason: reason(evidence.reason),
                directRequests: directCalls.count, directIdentities: Set(directCalls).count,
                directReused: evidence.directReusedCount, directDeferred: evidence.directDeferredCount,
                proxyRequests: proxy.calls.count, confirmations: evidence.proxy.confirmationAttempts,
                cooldownCount: evidence.proxy.confirmedFailureCount,
                cooling: keys.filter { app.nodeProbeCooldown.contains(byKey[$0]!.identityFingerprint, now: clock.date) },
                usedBackup: evidence.proxy.usedBackupTarget, proxyNodes: proxy.calls))
        }
        report.unresolvedOutages = outageStart == nil ? 0 : 1
        return report
    }

    private static func reason(_ reason: NodeSelectionReport.Reason) -> String {
        switch reason {
        case .highestScore: "highestScore"
        case .alreadyBest: "alreadyBest"
        case .insufficientLead: "insufficientLead"
        case .confirmingLead(let n, let total): "confirmingLead-\(n)-\(total)"
        case .networkChanged: "networkChanged"
        case .noEligibleMeasurement: "noEligibleMeasurement"
        case .selectionChanged: "selectionChanged"
        case .candidateChanged: "candidateChanged"
        case .cancelled: "cancelled"
        case .proxyUnverified: "proxyUnverified"
        case .availabilityRecovery: "availabilityRecovery"
        }
    }
}
