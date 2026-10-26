import XCTest
@testable import QingzhouSpeedTest

final class PublicIPTransportTests: XCTestCase {
    func testFramingWaitsForFullBodyAndRejectsTruncation() throws {
        let prefix = Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nabc".utf8)
        XCTAssertNil(try PublicIPHTTPResponse.body(prefix, complete: false))
        XCTAssertThrowsError(try PublicIPHTTPResponse.body(prefix, complete: true))
        XCTAssertEqual(try PublicIPHTTPResponse.body(prefix + Data("de".utf8), complete: false), Data("abcde".utf8))
    }
    func testChunkedJSONAndMalformedChunk() throws {
        let header = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
        XCTAssertEqual(try PublicIPHTTPResponse.body(Data((header + "2\r\n{}\r\n0\r\n\r\n").utf8), complete: false), Data("{}".utf8))
        XCTAssertThrowsError(try PublicIPHTTPResponse.body(Data((header + "2\r\n{}").utf8), complete: true))
        XCTAssertThrowsError(try PublicIPHTTPResponse.body(Data((header + "xyz\r\n").utf8), complete: false))
    }
    func testRejectsErrorsRedirectsCompressionAndOversize() {
        for header in ["HTTP/1.1 429 Limited\r\n", "HTTP/1.1 302 Redirect\r\n", "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\n", "HTTP/1.1 200 OK\r\nContent-Length: 999999\r\n"] {
            XCTAssertThrowsError(try PublicIPHTTPResponse.body(Data((header + "\r\n{}").utf8), complete: true))
        }
    }
}
