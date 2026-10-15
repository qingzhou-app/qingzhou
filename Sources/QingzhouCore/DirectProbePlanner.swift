import Foundation

/// 定时 TCP 测量预算。调用方负责地区排除、冷却和评分排序；手动全量绕过此规划器。
public enum DirectProbePlanner {
    public static let candidateLimit = 24
    public static let reuseInterval: TimeInterval = 5 * 60

    public struct Plan: Sendable {
        public let candidates: [Node]
        public let reusedCount: Int
        public let deferredCount: Int
    }

    /// 成功和失败都可复用，未来时间不能因时钟回拨长期占住缓存。
    public static func isRecent(_ node: Node, now: Date) -> Bool {
        guard let at = node.lastTestedAt else { return false }
        return (0..<reuseInterval).contains(now.timeIntervalSince(at))
    }

    public static func plan(ranked: [Node], incumbentID: UUID?, now: Date,
                            confirmingIdentity: String? = nil) -> Plan {
        let eligible = ranked.filter { !$0.isExcluded && $0.protocolType.supportsTCPProbe }
        let incumbent = eligible.first { $0.id == incumbentID }
        var seen: Set<String> = []
        // 当前 UUID 优先，其余同配置别名用最新测量判断是否已测。
        let byIdentity = Dictionary(grouping: eligible, by: \.identityFingerprint)
        let unique = eligible.filter { seen.insert($0.identityFingerprint).inserted }.map { node in
            byIdentity[node.identityFingerprint]!.max {
                ($0.lastTestedAt ?? .distantPast) < ($1.lastTestedAt ?? .distantPast)
            }!
        }
        var chosen = incumbent.map { [$0] } ?? []
        if let confirming = unique.first(where: { $0.identityFingerprint == confirmingIdentity }),
           confirming.identityFingerprint != incumbent?.identityFingerprint {
            chosen.append(confirming)
        }
        let forced = Set(chosen.map(\.identityFingerprint))
        let remaining = unique.filter { !forced.contains($0.identityFingerprint) }
        let due = remaining.filter { !isRecent($0, now: now) }
        // 最多8个重点候选（含当前），至少16个位置留给未测/最久未测者，避免大池饿死。
        let topCount = 8 - chosen.count
        chosen.append(contentsOf: due.prefix(topCount))
        let exploring = due.dropFirst(topCount).sorted {
            func age(_ node: Node) -> Date {
                guard let at = node.lastTestedAt, at <= now else { return .distantPast }
                return at
            }
            let a = age($0), b = age($1)
            return a != b ? a < b : $0.identityFingerprint < $1.identityFingerprint
        }
        chosen.append(contentsOf: exploring.prefix(candidateLimit - chosen.count))
        let reused = remaining.count - due.count
        return Plan(candidates: chosen, reusedCount: reused,
                    deferredCount: unique.count - chosen.count - reused)
    }
}
