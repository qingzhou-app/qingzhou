import XCTest
import QingzhouCore
@testable import QingzhouProtocols

/// SOCKS5 节点解析 + 出站生成（静态住宅代理的入口协议）。
final class Socks5ParserTests: XCTestCase {

    func testParsesWithCredentials() throws {
        let node = try ProxyURLParser.parse("socks5://user1:p%40ss@1.2.3.4:1080#住宅%20A")
        XCTAssertEqual(node.protocolType, .socks5)
        XCTAssertEqual(node.host, "1.2.3.4")
        XCTAssertEqual(node.port, 1080)
        XCTAssertEqual(node.parameters["username"], "user1")
        XCTAssertEqual(node.password, "p@ss", "密码里的 %40 只能解码一次，得到 @")
        XCTAssertEqual(node.name, "住宅 A")
    }

    func testParsesWithoutAuthentication() throws {
        let node = try ProxyURLParser.parse("socks5://127.0.0.1:1080")
        XCTAssertEqual(node.protocolType, .socks5)
        XCTAssertNil(node.parameters["username"])
        XCTAssertNil(node.password)
        XCTAssertEqual(node.name, "127.0.0.1:1080")
    }

    func testSocksAliasSchemes() throws {
        for scheme in ["socks", "socks5h", "SOCKS5"] {
            let node = try ProxyURLParser.parse("\(scheme)://u:p@example.com:1080")
            XCTAssertEqual(node.protocolType, .socks5, scheme)
        }
    }

    /// 只给了一半凭据 = 链接写坏了（常见于密码含 @ 未转义）。宁可报错，也别静默当无认证 ——
    /// 那会变成"连得上但被代理拒绝"，比解析失败难查得多。
    func testHalfCredentialsRejected() {
        for url in ["socks5://user@example.com:1080", "socks5://:pass@example.com:1080"] {
            XCTAssertThrowsError(try ProxyURLParser.parse(url), url) { error in
                XCTAssertEqual(error as? ProxyURLParseError, .missingCredential)
            }
        }
    }

    func testMissingPortRejected() {
        XCTAssertThrowsError(try ProxyURLParser.parse("socks5://example.com")) { error in
            XCTAssertEqual(error as? ProxyURLParseError, .missingPort)
        }
    }

    func testClashYAMLSocks5Node() throws {
        let yaml = """
        proxies:
          - name: 住宅出口
            type: socks5
            server: 1.2.3.4
            port: 1080
            username: u1
            password: "p1"
        """
        let (nodes, errors) = try ClashConfigParser.parse(yaml)
        XCTAssertTrue(errors.isEmpty, "\(errors)")
        let node = try XCTUnwrap(nodes.first)
        XCTAssertEqual(node.protocolType, .socks5)
        XCTAssertEqual(node.parameters["username"], "u1")
        XCTAssertEqual(node.password, "p1")
    }
}
