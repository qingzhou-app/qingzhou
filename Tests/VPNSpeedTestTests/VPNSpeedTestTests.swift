import XCTest
import VPNCore
@testable import VPNSpeedTest

final class VPNSpeedTestTests: XCTestCase {

    /// 假探针：按预设映射返回延迟，不发起任何网络请求。
    struct StubProber: LatencyProber {
        let mapping: [String: Int?]   // URL → 毫秒；nil 表示模拟失败
        func probe(_ url: URL, timeout: TimeInterval) async -> LatencyResult {
            // 用 host:port 当 key，URL 内部可能有变体
            let key = "\(url.host ?? ""):\(url.port ?? 0)"
            let absKey = url.absoluteString
            if let ms = mapping[absKey] {
                return LatencyResult(url: url, latencyMs: ms)
            } else if let ms = mapping[key] {
                return LatencyResult(url: url, latencyMs: ms)
            }
            return LatencyResult(url: url, latencyMs: nil, errorDescription: "no stub")
        }
    }

    func testBuiltInTargetsURLs() {
        for t in SpeedTestTarget.allCases {
            XCTAssertNotNil(t.url.host, "\(t) 必须有 host")
            XCTAssertFalse(t.displayName.isEmpty)
        }
    }

    func testSpeedTestRunnerCollectsResultsInOrder() async {
        let urls = [
            URL(string: "https://a.example/")!,
            URL(string: "https://b.example/")!,
            URL(string: "https://c.example/")!
        ]
        let prober = StubProber(mapping: [
            "https://a.example/": 10,
            "https://b.example/": 50,
            "https://c.example/": nil
        ])
        let runner = SpeedTestRunner(prober: prober)
        let report = await runner.run(urls: urls)
        XCTAssertEqual(report.results.map(\.url), urls)
        XCTAssertEqual(report.results[0].latencyMs, 10)
        XCTAssertEqual(report.results[1].latencyMs, 50)
        XCTAssertNil(report.results[2].latencyMs)
    }

    func testNodeSelectorRanksByLatency() async {
        let nodes = [
            Node(name: "slow", protocolType: .trojan, host: "slow.example", port: 443),
            Node(name: "fast", protocolType: .trojan, host: "fast.example", port: 443),
            Node(name: "dead", protocolType: .trojan, host: "dead.example", port: 443)
        ]
        let prober = StubProber(mapping: [
            "slow.example:443": 200,
            "fast.example:443": 30,
            "dead.example:443": nil
        ])
        let selector = NodeSelector(prober: prober)
        let measured = await selector.measure(nodes: nodes)
        XCTAssertEqual(measured.first(where: { $0.name == "fast" })?.lastLatencyMs, 30)
        XCTAssertEqual(measured.first(where: { $0.name == "slow" })?.lastLatencyMs, 200)
        XCTAssertNil(measured.first(where: { $0.name == "dead" })?.lastLatencyMs)
        let best = await selector.pickBest(from: measured)
        XCTAssertEqual(best?.name, "fast")
    }

    func testNodeSelectorSkipsExcludedNodes() async {
        let nodes = [
            Node(name: "ex", protocolType: .trojan, host: "ex.example", port: 443, isExcluded: true),
            Node(name: "ok", protocolType: .trojan, host: "ok.example", port: 443)
        ]
        let prober = StubProber(mapping: [
            "ex.example:443": 1,  // 即使最快也不应被选中
            "ok.example:443": 100
        ])
        let selector = NodeSelector(prober: prober)
        let measured = await selector.measure(nodes: nodes)
        // 被排除节点不应被测速
        XCTAssertNil(measured.first(where: { $0.name == "ex" })?.lastLatencyMs)
        let best = await selector.pickBest(from: measured)
        XCTAssertEqual(best?.name, "ok")
    }

    /// 渐进式回调：每个非排除节点恰好回调一次，且 id/结果对应正确。
    func testMeasureFiresProgressiveCallbackPerNode() async {
        let nodes = [
            Node(name: "a", protocolType: .trojan, host: "a.example", port: 443),
            Node(name: "ex", protocolType: .trojan, host: "ex.example", port: 443, isExcluded: true),
            Node(name: "b", protocolType: .trojan, host: "b.example", port: 443)
        ]
        let prober = StubProber(mapping: [
            "a.example:443": 50,
            "ex.example:443": 10,
            "b.example:443": 80
        ])
        let selector = NodeSelector(prober: prober)

        // 收集回调 —— 用 actor 避免数据竞争
        actor Collector {
            var hits: [(UUID, Int?)] = []
            func add(_ id: UUID, _ ms: Int?) { hits.append((id, ms)) }
        }
        let collector = Collector()

        _ = await selector.measure(nodes: nodes) { id, result in
            // 跳出 MainActor 边界把结果丢进 actor
            Task { await collector.add(id, result.latencyMs) }
        }
        // 给 detached 的回调收尾
        try? await Task.sleep(for: .milliseconds(50))

        let hits = await collector.hits
        // 只有 2 个非排除节点应触发回调
        XCTAssertEqual(hits.count, 2)
        let ids = Set(hits.map(\.0))
        XCTAssertTrue(ids.contains(nodes[0].id))
        XCTAssertTrue(ids.contains(nodes[2].id))
        XCTAssertFalse(ids.contains(nodes[1].id), "被排除节点不应回调")
    }

    func testNodeSelectorReturnsNilWhenAllFailed() async {
        let nodes = [
            Node(name: "a", protocolType: .trojan, host: "a.example", port: 443),
            Node(name: "b", protocolType: .trojan, host: "b.example", port: 443)
        ]
        let prober = StubProber(mapping: [
            "a.example:443": nil,
            "b.example:443": nil
        ])
        let selector = NodeSelector(prober: prober)
        let measured = await selector.measure(nodes: nodes)
        let best = await selector.pickBest(from: measured)
        XCTAssertNil(best)
    }
}
