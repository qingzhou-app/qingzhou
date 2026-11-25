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

        let upper = Node(name: "住宅2", protocolType: .socks5, host: "Exit.Example.COM", port: 1080, password: "p")
        let lower = Node(name: "跳板2", protocolType: .socks5, host: "exit.example.com", port: 1080, password: "p")
        state.nodes = [upper, lower]
        state.settings.splitExitExitNodeID = upper.id
        state.settings.splitExitHopNodeID = lower.id
        XCTAssertNotNil(state.splitExitBlockedReason, "大小写不同的同主机出口=跳板也必须拦住")
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

    func testStartTunnelAllowsSplitExitWhenCurrentNodeIdIsNil() async {
        let state = makeState()
        let exit = exitNode(), hop = hopNode()
        state.nodes = [exit, hop]
        state.currentNodeId = nil
        state.settings.proxyMode = .rule
        state.settings.splitExitEnabled = true
        state.settings.splitExitExitNodeID = exit.id
        state.settings.splitExitHopNodeID = hop.id

        await state.startTunnel()
        XCTAssertNotEqual(state.tunnelError, VPNTunnelManager.TunnelError.noCurrentNode.errorDescription)
        XCTAssertNotEqual(state.tunnelError, L("无法把节点编码成分享链接"))
    }

    func testEffectiveBlockQUICUsesSplitExitNodeOverHysteria2OrNilCurrentNode() {
        let state = makeState()
        state.settings.quicPolicy = .auto
        let hy2 = Node(name: "HY2", protocolType: .hysteria2, host: "hy2.example.com", port: 443, password: "pw")
        let socks = exitNode()

        XCTAssertFalse(state.effectiveBlockQUIC(for: hy2))
        XCTAssertTrue(state.effectiveBlockQUIC(for: socks))

        XCTAssertTrue(state.effectiveBlockQUICForTunnel(normalNode: hy2, splitExitNode: socks))
        XCTAssertTrue(state.effectiveBlockQUICForTunnel(normalNode: nil, splitExitNode: socks))
        XCTAssertFalse(state.effectiveBlockQUICForTunnel(normalNode: socks, splitExitNode: hy2))
        XCTAssertFalse(state.effectiveBlockQUICForTunnel(normalNode: hy2, splitExitNode: nil))
    }

    func testSetGuardRelayEnabledPersistsState() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directories.append(dir)
        let state = AppState(
            logger: Logger(capacity: 100, minimumLevel: .error),
            persistence: Persistence(directory: dir)
        )
        state.settings.iCloudSyncEnabled = false
        XCTAssertFalse(state.settings.guardRelayEnabled)

        state.setGuardRelayEnabled(true)
        XCTAssertTrue(state.settings.guardRelayEnabled)

        let saved = await state.saveCurrentSnapshot().value
        XCTAssertTrue(saved)
        let reloaded = Persistence(directory: dir).loadSnapshot()
        XCTAssertTrue(reloaded.settings.guardRelayEnabled)
    }

    #if os(macOS)
    func testPerformReapplyAbortsFailClosedWhenGuardRelayCredentialsMissing() async {
        let state = makeState()
        let exit = exitNode(), hop = hopNode()
        state.nodes = [exit, hop]
        state.settings.proxyMode = .rule
        state.settings.splitExitEnabled = true
        state.settings.splitExitExitNodeID = exit.id
        state.settings.splitExitHopNodeID = hop.id
        state.settings.guardRelayEnabled = true
        state.isVPNRunning = true

        var loaderCalls = 0
        var testNodeCalls = 0
        var configureCalls = 0
        var startCalls = 0
        state.loadGuardRelayCredentials = {
            loaderCalls += 1
            return nil
        }
        state.tunnelManager.onTestNodeConfigAttempt = { testNodeCalls += 1 }
        state.tunnelManager.onConfigureAttempt = { configureCalls += 1 }
        state.tunnelManager.onStartAttempt = { startCalls += 1 }

        await state.performReapply(scope: .full)

        XCTAssertEqual(loaderCalls, 1)
        XCTAssertEqual(testNodeCalls, 0)
        XCTAssertEqual(configureCalls, 0)
        XCTAssertEqual(startCalls, 0)
        XCTAssertTrue(state.isVPNRunning, "缺失中继凭据时不得破坏仍在运行的隧道")
        XCTAssertFalse(state.isSwitchingTunnel)
        XCTAssertEqual(
            state.tunnelError,
            L("已开启「经 root 中继出网」，但读不到中继凭据。先安装 guard：sudo sh Tools/qingzhou-guard/install.sh")
        )
    }

    func testStartTunnelAbortsFailClosedWhenGuardRelayCredentialsMissing() async {
        let state = makeState()
        let exit = exitNode(), hop = hopNode()
        state.nodes = [exit, hop]
        state.settings.proxyMode = .rule
        state.settings.splitExitEnabled = true
        state.settings.splitExitExitNodeID = exit.id
        state.settings.splitExitHopNodeID = hop.id
        state.settings.guardRelayEnabled = true

        var loaderCalls = 0
        var configureCalls = 0
        var startCalls = 0
        state.loadGuardRelayCredentials = {
            loaderCalls += 1
            return nil
        }
        state.tunnelManager.onConfigureAttempt = { configureCalls += 1 }
        state.tunnelManager.onStartAttempt = { startCalls += 1 }

        await state.startTunnel()

        XCTAssertEqual(loaderCalls, 1)
        XCTAssertEqual(configureCalls, 0)
        XCTAssertEqual(startCalls, 0)
        XCTAssertFalse(state.isVPNRunning)
        XCTAssertEqual(
            state.tunnelError,
            L("已开启「经 root 中继出网」，但读不到中继凭据。先安装 guard：sudo sh Tools/qingzhou-guard/install.sh")
        )
    }

    func testSetGuardRelayEnabledWhileSplitExitVPNRunningFailsClosedWithoutCredentials() async {
        let state = makeState()
        let exit = exitNode(), hop = hopNode()
        state.nodes = [exit, hop]
        state.settings.proxyMode = .rule
        state.settings.splitExitEnabled = true
        state.settings.splitExitExitNodeID = exit.id
        state.settings.splitExitHopNodeID = hop.id
        state.settings.guardRelayEnabled = false
        state.isVPNRunning = true

        var loaderCalls = 0
        var testNodeCalls = 0
        var configureCalls = 0
        var startCalls = 0
        state.loadGuardRelayCredentials = {
            loaderCalls += 1
            return nil
        }
        state.tunnelManager.onTestNodeConfigAttempt = { testNodeCalls += 1 }
        state.tunnelManager.onConfigureAttempt = { configureCalls += 1 }
        state.tunnelManager.onStartAttempt = { startCalls += 1 }

        state.setGuardRelayEnabled(true)
        for _ in 0..<50 where loaderCalls == 0 || state.tunnelError == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(loaderCalls, 1)
        XCTAssertEqual(testNodeCalls, 0)
        XCTAssertEqual(configureCalls, 0)
        XCTAssertEqual(startCalls, 0)
        XCTAssertTrue(state.isVPNRunning)
        XCTAssertFalse(state.isSwitchingTunnel)
        XCTAssertEqual(
            state.tunnelError,
            L("已开启「经 root 中继出网」，但读不到中继凭据。先安装 guard：sudo sh Tools/qingzhou-guard/install.sh")
        )
    }
    #endif

    func testMakeTestNodeMessageIncludesSplitExitAndNormalPayloads() throws {
        let manager = VPNTunnelManager()
        let exit = exitNode(), hop = hopNode()
        let relay = GuardRelayCredentials(port: 10808, username: "fwd_u", password: "fwd_p")
        let groups = [SplitExitPolicyGroup(name: "G1", target: .exit, domains: ["ai.example.com"])]

        // 1. splitExit == true
        let splitMsg = manager.makeTestNodeMessage(
            node: nil,
            mode: .rule,
            shareLink: "",
            blockQUIC: true,
            splitExit: true,
            splitExitExit: exit,
            splitExitHop: hop,
            guardRelay: relay,
            splitExitPolicyGroups: groups
        )
        XCTAssertEqual(splitMsg["command"], "testNode")
        XCTAssertEqual(splitMsg["splitExit"], "true")
        XCTAssertEqual(splitMsg["blockQUIC"], "true")
        XCTAssertFalse((splitMsg["exitNodeJSON"] ?? "").isEmpty)
        XCTAssertFalse((splitMsg["hopNodeJSON"] ?? "").isEmpty)
        XCTAssertFalse((splitMsg["guardRelayJSON"] ?? "").isEmpty)
        XCTAssertFalse((splitMsg["splitExitPolicyGroupsJSON"] ?? "").isEmpty)

        // 2. splitExit == false
        let normalMsg = manager.makeTestNodeMessage(
            node: hop,
            mode: .rule,
            shareLink: "trojan://pw@hk.example.com:443",
            blockQUIC: false,
            splitExit: false
        )
        XCTAssertEqual(normalMsg["splitExit"], "false")
        XCTAssertEqual(normalMsg["blockQUIC"], "false")
        XCTAssertEqual(normalMsg["exitNodeJSON"], "")
        XCTAssertEqual(normalMsg["hopNodeJSON"], "")
        XCTAssertEqual(normalMsg["guardRelayJSON"], "")
        XCTAssertEqual(normalMsg["splitExitPolicyGroupsJSON"], "")

        // 3. legacy splitExit == nil
        let legacyMsg = manager.makeTestNodeMessage(node: hop, mode: .global, shareLink: "")
        XCTAssertNil(legacyMsg["splitExit"])
        XCTAssertNil(legacyMsg["blockQUIC"])
    }
}
