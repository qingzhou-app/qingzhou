import Foundation
import VPNCore
import VPNLogging

/// 给一组节点逐个测速，再选出延迟最低的节点。
///
/// 探针默认是 `TCPConnectLatencyProber` —— 只测 TCP 三次握手的 RTT，
/// 不做 TLS handshake / HTTP 请求，跟 VPN 节点（trojan/vmess 等非 HTTP 服务）匹配得多。
/// 单测可注入 fake LatencyProber。
public actor NodeSelector {
    private let prober: LatencyProber
    private let logger: Logger?
    /// 同时打开的探针数上限。一次性放出去几百个 TCP 握手会把网络压满，导致每个探针都看到
    /// 几百毫秒延迟，跟"网络真没那么慢"的事实矛盾。8 是经验值，在 4G/Wi-Fi 上都比较稳。
    private let maxConcurrent: Int

    public init(
        prober: LatencyProber = TCPConnectLatencyProber(),
        logger: Logger? = nil,
        maxConcurrent: Int = 8
    ) {
        self.prober = prober
        self.logger = logger
        self.maxConcurrent = max(1, maxConcurrent)
    }

    /// 给每个非排除的节点打分（延迟）。返回更新后的节点列表（保持原顺序，写入测速结果）。
    ///
    /// `onResult` 在每个节点测完时立刻回调（按 node id），让 UI 能逐个刷新延迟、
    /// 而不是干等所有节点测完一次性更新。回调在 MainActor 上执行。
    public func measure(
        nodes: [Node],
        timeout: TimeInterval = 5,
        onResult: (@MainActor @Sendable (UUID, LatencyResult) -> Void)? = nil
    ) async -> [Node] {
        // 先把要测的节点压成 (索引, URL) 二元组 —— probe URL 算出来不可用的直接跳过。
        let work: [(Int, URL)] = nodes.enumerated().compactMap { (idx, node) in
            guard !node.isExcluded, let url = nodeProbeURL(node) else { return nil }
            return (idx, url)
        }
        logger?.info(
            "Measuring latency: \(work.count)/\(nodes.count) candidates, concurrency=\(maxConcurrent)",
            category: "speedtest"
        )

        // Sliding-window 并发：始终保持 ≤ maxConcurrent 个 task 在飞，先到先回收。
        let measurements: [(Int, LatencyResult)] = await withTaskGroup(of: (Int, LatencyResult).self) { group in
            var iter = work.makeIterator()

            // 先 prime 一批
            for _ in 0..<maxConcurrent {
                guard let (idx, url) = iter.next() else { break }
                group.addTask { [prober] in
                    (idx, await prober.probe(url, timeout: timeout))
                }
            }

            var collected: [(Int, LatencyResult)] = []
            // 每完成一个就补一个，直到 iter 耗尽且 group 排空
            while let (idx, result) = await group.next() {
                collected.append((idx, result))
                // 测完一个立刻回调 UI（用 node id 定位，不依赖 index，调用方可能在重排）
                if let onResult {
                    await onResult(nodes[idx].id, result)
                }
                if let (nextIdx, nextURL) = iter.next() {
                    group.addTask { [prober] in
                        (nextIdx, await prober.probe(nextURL, timeout: timeout))
                    }
                }
            }
            return collected
        }

        var updated = nodes
        let now = Date()
        for (idx, result) in measurements {
            updated[idx].lastLatencyMs = result.latencyMs
            updated[idx].lastTestedAt = now
        }
        return updated
    }

    /// 在节点列表里找出延迟最低的非排除节点；都失败时返回 nil。
    public func pickBest(from nodes: [Node]) -> Node? {
        let viable = nodes.filter { !$0.isExcluded && $0.lastLatencyMs != nil }
        return viable.min(by: { ($0.lastLatencyMs ?? .max) < ($1.lastLatencyMs ?? .max) })
    }

    private func nodeProbeURL(_ node: Node) -> URL? {
        // 只是个 host:port 容器 —— TCPConnectLatencyProber 解析后只用 host + port，
        // scheme 不参与连接。保留 `tcp://` 这种半合法 scheme 单纯为了 URLComponents 能 round-trip。
        var comps = URLComponents()
        comps.scheme = "tcp"
        comps.host = node.host
        comps.port = node.port
        return comps.url
    }
}
