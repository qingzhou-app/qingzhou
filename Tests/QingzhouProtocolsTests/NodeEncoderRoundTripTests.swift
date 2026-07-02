import XCTest
import QingzhouCore
@testable import QingzhouProtocols

/// 反向导出（NodeEncoder.shareLink）的 round-trip 保证：
/// `parse(export(node))` 的**语义字段**与原 node 一致。
///
/// 语义相等的口径（而非 Node ==）：
/// - `id` 每次 parse 都新生成（节点身份靠 identityFingerprint）；
/// - `isExcluded / lastLatencyMs / lastTestedAt / subscriptionId` 等运行时状态本就不进链接；
/// 所以逐字段比：name / protocolType / host / port / password / uuid / cipher / alterId / parameters。
final class NodeEncoderRoundTripTests: XCTestCase {

    private func assertRoundTrip(_ node: Node, file: StaticString = #filePath, line: UInt = #line) throws {
        let link = try XCTUnwrap(NodeEncoder.shareLink(node), "export 失败", file: file, line: line)
        let parsed = try ProxyURLParser.parse(link)
        XCTAssertEqual(parsed.name, node.name, "name (\(link))", file: file, line: line)
        XCTAssertEqual(parsed.protocolType, node.protocolType, "protocolType", file: file, line: line)
        XCTAssertEqual(parsed.host, node.host, "host", file: file, line: line)
        XCTAssertEqual(parsed.port, node.port, "port", file: file, line: line)
        XCTAssertEqual(parsed.password, node.password, "password", file: file, line: line)
        XCTAssertEqual(parsed.uuid, node.uuid, "uuid", file: file, line: line)
        XCTAssertEqual(parsed.cipher, node.cipher, "cipher", file: file, line: line)
        XCTAssertEqual(parsed.parameters, node.parameters, "parameters (\(link))", file: file, line: line)
        // alterId 只对 vmess 有意义；导出时 nil → 0，语义等价
        if node.protocolType == .vmess {
            XCTAssertEqual(parsed.alterId ?? 0, node.alterId ?? 0, "alterId", file: file, line: line)
        }
        XCTAssertEqual(parsed.identityFingerprint, node.identityFingerprint, "fingerprint", file: file, line: line)
    }

    // MARK: - 五协议基本 round-trip

    func testTrojanRoundTrip() throws {
        try assertRoundTrip(Node(
            name: "香港 IPLC-01",
            protocolType: .trojan,
            host: "hk.example.com",
            port: 443,
            password: "s3cret-p@ss",
            parameters: ["sni": "hk.example.com", "type": "tcp"]
        ))
    }

    func testShadowsocksRoundTrip() throws {
        try assertRoundTrip(Node(
            name: "SS 东京",
            protocolType: .shadowsocks,
            host: "jp.example.com",
            port: 8388,
            password: "password123",
            cipher: "aes-256-gcm",
            parameters: ["plugin": "obfs-local"]
        ))
    }

    /// ss 凭据 base64 里出现 + / =（标准 base64 的坑字符）也必须 round-trip ——
    /// 导出用 URL-safe 无 padding 变体，parser 的宽松解码两种都认。
    func testShadowsocksCredentialWithBase64UnsafeChars() throws {
        // "chacha20-ietf-poly1305:p?s/w+rd~!" 的标准 base64 含 + 和 /
        try assertRoundTrip(Node(
            name: "SS 特殊密码",
            protocolType: .shadowsocks,
            host: "1.2.3.4",
            port: 443,
            password: "p?s/w+rd~!",
            cipher: "chacha20-ietf-poly1305"
        ))
    }

    func testVMessRoundTrip() throws {
        try assertRoundTrip(Node(
            name: "vmess 美国-西雅图 01",
            protocolType: .vmess,
            host: "us.example.com",
            port: 443,
            uuid: "b831381d-6324-4d53-ad4f-8cda48b30811",
            cipher: "auto",
            alterId: 0,
            parameters: ["net": "ws", "path": "/ray", "tls": "tls", "host": "cdn.example.com", "sni": "us.example.com"]
        ))
    }

    func testVLESSRoundTrip() throws {
        try assertRoundTrip(Node(
            name: "vless-reality 新加坡",
            protocolType: .vless,
            host: "sg.example.com",
            port: 8443,
            uuid: "27848739-7e62-4138-9fd3-098a63964b6b",
            parameters: [
                "encryption": "none", "security": "reality", "flow": "xtls-rprx-vision",
                "sni": "www.microsoft.com", "fp": "chrome", "pbk": "SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc",
                "sid": "6ba85179e30d4fc2", "type": "tcp"
            ]
        ))
    }

    func testHysteria2RoundTrip() throws {
        try assertRoundTrip(Node(
            name: "hy2 洛杉矶",
            protocolType: .hysteria2,
            host: "la.example.com",
            port: 34523,
            password: "letmein",
            parameters: ["sni": "la.example.com", "insecure": "0"]
        ))
    }

    // MARK: - 边界

    /// 名称带空格 / 中文 / emoji —— fragment percent-encode 后要能原样回来。
    func testNameWithSpacesAndUnicode() throws {
        for proto in [ProxyProtocol.trojan, .vless, .hysteria2] {
            try assertRoundTrip(Node(
                name: "🇭🇰 香港 BGP · x2 倍率",
                protocolType: proto,
                host: "edge.example.com",
                port: 443,
                password: proto == .vless ? nil : "pw",
                uuid: proto == .vless ? "27848739-7e62-4138-9fd3-098a63964b6b" : nil
            ))
        }
    }

    /// 密码带 URL 保留字符（`:` 尤其毒 —— userinfo 宽松编码不转义它，会被当成
    /// user:password 分隔符截断；export 必须严格 percent-encode）。
    func testPasswordWithReservedCharacters() throws {
        try assertRoundTrip(Node(
            name: "特殊密码",
            protocolType: .trojan,
            host: "a.example.com",
            port: 443,
            password: "p@ss:w0rd/with?odd&chars=+"
        ))
    }

    /// 密码里含字面 `%`：解析侧曾经双重 percent-decode（URLComponents 已解一次，再
    /// removingPercentEncoding 一次），"100%" 会解成 nil、"a%20b" 会被错改成 "a b"。
    func testPasswordWithLiteralPercent() throws {
        try assertRoundTrip(Node(
            name: "百分号密码",
            protocolType: .trojan,
            host: "a.example.com",
            port: 443,
            password: "100%pass%20word"
        ))
    }

    /// IPv4 裸地址 host。
    func testIPv4Host() throws {
        try assertRoundTrip(Node(
            name: "裸 IP",
            protocolType: .trojan,
            host: "203.0.113.7",
            port: 443,
            password: "pw"
        ))
    }

    /// 链接级 round-trip 的强性质：export(parse(link)) 再 parse 一次，两次 parse 结果
    /// 语义一致（对真实来源链接的稳定性 —— 不要求字符串完全一致，只要求信息不丢）。
    func testLinkLevelStability() throws {
        let links = [
            "trojan://my%20pass@example.com:443?sni=example.com&type=tcp#%E9%A6%99%E6%B8%AF",
            "ss://YWVzLTEyOC1nY206cGFzc3dvcmQ=@1.2.3.4:8388#SS-Node",
            "vless://27848739-7e62-4138-9fd3-098a63964b6b@sg.example.com:8443?encryption=none&security=tls&sni=sg.example.com&type=ws&path=%2Fws#SG",
            "hysteria2://letmein@la.example.com:34523?sni=la.example.com#LA"
        ]
        for link in links {
            let first = try ProxyURLParser.parse(link)
            let reexported = try XCTUnwrap(NodeEncoder.shareLink(first))
            let second = try ProxyURLParser.parse(reexported)
            XCTAssertEqual(second.name, first.name, link)
            XCTAssertEqual(second.protocolType, first.protocolType, link)
            XCTAssertEqual(second.host, first.host, link)
            XCTAssertEqual(second.port, first.port, link)
            XCTAssertEqual(second.password, first.password, link)
            XCTAssertEqual(second.uuid, first.uuid, link)
            XCTAssertEqual(second.cipher, first.cipher, link)
            XCTAssertEqual(second.parameters, first.parameters, link)
        }
    }

    /// vmess 链接级 round-trip（base64(json) 形式单独验）：含 aid / scy / ws 参数。
    func testVMessLinkLevelStability() throws {
        let json = """
        {"v":"2","ps":"US-01","add":"us.example.com","port":"443","id":"b831381d-6324-4d53-ad4f-8cda48b30811",\
        "aid":2,"scy":"aes-128-gcm","net":"ws","path":"/ray","tls":"tls","host":"cdn.example.com"}
        """
        let link = "vmess://" + Data(json.utf8).base64EncodedString()
        let first = try ProxyURLParser.parse(link)
        let reexported = try XCTUnwrap(NodeEncoder.shareLink(first))
        let second = try ProxyURLParser.parse(reexported)
        XCTAssertEqual(second.name, "US-01")
        XCTAssertEqual(second.alterId, 2)
        XCTAssertEqual(second.cipher, "aes-128-gcm")
        XCTAssertEqual(second.parameters, first.parameters)
        XCTAssertEqual(second.identityFingerprint, first.identityFingerprint)
    }

    // MARK: - 批量导出

    func testShareLinksBatchExport() throws {
        let nodes = [
            Node(name: "A", protocolType: .trojan, host: "a.example.com", port: 443, password: "pw1"),
            Node(name: "B", protocolType: .vless, host: "b.example.com", port: 443,
                 uuid: "27848739-7e62-4138-9fd3-098a63964b6b"),
            Node(name: "C", protocolType: .shadowsocks, host: "c.example.com", port: 8388,
                 password: "pw3", cipher: "aes-256-gcm")
        ]
        let text = NodeEncoder.shareLinks(nodes)
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        // 批量导出的产物必须能被 parseBatch 全量吃回来
        let (parsed, errors) = ProxyURLParser.parseBatch(text)
        XCTAssertTrue(errors.isEmpty, "\(errors)")
        XCTAssertEqual(parsed.map(\.name), ["A", "B", "C"])
    }
}
