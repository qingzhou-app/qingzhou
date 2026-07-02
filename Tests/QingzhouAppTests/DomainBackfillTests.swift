import XCTest
import QingzhouCore
import QingzhouLogging
@testable import QingzhouApp

/// 裸 IP 连接的域名回翻：fakedns-map（appex 每秒才落盘一次）晚于连接 ingest 到达时，
/// 已摄入的连接不能永远顶着裸 IP —— 否则按域名搜不到、开「忽略 IP」时整行被藏。
@MainActor
final class DomainBackfillTests: XCTestCase {
    var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("backfill-test-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        try await super.tearDown()
    }

    private func makeState() -> AppState {
        AppState(
            logger: Logger(capacity: 100, minimumLevel: .debug),
            persistence: Persistence(directory: tmpDir)
        )
    }

    private func bareIPConn(_ ip: String, route: String = "DIRECT") -> Connection {
        Connection(
            targetHost: ip,
            sourceAddress: "10.0.10.1:50000",
            targetAddress: "\(ip):443",
            type: .https,
            route: route,
            matchedRule: ""
        )
    }

    func testLateMapTranslatesIngestedBareIP() {
        let state = makeState()
        state.connectionTracker.ingest(bareIPConn("123.125.244.81"))
        XCTAssertEqual(state.connections.first?.targetHost, "123.125.244.81")

        // map 晚到（appex 下一秒才写盘）→ 回翻
        state.fakeDNSMap = ["123.125.244.81": "mqtt-web.zhihu.com"]
        state.backfillDomainNames()
        XCTAssertEqual(state.connections.first?.targetHost, "mqtt-web.zhihu.com")
        // targetAddress 保留 ip:port 原样 —— 那一行显示的就是真实地址
        XCTAssertEqual(state.connections.first?.targetAddress, "123.125.244.81:443")
    }

    func testBackfillRecomputesMatchedRule() {
        let state = makeState()
        state.addCustomRule(Rule(type: .domainSuffix, value: "zhihu.com", target: .direct))
        state.connectionTracker.ingest(bareIPConn("123.125.244.81"))
        state.fakeDNSMap = ["123.125.244.81": "www.zhihu.com"]
        state.backfillDomainNames()
        // host 变成域名后，规则命中要重算，不能留着裸 IP 时代的空值
        XCTAssertEqual(state.connections.first?.matchedRule, "DOMAIN-SUFFIX,zhihu.com,DIRECT")
    }

    func testDomainHostsAndUnmappedIPsUntouched() {
        let state = makeState()
        var domainConn = bareIPConn("198.18.0.5")
        domainConn.targetHost = "example.com"          // 已是域名
        state.connectionTracker.ingest(domainConn)
        state.connectionTracker.ingest(bareIPConn("9.9.9.9"))  // map 里没有
        state.fakeDNSMap = ["1.1.1.1": "one.one.one.one"]
        state.backfillDomainNames()
        let hosts = state.connections.map(\.targetHost).sorted()
        XCTAssertEqual(hosts, ["9.9.9.9", "example.com"])
    }

    func testEmptyMapIsNoop() {
        let state = makeState()
        state.connectionTracker.ingest(bareIPConn("5.6.7.8"))
        state.backfillDomainNames()
        XCTAssertEqual(state.connections.first?.targetHost, "5.6.7.8")
    }
}
