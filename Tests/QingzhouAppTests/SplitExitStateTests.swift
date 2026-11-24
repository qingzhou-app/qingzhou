import XCTest
import QingzhouCore
import QingzhouLogging
@testable import QingzhouApp

/// 分流方案（国内直连 / 海外出口）在 App 层的状态语义。
///
/// 这里测的是「什么情况下允许连、什么情况下必须拒绝连」，不是界面。
/// 拒绝的两种情形都不是"体验问题"：缺跳板的住宅代理会从本机直连（国内连不上 + 暴露真实 IP），
/// 出口=跳板会绕成死循环。所以宁可连不上并给出原因。
@MainActor
final class SplitExitStateTests: XCTestCase {

    private var directories: [URL] = []

    private func makeState() -> AppState {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directories.append(directory)
        let state = AppState(
            logger: Logger(capacity: 100, minimumLevel: .error),
            persistence: Persistence(directory: directory))
        state.settings.iCloudSyncEnabled = false
        return state
    }

    override func tearDown() async throws {
        for d in directories { try? FileManager.default.removeItem(at: d) }
        directories = []
        try await super.tearDown()
    }

    private func exitNode() -> Node {
        Node(name: "住宅", protocolType: .socks5, host: "203.0.113.9", port: 1080,
             password: "p", parameters: ["username": "u"])
    }

    private func hopNode() -> Node {
        Node(name: "HK-01", protocolType: .trojan, host: "hk.example.com", port: 443, password: "pw")
    }

    func testDisabledMeansNoReason() {
        let state = makeState()
        state.settings.splitExitEnabled = false
        XCTAssertNil(state.splitExitBlockedReason)
    }

    func testMissingExitOrHopBlocksStart() {
        let state = makeState()
        state.nodes = [exitNode(), hopNode()]
        state.settings.splitExitEnabled = true

        XCTAssertNotNil(state.splitExitBlockedReason, "两个都没选时必须拦住")

        state.settings.splitExitExitNodeID = state.nodes[0].id
        XCTAssertNotNil(state.splitExitBlockedReason, "缺跳板必须拦住")

        state.settings.splitExitExitNodeID = nil
        state.settings.splitExitHopNodeID = state.nodes[1].id
        XCTAssertNotNil(state.splitExitBlockedReason, "缺出口必须拦住")
    }

    func testSameNodeForExitAndHopBlocksStart() {
        let state = makeState()
        let n = exitNode()
        state.nodes = [n]
        state.settings.splitExitEnabled = true
        state.settings.splitExitExitNodeID = n.id
        state.settings.splitExitHopNodeID = n.id
        XCTAssertNotNil(state.splitExitBlockedReason, "出口=跳板会绕成死循环")
    }

    func testBothSelectedIsReady() {
        let state = makeState()
        let exit = exitNode(), hop = hopNode()
        state.nodes = [exit, hop]
        state.settings.splitExitEnabled = true
        state.settings.splitExitExitNodeID = exit.id
        state.settings.splitExitHopNodeID = hop.id
        XCTAssertNil(state.splitExitBlockedReason)
        XCTAssertEqual(state.splitExitExitNode?.id, exit.id)
        XCTAssertEqual(state.splitExitHopNode?.id, hop.id)
    }

    /// 分流方案自带完整 routing，与全局/直连模式互斥 —— 打开时强制规则模式，
    /// 否则会出现「开关是开的、其实没按分流跑」。
    func testEnablingForcesRuleMode() {
        let state = makeState()
        state.settings.proxyMode = .global
        state.setSplitExitEnabled(true)
        XCTAssertEqual(state.settings.proxyMode, .rule)
    }
}
