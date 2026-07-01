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
                "spx": "/spider",
                "fp": "chrome",
                "flow": "xtls-rprx-vision"
            ]
        )
        let out = try NodeConverter.toOutboundDict(node)
        // user 里必须带 flow + encryption=none
        let users = serverDict(out, key: "vnext")["users"] as! [[String: Any]]
        XCTAssertEqual(users[0]["flow"] as? String, "xtls-rprx-vision")
        XCTAssertEqual(users[0]["encryption"] as? String, "none")

        let stream = streamSettings(out)
        XCTAssertEqual(stream["security"] as? String, "reality")
        // reality 与 tls 互斥：绝不能输出 tlsSettings
        XCTAssertNil(stream["tlsSettings"])
        let reality = stream["realitySettings"] as! [String: Any]
        XCTAssertEqual(reality["serverName"] as? String, "www.cloudflare.com")
        XCTAssertEqual(reality["publicKey"] as? String, "ABCD-public-key")
        XCTAssertEqual(reality["shortId"] as? String, "deadbeef")
        XCTAssertEqual(reality["spiderX"] as? String, "/spider")
        XCTAssertEqual(reality["fingerprint"] as? String, "chrome")
        // 这版 xray-core 移除了 allowInsecure —— reality 块里也绝不能出现
        XCTAssertNil(reality["allowInsecure"], "allowInsecure 必须不出现")
    }

    /// 分享链接缺 fp / spx 时，realitySettings 用默认值 chrome / "/"。
    func testVLESSREALITYDefaultsFingerprintAndSpiderX() throws {
        let node = Node(
            name: "v", protocolType: .vless,
            host: "real.example", port: 443,
            uuid: "u",
            parameters: [
                "security": "reality",
                "sni": "www.apple.com",
                "pbk": "pubkey",
                "sid": "abcd"
                // 故意不带 fp / spx
            ]
        )
        let reality = streamSettings(try NodeConverter.toOutboundDict(node))["realitySettings"] as! [String: Any]
        XCTAssertEqual(reality["serverName"] as? String, "www.apple.com")
        XCTAssertEqual(reality["fingerprint"] as? String, "chrome")
        XCTAssertEqual(reality["spiderX"] as? String, "/")
    }

    /// reality 节点里带 flow=xtls-rprx-vision + 完整 realitySettings 的形态校验。
    /// （分享链接 → Node 的端到端解析在 VPNProtocolsTests 里覆盖，这里只测 Node → outbound。）
    func testVLESSREALITYWithSpiderXAndTCP() throws {
        let node = Node(
            name: "reality", protocolType: .vless,
            host: "real.example.com", port: 443,
            uuid: "u-1234",
            parameters: [
                "encryption": "none",
                "flow": "xtls-rprx-vision",
                "security": "reality",
                "sni": "www.microsoft.com",
                "fp": "chrome",
                "pbk": "share-pbk",
                "sid": "00ff",
                "spx": "/",
                "type": "tcp"
            ]
        )
        let out = try NodeConverter.toOutboundDict(node)
        XCTAssertEqual(out["protocol"] as? String, "vless")
        let users = serverDict(out, key: "vnext")["users"] as! [[String: Any]]
        XCTAssertEqual(users[0]["flow"] as? String, "xtls-rprx-vision")
        XCTAssertEqual(users[0]["encryption"] as? String, "none")
        let stream = streamSettings(out)
        XCTAssertEqual(stream["network"] as? String, "tcp")
        XCTAssertEqual(stream["security"] as? String, "reality")
        XCTAssertNil(stream["tlsSettings"])
        let reality = stream["realitySettings"] as! [String: Any]
        XCTAssertEqual(reality["serverName"] as? String, "www.microsoft.com")
        XCTAssertEqual(reality["publicKey"] as? String, "share-pbk")
        XCTAssertEqual(reality["shortId"] as? String, "00ff")
        XCTAssertEqual(reality["spiderX"] as? String, "/")
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

    // MARK: - Hysteria2

    /// hysteria2 outbound 形态：协议名 "hysteria"、settings 只放 server endpoint + version=2、
    /// 口令落在 streamSettings.hysteriaSettings.auth、network "hysteria" + TLS。
    func testHysteria2BasicShape() throws {
        let node = Node(
            name: "hy2", protocolType: .hysteria2,
            host: "hy.example.com", port: 36500,
            password: "pwd123",
            parameters: ["sni": "hy.example.com"]
        )
        let out = try NodeConverter.toOutboundDict(node)
        XCTAssertEqual(out["protocol"] as? String, "hysteria")

        // settings = HysteriaClientConfig：version + address + port，没有密码
        let settings = out["settings"] as! [String: Any]
        XCTAssertEqual(settings["version"] as? Int, 2)
        XCTAssertEqual(settings["address"] as? String, "hy.example.com")
        XCTAssertEqual(settings["port"] as? Int, 36500)
        XCTAssertNil(settings["password"], "settings 里不放密码 —— 口令只在 hysteriaSettings.auth")
        XCTAssertNil(settings["auth"])

        let stream = streamSettings(out)
        XCTAssertEqual(stream["network"] as? String, "hysteria")
        XCTAssertEqual(stream["security"] as? String, "tls")

        let tls = stream["tlsSettings"] as! [String: Any]
        XCTAssertEqual(tls["serverName"] as? String, "hy.example.com")

        // hysteriaSettings = HysteriaConfig：version=2 + auth=口令
        let hy = stream["hysteriaSettings"] as! [String: Any]
        XCTAssertEqual(hy["version"] as? Int, 2)
        XCTAssertEqual(hy["auth"] as? String, "pwd123")
    }

    /// hy2 链接常带 insecure=1（自签证书），Clash 转出来会是 allowInsecure=1 ——
    /// 这版 xray-core 移除了该字段，转换器必须在任何层级都不产出它。
    func testHysteria2NeverEmitsAllowInsecure() throws {
        let node = Node(
            name: "hy2", protocolType: .hysteria2,
            host: "hy.example.com", port: 443,
            password: "pwd",
            parameters: ["sni": "real.example", "insecure": "1", "allowInsecure": "1"]
        )
        let out = try NodeConverter.toOutboundDict(node)
        // 递归扫整棵 outbound，确保哪儿都没有 allowInsecure / insecure 漏出去
        assertNoKeyAnywhere(out, key: "allowInsecure")
        assertNoKeyAnywhere(out, key: "insecure")
        // SNI 仍按链接里的 sni 走
        let tls = streamSettings(out)["tlsSettings"] as! [String: Any]
        XCTAssertEqual(tls["serverName"] as? String, "real.example")
    }

    /// 没给 alpn 时默认 h3（hysteria2 就是 HTTP/3 over QUIC）。
    func testHysteria2DefaultsAlpnToH3() throws {
        let node = Node(
            name: "hy2", protocolType: .hysteria2,
            host: "hy.example.com", port: 443,
            password: "pwd"
        )
        let tls = streamSettings(try NodeConverter.toOutboundDict(node))["tlsSettings"] as! [String: Any]
        XCTAssertEqual(tls["alpn"] as? [String], ["h3"])
        // 没给 sni 时退回节点 host
        XCTAssertEqual(tls["serverName"] as? String, "hy.example.com")
    }

    /// 链接显式给了 alpn / fp 时尊重链接。
    func testHysteria2RespectsExplicitAlpnAndFingerprint() throws {
        let node = Node(
            name: "hy2", protocolType: .hysteria2,
            host: "h", port: 443,
            password: "pwd",
            parameters: ["alpn": "h3,h2", "fp": "chrome"]
        )
        let tls = streamSettings(try NodeConverter.toOutboundDict(node))["tlsSettings"] as! [String: Any]
        XCTAssertEqual(tls["alpn"] as? [String], ["h3", "h2"])
        XCTAssertEqual(tls["fingerprint"] as? String, "chrome")
    }

    /// udpIdleTimeout 合法(2...600)才透传，非法值忽略。
    func testHysteria2UdpIdleTimeout() throws {
        let valid = Node(name: "h", protocolType: .hysteria2, host: "h", port: 443,
                         password: "pwd", parameters: ["udpIdleTimeout": "120"])
        let hyValid = streamSettings(try NodeConverter.toOutboundDict(valid))["hysteriaSettings"] as! [String: Any]
        XCTAssertEqual(hyValid["udpIdleTimeout"] as? Int, 120)

        // 越界 / 非数字 → 不透传，让 xray 用默认 60
        for bad in ["1", "601", "abc"] {
            let node = Node(name: "h", protocolType: .hysteria2, host: "h", port: 443,
                            password: "pwd", parameters: ["udpIdleTimeout": bad])
            let hy = streamSettings(try NodeConverter.toOutboundDict(node))["hysteriaSettings"] as! [String: Any]
            XCTAssertNil(hy["udpIdleTimeout"], "非法 udpIdleTimeout=\(bad) 不应透传")
        }
    }

    func testHysteria2RejectsMissingPassword() {
        let node = Node(name: "hy2", protocolType: .hysteria2, host: "h", port: 443, password: nil)
        XCTAssertThrowsError(try NodeConverter.toOutboundDict(node)) { err in
            XCTAssertEqual(err as? NodeConverterError, .missingPassword)
        }
    }

    /// compose 应该能接住 hysteria2 的 outbound 输出，且最终配置里没有 allowInsecure。
    func testHysteria2OutputIsAcceptedByComposer() throws {
        let node = Node(
            name: "hy2", protocolType: .hysteria2,
            host: "hy.example.com", port: 443,
            password: "pwd",
            parameters: ["sni": "hy.example.com", "insecure": "1"]
        )
        let outbounds = try NodeConverter.toOutboundsJSON(node)
        let composed = try XrayConfigComposer.compose(outboundsJSON: outbounds, mode: .global)
        let parsed = try JSONSerialization.jsonObject(with: composed.data(using: .utf8)!) as! [String: Any]
        let outs = parsed["outbounds"] as! [[String: Any]]
        let proxy = outs.first { ($0["tag"] as? String) == "proxy" }!
        XCTAssertEqual(proxy["protocol"] as? String, "hysteria")
        assertNoKeyAnywhere(parsed, key: "allowInsecure")
    }

    // MARK: - 公共错误路径

    func testRejectsInvalidPort() {
        let node = Node(name: "n", protocolType: .trojan, host: "h", port: 0, password: "p")
        XCTAssertThrowsError(try NodeConverter.toOutboundDict(node)) { err in
            XCTAssertEqual(err as? NodeConverterError, .invalidPort(0))
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

    /// 递归断言整棵 JSON 对象里不存在某个 key（用于证明 allowInsecure 哪儿都没漏出去）。
    private func assertNoKeyAnywhere(_ obj: Any, key: String,
                                    file: StaticString = #file, line: UInt = #line) {
        switch obj {
        case let dict as [String: Any]:
            XCTAssertNil(dict[key], "意外出现 key=\(key)", file: file, line: line)
            for value in dict.values { assertNoKeyAnywhere(value, key: key, file: file, line: line) }
        case let array as [Any]:
            for element in array { assertNoKeyAnywhere(element, key: key, file: file, line: line) }
        default:
            break
        }
    }
}
