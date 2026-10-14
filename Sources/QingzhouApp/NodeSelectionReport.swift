import Foundation
import QingzhouCore

/// 最近一轮真实择优的只读证据，进程内保留，不写入配置或云文档。
/// 只描述选择决定；隧道是否已应用该选择仍由实际会话状态表示。
public struct NodeSelectionReport: Sendable, Identifiable {
    public enum Reason: Sendable, Equatable {
        case highestScore, alreadyBest, insufficientLead
        case confirmingLead(completed: Int, required: Int)
        case noEligibleMeasurement, selectionChanged, candidateChanged, cancelled
    }
    public struct Candidate: Sendable {
        public let id: UUID
        public let name: String
        public let region: String
        public let directLatencyMs: Int?
        public let score: NodeScorer.Score
        public let stabilitySampleCount: Int
        public let hasBandwidthObservation: Bool
    }
    public struct ProxyEvidence: Sendable {
        public enum State: Sendable { case notRequested, vpnUnavailable, switchInProgress, completed, interrupted }
        public var state: State = .notRequested
        public var succeeded = 0
        public var failed = 0
        public var attempted: Int { succeeded + failed }
        public var fellBackToDirect = false
    }
    public let id: UUID
    public let completedAt: Date
    public let origin: AppState.AutoSelectOrigin
    public let reason: Reason
    public let selected: Candidate?
    public let challenger: Candidate?
    public let profile: ScoringProfile
    public let prefersLowerRate: Bool
    public let preferredRegion: String?
    public let usedPreferredRegion: Bool
    public let excludedCount: Int
    public let directSucceeded: Int
    public let directFailed: Int
    public let unmeasuredUDPCount: Int
    public let proxy: ProxyEvidence

    public var summary: String {
        switch reason {
        case .highestScore: selected.map { L("已选择：\($0.name)") } ?? L("未选择新节点")
        case .alreadyBest: L("保持当前节点：综合评分仍为本轮最优")
        case .insufficientLead: L("保持当前节点：候选领先不足，避免频繁切换")
        case .confirmingLead(let completed, let required): L("保持当前节点：候选连续领先 \(completed)/\(required) 轮")
        case .noEligibleMeasurement: L("本轮没有合格的测量候选，未选择新节点")
        case .selectionChanged: L("测量期间选择已变化，未覆盖你的选择")
        case .candidateChanged: L("候选配置已变化，本轮未采用旧结果")
        case .cancelled: L("本轮择优已取消")
        }
    }
}

/// MainActor 回调与串行代理探测共享本轮计数；不把可变捕获变量带入 Sendable 闭包。
@MainActor
final class SelectionMeasurementEvidence {
    var directSucceeded = 0
    var directFailed = 0
    var proxy = NodeSelectionReport.ProxyEvidence()
    func recordProxy(_ latency: Int?) {
        proxy.state = .completed
        if latency != nil { proxy.succeeded += 1 } else { proxy.failed += 1 }
    }
}
