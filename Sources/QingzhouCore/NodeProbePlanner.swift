import Foundation

/// 有界代理候选：当前节点 + 综合评分前列 + 少量轮换探索。
public struct NodeProbePlanner: Sendable {
    public static let candidateLimit = 6
    public struct Plan: Sendable {
        public let candidates: [Node]
        public let explorationCount: Int
    }
    private var round: UInt64 = 0
    private var lastExplored: [String: UInt64] = [:]
    public init() {}
    public mutating func plan(ranked: [Node], incumbent: Node?) -> Plan {
        round &+= 1
        var seen: Set<String> = []
        var selected: [Node] = []
        if let incumbent {
            selected.append(incumbent)
            seen.insert(incumbent.identityFingerprint)
        }
        // 调用方已按地区 / 冷却过滤并按综合分排序。完整配置去重，当前节点的 UUID 优先。
        let unique = ranked.filter { seen.insert($0.identityFingerprint).inserted }
        let topCount = max(0, Self.candidateLimit - 2 - selected.count)
        selected.append(contentsOf: unique.prefix(topCount))
        let remaining = Array(unique.dropFirst(topCount)).sorted {
            let a = lastExplored[$0.identityFingerprint] ?? 0
            let b = lastExplored[$1.identityFingerprint] ?? 0
            return a != b ? a < b : $0.identityFingerprint < $1.identityFingerprint
        }
        let explorers = Array(remaining.prefix(Self.candidateLimit - selected.count))
        let valid = Set(ranked.map(\.identityFingerprint))
        lastExplored = lastExplored.filter { valid.contains($0.key) }
        for node in explorers { lastExplored[node.identityFingerprint] = round }
        selected.append(contentsOf: explorers)
        return Plan(candidates: selected, explorationCount: explorers.count)
    }
}
