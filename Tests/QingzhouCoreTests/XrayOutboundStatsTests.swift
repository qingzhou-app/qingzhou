import XCTest
@testable import QingzhouCore

final class XrayOutboundStatsTests: XCTestCase {

    func testProxyShare() {
        var stats = XrayOutboundStats()
        XCTAssertNil(stats.proxyShare, "无数据时占比无意义")
        stats.outbounds["proxy"] = .init(uplinkBytes: 100, downlinkBytes: 300)   // 400
        stats.outbounds["direct"] = .init(uplinkBytes: 50, downlinkBytes: 50)    // 100
        stats.outbounds["reject"] = .init(uplinkBytes: 999, downlinkBytes: 999)  // 不参与占比
        XCTAssertEqual(stats.proxyShare!, 0.8, accuracy: 0.0001)
    }

    func testCodableRoundTripISO8601() throws {
        let stats = XrayOutboundStats(
            outbounds: ["proxy": .init(uplinkBytes: 1, downlinkBytes: 2)],
            sampledAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(XrayOutboundStats.self, from: encoder.encode(stats))
        XCTAssertEqual(decoded, stats)
    }

    /// Node 新增的经代理延迟字段必须向后兼容：旧版持久化 JSON（没有这俩 key）要能解出来。
    func testNodeDecodesLegacyJSONWithoutProxiedFields() throws {
        let legacy = #"""
        {
          "id": "6BA85179-E30D-4FC2-8CDA-48B308110000",
          "name": "旧节点",
          "protocolType": "trojan",
          "host": "example.com",
          "port": 443,
          "password": "pw",
          "parameters": {},
          "isExcluded": false
        }
        """#
        let node = try JSONDecoder().decode(Node.self, from: legacy.data(using: .utf8)!)
        XCTAssertNil(node.lastProxiedLatencyMs)
        XCTAssertNil(node.lastProxiedTestedAt)
        XCTAssertEqual(node.name, "旧节点")
    }
}
