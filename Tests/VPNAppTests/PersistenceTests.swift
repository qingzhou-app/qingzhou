import XCTest
import VPNCore
@testable import VPNApp

final class PersistenceTests: XCTestCase {
    var tmpDir: URL!
    var persistence: Persistence!

    override func setUp() {
        super.setUp()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vpn-test-\(UUID().uuidString)", isDirectory: true)
        persistence = Persistence(directory: tmpDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    func testRoundtripEmpty() {
        let snap = persistence.loadSnapshot()
        XCTAssertTrue(snap.subscriptions.isEmpty)
        XCTAssertTrue(snap.nodes.isEmpty)
        XCTAssertTrue(snap.customRules.isEmpty)
        XCTAssertNil(snap.currentNodeId)
    }

    func testRoundtripWithData() throws {
        let nodeId = UUID()
        let node = Node(id: nodeId, name: "n1", protocolType: .trojan, host: "h", port: 443, password: "pw")
        let rule = Rule(type: .domainSuffix, value: "google.com", target: .proxy)
        let sub = Subscription(name: "s1", url: URL(string: "https://x.com/sub")!)
        var settings = Settings()
        settings.proxyMode = .global
        settings.logLevel = "WARN"

        let snap = Persistence.Snapshot(
            subscriptions: [sub],
            nodes: [node],
            customRules: [rule],
            settings: settings,
            currentNodeId: nodeId
        )
        try persistence.saveSnapshot(snap)

        let loaded = persistence.loadSnapshot()
        XCTAssertEqual(loaded.subscriptions.first?.name, "s1")
        XCTAssertEqual(loaded.nodes.first?.id, nodeId)
        XCTAssertEqual(loaded.nodes.first?.name, "n1")
        XCTAssertEqual(loaded.customRules.first?.value, "google.com")
        XCTAssertEqual(loaded.settings.proxyMode, .global)
        XCTAssertEqual(loaded.settings.logLevel, "WARN")
        XCTAssertEqual(loaded.currentNodeId, nodeId)
    }

    func testSurvivesMissingFile() {
        // 没有写过任何东西时 load 应该返回空 snapshot 而不是 crash
        let fresh = Persistence(directory: tmpDir.appendingPathComponent("does-not-exist"))
        let snap = fresh.loadSnapshot()
        XCTAssertTrue(snap.nodes.isEmpty)
    }

    func testCorruptedFileFallsBackToEmpty() throws {
        // 故意写一个非法 JSON
        let url = tmpDir.appendingPathComponent("state.json")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        let snap = persistence.loadSnapshot()
        XCTAssertTrue(snap.nodes.isEmpty)
    }

    func testDefaultDirectoryReturnsValidPath() {
        let dir = Persistence.defaultDirectory()
        XCTAssertTrue(dir.path.contains("VPN"))
    }
}
