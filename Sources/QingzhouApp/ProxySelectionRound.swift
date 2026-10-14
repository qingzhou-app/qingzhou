import Foundation
import QingzhouCore

/// 串行探测编排；IO 由调用者提供，决定及计数只依赖本轮结果。
@MainActor
enum ProxySelectionRound {
    struct Result {
        var measurements: [(node: Node, ms: Int)] = []
        var confirmedFailures: Set<String> = []
        var evidence = NodeSelectionReport.ProxyEvidence()
    }
    static func run(candidates: [Node], incumbentID: UUID?, initialID: UUID?, target: String,
        shouldContinue: () -> Bool,
        probe: (Node, String) async -> ProxyProbeOutcome) async -> Result {
        var result = Result()
        var primary: [(node: Node, ms: Int)] = []
        var backup: [(node: Node, ms: Int)] = []
        var failed: [Node] = []
        var twiceFailed: Set<String> = []
        func canContinue() -> Bool { !Task.isCancelled && shouldContinue() }
        func interrupted() -> Result {
            result.measurements = []; result.confirmedFailures = []
            result.evidence.state = .interrupted
            return result
        }
        for node in candidates {
            guard canContinue() else { return interrupted() }
            let outcome = await probe(node, target)
            result.evidence.record(outcome)
            guard canContinue() else { return interrupted() }
            switch outcome {
            case .success(let ms): primary.append((node, ms))
            case .failure(.probeFailed): failed.append(node)
            case .failure(.invalidConfiguration): break
            case .failure: return interrupted()
            }
        }
        // 最多两次额外请求；优先复核当前节点和初选，其他失败不升级为冷却。
        let ordered = failed.sorted {
            func priority(_ node: Node) -> Int { node.id == incumbentID ? 0 : (node.id == initialID ? 1 : 2) }
            let lhs = priority($0), rhs = priority($1)
            return lhs != rhs ? lhs < rhs : $0.id.uuidString < $1.id.uuidString
        }
        let targetHost = URL(string: target)?.host?.lowercased()
        let backupTarget = ConnectivityProbe.presets.first { URL(string: $0.url)?.host?.lowercased() != targetHost }!.url
        for node in ordered.prefix(2) {
            guard canContinue() else { return interrupted() }
            let outcome = await probe(node, backupTarget)
            result.evidence.confirmationAttempts += 1
            result.evidence.record(outcome)
            guard canContinue() else { return interrupted() }
            switch outcome {
            case .success(let ms): backup.append((node, ms))
            case .failure(.probeFailed): twiceFailed.insert(node.identityFingerprint)
            case .failure(.invalidConfiguration): break
            case .failure: return interrupted()
            }
        }
        // 不混合不同目标的延迟；主目标全失败时才以公共备用目标的成功集排名。
        result.measurements = primary.isEmpty ? backup : primary
        result.evidence.usedBackupTarget = primary.isEmpty && !backup.isEmpty
        let successfulIdentities = Set((primary + backup).map { $0.node.identityFingerprint })
        if !successfulIdentities.isEmpty {
            // 跨订阅同配置可有多个UUID；成功别名不能被另一别名的失败处罚。
            result.confirmedFailures = twiceFailed.subtracting(successfulIdentities)
        }
        return result
    }
}
