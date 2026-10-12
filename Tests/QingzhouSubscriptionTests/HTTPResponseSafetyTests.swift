import XCTest
@testable import QingzhouSubscription

private final class ResponseProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let code = Int(request.url!.lastPathComponent)!
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("trojan://pw@fixture.invalid:443#A".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class HTTPResponseSafetyTests: XCTestCase {
    func testHTTPErrorWithValidLookingBodyIsRejected() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResponseProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = URLSessionHTTPClient(session: session)
        for code in [403, 404, 500] {
            do {
                _ = try await client.get(URL(string: "https://fixture.invalid/\(code)")!)
                XCTFail("HTTP \(code) 不可被当成成功订阅")
            } catch let error as SubscriptionRefreshError {
                guard case .httpStatus(let status) = error else { return XCTFail("应提供状态码") }
                XCTAssertEqual(status, code)
            }
        }
    }
}
