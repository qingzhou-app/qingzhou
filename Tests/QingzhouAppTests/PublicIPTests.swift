import XCTest
import Foundation
import QingzhouCore
import QingzhouLogging
@testable import QingzhouApp

private final class IPErrorResponseProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"ip":"203.0.113.1","error":true}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class PublicIPTests: XCTestCase {
    func testRateLimitedResponseCannotBecomeAnExitIP() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [IPErrorResponseProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await NetworkInfoService(session: session).fetchPublicIPInfo()
            XCTFail("An HTTP error must not become a successful exit measurement")
        } catch { }
    }

    @MainActor
    func testNetworkChangeInvalidatesBothCachedExits() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = AppState(logger: Logger(), persistence: Persistence(directory: dir))
        state.directIPInfo = PublicIPInfo(ip: "203.0.113.1")
        state.proxyIPInfo = PublicIPInfo(ip: "203.0.113.2")
        state.measurementNetworkDidChange()
        XCTAssertNil(state.directIPInfo)
        XCTAssertNil(state.proxyIPInfo)
    }
}

@MainActor
final class PublicIPAttributionTests: XCTestCase {
    private func make() -> AppState {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return AppState(persistence: Persistence(directory: dir))
    }
    func testContradictingHeartbeatClearsAlreadyDisplayedProxyExit() throws {
        let app = make()
        try app.addNode(fromURL: "trojan://pw@example.com:443#test")
        app.isVPNRunning = true
        let applied = AppliedTunnelConfiguration(node: app.nodes[0], mode: .rule, blockQUIC: true)
        app.syncAppliedConfiguration(session: TunnelSessionInfo(startedAt: Date(), autoStopSeconds: 0, appliedConfiguration: applied), status: .connected)
        app.proxyIPInfo = PublicIPInfo(ip: "203.0.113.2")
        app.publicIPInfo = app.proxyIPInfo
        app.ingestTrafficStats(TrafficStats(configurationID: UUID()))
        XCTAssertNil(app.appliedTunnelConfiguration)
        XCTAssertNil(app.proxyIPInfo)
        XCTAssertNil(app.publicIPInfo)
        app.persistence.waitForPendingWritesForTesting()
    }
    func testGeolocationProviderRejectsFailureAndPreservesDetails() throws {
        XCTAssertThrowsError(try NetworkInfoService.decode(Data(#"{"success":false,"ip":"203.0.113.1"}"#.utf8)))
        let result = try NetworkInfoService.decode(Data(#"{"success":true,"ip":"203.0.113.1","country":"China","city":"Beijing","region":"Beijing","connection":{"isp":"Example ISP"}}"#.utf8))
        XCTAssertEqual(result.country, "China")
        XCTAssertEqual(result.city, "Beijing")
        XCTAssertEqual(result.isp, "Example ISP")
    }
    func testLateResultFromOldRefreshCannotOverwriteNewResult() async {
        let app = make(), gate = CloudIOGate()
        let old = Task { await app.refreshPublicIPInfo(direct: {
            await gate.suspend(); return PublicIPInfo(ip: "203.0.113.1")
        }, proxy: { _ in XCTFail("Disconnected must not query a node"); throw URLError(.unknown) }) }
        await gate.waitUntilEntered()
        await app.refreshPublicIPInfo(direct: { PublicIPInfo(ip: "203.0.113.2") }, proxy: { _ in throw URLError(.unknown) })
        await gate.resume(); await old.value
        XCTAssertEqual(app.directIPInfo?.ip, "203.0.113.2")
        XCTAssertNil(app.proxyIPInfo)
    }
    func testNetworkChangesDiscardInFlightDirectResult() async {
        let app = make(), gate = CloudIOGate()
        let work = Task { await app.refreshPublicIPInfo(direct: {
            await gate.suspend(); return PublicIPInfo(ip: "203.0.113.1")
        }, proxy: { _ in throw URLError(.unknown) }) }
        await gate.waitUntilEntered(); app.measurementNetworkDidChange()
        await gate.resume(); await work.value
        XCTAssertNil(app.directIPInfo)
        XCTAssertNil(app.publicIPInfo)
    }
    func testSeparateExitResultsAndFailureNeverFallsBack() async {
        let app = make()
        try? app.addNode(fromURL: "trojan://pw@example.com:443#test")
        let node = app.nodes[0]
        app.isVPNRunning = true
        let applied = AppliedTunnelConfiguration(node: node, mode: .direct, blockQUIC: true)
        app.syncAppliedConfiguration(session: TunnelSessionInfo(startedAt: Date(), autoStopSeconds: 0, appliedConfiguration: applied), status: .connected)
        await app.refreshPublicIPInfo(direct: { PublicIPInfo(ip: "203.0.113.1") }, proxy: { id in
            XCTAssertEqual(id, applied.id); return PublicIPInfo(ip: "203.0.113.2")
        })
        XCTAssertEqual(app.directIPInfo?.ip, "203.0.113.1")
        XCTAssertEqual(app.proxyIPInfo?.ip, "203.0.113.2")
        await app.refreshPublicIPInfo(direct: { throw URLError(.timedOut) }, proxy: { _ in PublicIPInfo(ip: "203.0.113.3") })
        XCTAssertNil(app.directIPInfo)
        XCTAssertTrue(app.directIPFailed)
        XCTAssertEqual(app.proxyIPInfo?.ip, "203.0.113.3")
        app.persistence.waitForPendingWritesForTesting()
    }
    func testDisconnectDuringProxyQueryCannotPopulateDirect() async {
        let app = make(), gate = CloudIOGate()
        try? app.addNode(fromURL: "trojan://pw@example.com:443#test")
        app.isVPNRunning = true
        let applied = AppliedTunnelConfiguration(node: app.nodes[0], mode: .rule, blockQUIC: true)
        app.syncAppliedConfiguration(session: TunnelSessionInfo(startedAt: Date(), autoStopSeconds: 0, appliedConfiguration: applied), status: .connected)
        let work = Task { await app.refreshPublicIPInfo(direct: { throw URLError(.timedOut) }, proxy: { _ in
            await gate.suspend(); return PublicIPInfo(ip: "203.0.113.2")
        }) }
        await gate.waitUntilEntered(); app.isVPNRunning = false
        await gate.resume(); await work.value
        XCTAssertNil(app.directIPInfo); XCTAssertNil(app.proxyIPInfo)
        app.persistence.waitForPendingWritesForTesting()
    }
}
