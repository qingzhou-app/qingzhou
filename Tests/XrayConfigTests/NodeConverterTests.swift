import XCTest
import VPNCore
@testable import XrayConfig

/// Node → xray outbound JSON 转换器的单测。
///
/// 主要验证：
/// 1. 协议字段映射正确（trojan password / vmess uuid+scy / vless uuid+flow / ss method+password）
/// 2. transport 块对应正确（tcp / ws / grpc / h2 / kcp / quic）
/// 3. TLS / REALITY 配置项映射 + SNI / ALPN / fingerprint 等别名识别
/// 4. 错误路径：缺字段 / 错误端口 / 不支持协议 都明确抛错
final class NodeConverterTests: XCTestCase {

    // MARK: - Trojan

    func testTrojanBasicTLS() throws {
        let node = Node(
            name: "trojan-hk", protocolType: .trojan,
            host: "tr.example.com", port: 443,
            password: "pw123",
            parameters: ["sni": "tr.example.com"]
        )
        let out = try NodeConverter.toOutboundDict(node)
        XCTAssertEqual(out["protocol"] as? String, "trojan")
        let server = serverDict(out, key: "servers")
        XCTAssertEqual(server["address"] as? String, "tr.example.com")
        XCTAssertEqual(server["port"] as? Int, 443)
        XCTAssertEqual(server["password"] as? String, "pw123")
        let stream = streamSettings(out)
        XCTAssertEqual(stream["network"] as? String, "tcp")
        XCTAssertEqual(stream["security"] as? String, "tls")
        let tls = stream["tlsSettings"] as! [String: Any]
        XCTAssertEqual(tls["serverName"] as? String, "tr.example.com")
    }

    func testTrojanWebSocket() throws {
        let node = Node(
            name: "trojan-ws", protocolType: .trojan,
            host: "tr.example.com", port: 443,
            password: "pw",
            parameters: ["type": "ws", "path": "/proxy", "host": "cdn.example.com"]
        )
        let stream = streamSettings(try NodeConverter.toOutboundDict(node))
        XCTAssertEqual(stream["network"] as? String, "ws")
        let ws = stream["wsSettings"] as! [String: Any]
        XCTAssertEqual(ws["path"] as? String, "/proxy")
        let headers = ws["headers"] as! [String: String]
        XCTAssertEqual(headers["Host"], "cdn.example.com")
    }

    func testTrojanGRPC() throws {
        let node = Node(
            name: "trojan-grpc", protocolType: .trojan,
            host: "tr.example.com", port: 443,
            password: "pw",
            parameters: ["type": "grpc", "serviceName": "tunnel"]
        )
        let stream = streamSettings(try NodeConverter.toOutboundDict(node))
        XCTAssertEqual(stream["network"] as? String, "grpc")
        let grpc = stream["grpcSettings"] as! [String: Any]
        XCTAssertEqual(grpc["serviceName"] as? String, "tunnel")
    }

    func testTrojanAlpnFingerprintAndNoAllowInsecure() throws {
        let node = Node(
            name: "tr", protocolType: .trojan,
            host: "h", port: 443,
            password: "p",
            parameters: ["sni": "real.example", "allowInsecure": "1",
                         "alpn": "h2,http/1.1", "fp": "chrome"]
        )
        let tls = streamSettings(try NodeConverter.toOutboundDict(node))["tlsSettings"] as! [String: Any]
        XCTAssertEqual(tls["serverName"] as? String, "real.example")
        XCTAssertEqual(tls["alpn"] as? [String], ["h2", "http/1.1"])
        XCTAssertEqual(tls["fingerprint"] as? String, "chrome")
        // 这版 xray-core 移除了 allowInsecure —— 即使链接里带了也绝不能输出，否则 xray 起不来。
        XCTAssertNil(tls["allowInsecure"], "allowInsecure 必须不出现")
    }

    func testTrojanRejectsMissingPassword() {
        let node = Node(name: "n", protocolType: .trojan, host: "h", port: 443, password: nil)
        XCTAssertThrowsError(try NodeConverter.toOutboundDict(node)) { err in
            XCTAssertEqual(err as? NodeConverterError, .missingPassword)
        }
    }

    func testTrojanSecurityNoneDisablesTLSBlock() throws {
        let node = Node(
            name: "tr-plain", protocolType: .trojan,
            host: "h", port: 443,
            password: "p",
            parameters: ["security": "none"]
        )
        let stream = streamSettings(try NodeConverter.toOutboundDict(node))
        XCTAssertEqual(stream["security"] as? String, "none")
        XCTAssertNil(stream["tlsSettings"])
    }

    // MARK: - VMess

    func testVMessBasicTLS() throws {
        let node = Node(
            name: "vmess", protocolType: .vmess,
            host: "v.example.com", port: 443,
            uuid: "11111111-2222-3333-4444-555555555555",
            cipher: "auto",
            alterId: 0,
            parameters: ["type": "ws", "path": "/", "security": "tls"]
        )
        let out = try NodeConverter.toOutboundDict(node)
        XCTAssertEqual(out["protocol"] as? String, "vmess")
        let vnext = serverDict(out, key: "vnext")
        XCTAssertEqual(vnext["address"] as? String, "v.example.com")
        XCTAssertEqual(vnext["port"] as? Int, 443)
        let users = vnext["users"] as! [[String: Any]]
        XCTAssertEqual(users[0]["id"] as? String, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(users[0]["security"] as? String, "auto")
        XCTAssertEqual(users[0]["alterId"] as? Int, 0)
    }

    func testVMessTLSAlsoRecognisesTLSAliasField() throws {
        // 不少 v2rayN vmess 链接用 `tls` 字段而非 `security`
        let node = Node(
            name: "v", protocolType: .vmess,
            host: "h", port: 443,
            uuid: "u",
            parameters: ["net": "ws", "tls": "tls", "sni": "sni.example"]
        )
        let stream = streamSettings(try NodeConverter.toOutboundDict(node))
        XCTAssertEqual(stream["security"] as? String, "tls")
        XCTAssertEqual((stream["tlsSettings"] as! [String: Any])["serverName"] as? String, "sni.example")
    }

    func testVMessHTTP2NetworkNormalisedToH2() throws {
        // vmess 老链接里 net=http 实际是 HTTP/2 transport
        let node = Node(
            name: "v", protocolType: .vmess,
            host: "h", port: 443,
            uuid: "u",
            parameters: ["net": "http", "host": "a.example,b.example", "path": "/h2"]
        )
        let stream = streamSettings(try NodeConverter.toOutboundDict(node))
        XCTAssertEqual(stream["network"] as? String, "h2")
        let http = stream["httpSettings"] as! [String: Any]
        XCTAssertEqual(http["path"] as? String, "/h2")
        XCTAssertEqual(http["host"] as? [String], ["a.example", "b.example"])
    }

    func testVMessRejectsMissingUUID() {
        let node = Node(name: "v", protocolType: .vmess, host: "h", port: 443, uuid: nil)
        XCTAssertThrowsError(try NodeConverter.toOutboundDict(node)) { err in
            XCTAssertEqual(err as? NodeConverterError, .missingUUID)
        }
    }

    // MARK: - VLESS

    func testVLESSBasicTLSEncryptionNone() throws {
        let node = Node(
            name: "vless", protocolType: .vless,
            host: "vl.example.com", port: 443,
            uuid: "abcd-1234",
            parameters: ["security": "tls", "type": "tcp"]
        )
        let out = try NodeConverter.toOutboundDict(node)
        XCTAssertEqual(out["protocol"] as? String, "vless")
        let vnext = serverDict(out, key: "vnext")
        let users = vnext["users"] as! [[String: Any]]
        XCTAssertEqual(users[0]["id"] as? String, "abcd-1234")
        XCTAssertEqual(users[0]["encryption"] as? String, "none")
    }

    func testVLESSWithFlow() throws {
        let node = Node(
            name: "v", protocolType: .vless,
            host: "h", port: 443,
            uuid: "u",
            parameters: ["security": "tls", "flow": "xtls-rprx-vision"]
        )
        let users = serverDict(try NodeConverter.toOutboundDict(node), key: "vnext")["users"] as! [[String: Any]]
        XCTAssertEqual(users[0]["flow"] as? String, "xtls-rprx-vision")
    }

    func testVLESSREALITY() throws {
        let node = Node(
            name: "v", protocolType: .vless,
            host: "real.example", port: 443,
            uuid: "u",
            parameters: [
                "security": "reality",
                "sni": "www.cloudflare.com",
                "pbk": "ABCD-public-key",
                "sid": "deadbeef",
                "fp": "chrome",
                "flow": "xtls-rprx-vision"
            ]
        )
        let stream = streamSettings(try NodeConverter.toOutboundDict(node))
        XCTAssertEqual(stream["security"] as? String, "reality")
        XCTAssertNil(stream["tlsSettings"])
        let reality = stream["realitySettings"] as! [String: Any]
        XCTAssertEqual(reality["serverName"] as? String, "www.cloudflare.com")
        XCTAssertEqual(reality["publicKey"] as? String, "ABCD-public-key")
        XCTAssertEqual(reality["shortId"] as? String, "deadbeef")
        XCTAssertEqual(reality["fingerprint"] as? String, "chrome")
    }

    func testVLESSRejectsMissingUUID() {
        let node = Node(name: "v", protocolType: .vless, host: "h", port: 443, uuid: nil)
        XCTAssertThrowsError(try NodeConverter.toOutboundDict(node)) { err in
            XCTAssertEqual(err as? NodeConverterError, .missingUUID)
        }
    }

    // MARK: - Shadowsocks

    func testShadowsocksBasic() throws {
        let node = Node(
            name: "ss", protocolType: .shadowsocks,
            host: "s.example.com", port: 8388,
            password: "secret",
            cipher: "aes-256-gcm"
        )
        let out = try NodeConverter.toOutboundDict(node)
        XCTAssertEqual(out["protocol"] as? String, "shadowsocks")
        let server = serverDict(out, key: "servers")
        XCTAssertEqual(server["address"] as? String, "s.example.com")
        XCTAssertEqual(server["port"] as? Int, 8388)
        XCTAssertEqual(server["method"] as? String, "aes-256-gcm")
        XCTAssertEqual(server["password"] as? String, "secret")
        // shadowsocks 没有 streamSettings —— 加密在协议层，不走 TLS
        XCTAssertNil(out["streamSettings"])
    }

    func testShadowsocksRejectsMissingPassword() {
        let node = Node(name: "ss", protocolType: .shadowsocks, host: "h", port: 8388,
                        password: nil, cipher: "aes-256-gcm")
        XCTAssertThrowsError(try NodeConverter.toOutboundDict(node)) { err in
            XCTAssertEqual(err as? NodeConverterError, .missingPassword)
        }
    }

    func testShadowsocksRejectsMissingCipher() {
        let node = Node(name: "ss", protocolType: .shadowsocks, host: "h", port: 8388,
                        password: "p", cipher: nil)
        XCTAssertThrowsError(try NodeConverter.toOutboundDict(node)) { err in
            XCTAssertEqual(err as? NodeConverterError, .missingCipher)
        }
    }

    // MARK: - 公共错误路径

    func testRejectsInvalidPort() {
        let node = Node(name: "n", protocolType: .trojan, host: "h", port: 0, password: "p")
        XCTAssertThrowsError(try NodeConverter.toOutboundDict(node)) { err in
            XCTAssertEqual(err as? NodeConverterError, .invalidPort(0))
        }
    }

    func testRejectsHysteria2AsUnsupported() {
        let node = Node(name: "n", protocolType: .hysteria2, host: "h", port: 443, password: "p")
        XCTAssertThrowsError(try NodeConverter.toOutboundDict(node)) { err in
            if case let NodeConverterError.unsupportedProtocol(s) = err {
                XCTAssertEqual(s, "hysteria2")
            } else {
                XCTFail("expected unsupportedProtocol, got \(err)")
            }
        }
    }

    // MARK: - 整体 JSON 输出形态

    func testTopLevelOutboundsJSONShape() throws {
        let node = Node(name: "n", protocolType: .trojan, host: "h", port: 443,
                        password: "p", parameters: ["sni": "s"])
        let json = try NodeConverter.toOutboundsJSON(node)
        let data = json.data(using: .utf8)!
        let parsed = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let outbounds = parsed["outbounds"] as! [[String: Any]]
        XCTAssertEqual(outbounds.count, 1)
        XCTAssertEqual(outbounds[0]["protocol"] as? String, "trojan")
    }

    /// 同一个 Node 转两次应该得到字节相等的 JSON —— 测确定性，避免序列化顺序漂移
    /// 导致 Extension 跟主 App 算出来的 fingerprint 不一致。
    func testConversionIsDeterministic() throws {
        let node = Node(
            name: "n", protocolType: .vmess, host: "h", port: 443,
            uuid: "u",
            parameters: ["net": "ws", "path": "/x", "host": "cdn", "security": "tls", "sni": "sni"]
        )
        let a = try NodeConverter.toOutboundsJSON(node)
        let b = try NodeConverter.toOutboundsJSON(node)
        XCTAssertEqual(a, b)
    }

    /// compose 应该能接住 NodeConverter 的输出 —— 端到端 smoke test
    func testNodeConverterOutputIsAcceptedByComposer() throws {
        let node = Node(
            name: "n", protocolType: .trojan, host: "h", port: 443,
            password: "p", parameters: ["sni": "s"]
        )
        let outbounds = try NodeConverter.toOutboundsJSON(node)
        let composed = try XrayConfigComposer.compose(outboundsJSON: outbounds, mode: .global)
        let parsed = try JSONSerialization.jsonObject(with: composed.data(using: .utf8)!) as! [String: Any]
        XCTAssertNotNil(parsed["inbounds"])
        XCTAssertNotNil(parsed["routing"])
        let outs = parsed["outbounds"] as! [[String: Any]]
        XCTAssertTrue(outs.contains { ($0["tag"] as? String) == "proxy" })
    }

    // MARK: - helpers

    /// 取 settings.servers[0] 或 settings.vnext[0]
    private func serverDict(_ out: [String: Any], key: String) -> [String: Any] {
        let settings = out["settings"] as! [String: Any]
        let list = settings[key] as! [[String: Any]]
        return list[0]
    }

    private func streamSettings(_ out: [String: Any]) -> [String: Any] {
        return out["streamSettings"] as! [String: Any]
    }
}
