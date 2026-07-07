import XCTest
import QingzhouCore
@testable import QingzhouProtocols

final class ClashConfigParserTests: XCTestCase {

    func testDetectClashConfig() {
        let yaml = """
        proxies:
          - name: a
            type: trojan
        """
        XCTAssertTrue(ClashConfigParser.isClashConfig(yaml))
    }

    func testParseVLESSRealityFromClash() throws {
        // Clash.Meta vless+reality —— 旧实现漏抽 reality-opts，节点走 Clash 订阅连不上（审计 P1）
        let yaml = """
        proxies:
          - name: 🇭🇰 香港 reality
            type: vless
            server: hk.example.com
            port: 443
            uuid: 11111111-2222-3333-4444-555555555555
            network: tcp
            tls: true
            servername: www.microsoft.com
            flow: xtls-rprx-vision
            client-fingerprint: chrome
            alpn: [h2, http/1.1]
            reality-opts:
              public-key: abcdefPUBKEYxyz
              short-id: 0123abcd
        """
        let (nodes, errs) = try ClashConfigParser.parse(yaml)
        XCTAssertTrue(errs.isEmpty)
        let node = try XCTUnwrap(nodes.first)
        XCTAssertEqual(node.protocolType, .vless)
        XCTAssertEqual(node.parameters["security"], "reality", "reality-opts 存在时 security 应是 reality（覆盖 tls）")
        XCTAssertEqual(node.parameters["pbk"], "abcdefPUBKEYxyz")
        XCTAssertEqual(node.parameters["sid"], "0123abcd")
        XCTAssertEqual(node.parameters["fp"], "chrome")
        XCTAssertEqual(node.parameters["sni"], "www.microsoft.com")
        XCTAssertEqual(node.parameters["flow"], "xtls-rprx-vision")
        XCTAssertEqual(node.parameters["alpn"], "h2,http/1.1")
    }

    func testDetectClashProviders() {
        let yaml = """
        proxy-providers:
          inline:
            type: http
            payload:
              - name: x
                type: trojan
                server: h
                port: 443
                password: pw
        """
        XCTAssertTrue(ClashConfigParser.isClashConfig(yaml))
    }

    func testDoesNotMatchPlainLinks() {
        let text = "trojan://pw@x.com:443\nss://abc@y.com:8388"
        XCTAssertFalse(ClashConfigParser.isClashConfig(text))
    }

    func testParseTrojan() throws {
        let yaml = """
        proxies:
          - name: HK01
            type: trojan
            server: hk.example.com
            port: 443
            password: secret
            sni: hk.example.com
            skip-cert-verify: true
            network: ws
            ws-opts:
              path: /trojan
              headers:
                Host: hk.example.com
        """
        let (nodes, errors) = try ClashConfigParser.parse(yaml)
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(nodes.count, 1)
        let n = nodes[0]
        XCTAssertEqual(n.name, "HK01")
        XCTAssertEqual(n.protocolType, .trojan)
        XCTAssertEqual(n.host, "hk.example.com")
        XCTAssertEqual(n.port, 443)
        XCTAssertEqual(n.password, "secret")
        XCTAssertEqual(n.parameters["sni"], "hk.example.com")
        XCTAssertEqual(n.parameters["allowInsecure"], "1")
        XCTAssertEqual(n.parameters["net"], "ws")
        XCTAssertEqual(n.parameters["path"], "/trojan")
        XCTAssertEqual(n.parameters["host"], "hk.example.com")
    }

    func testParseShadowsocks() throws {
        let yaml = """
        proxies:
          - name: SS-1
            type: ss
            server: ss.example.com
            port: 8388
            cipher: aes-256-gcm
            password: sspw
        """
        let (nodes, _) = try ClashConfigParser.parse(yaml)
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes[0].protocolType, .shadowsocks)
        XCTAssertEqual(nodes[0].cipher, "aes-256-gcm")
        XCTAssertEqual(nodes[0].password, "sspw")
    }

    func testParseVMess() throws {
        let yaml = """
        proxies:
          - name: VM-WS
            type: vmess
            server: vm.example.com
            port: 443
            uuid: 11111111-2222-3333-4444-555555555555
            alterId: 0
            cipher: auto
            tls: true
            servername: vm.example.com
            network: ws
            ws-opts:
              path: /ray
        """
        let (nodes, _) = try ClashConfigParser.parse(yaml)
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes[0].protocolType, .vmess)
        XCTAssertEqual(nodes[0].uuid, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(nodes[0].alterId, 0)
        XCTAssertEqual(nodes[0].cipher, "auto")
        XCTAssertEqual(nodes[0].parameters["tls"], "tls")
        XCTAssertEqual(nodes[0].parameters["sni"], "vm.example.com")
        XCTAssertEqual(nodes[0].parameters["net"], "ws")
        XCTAssertEqual(nodes[0].parameters["path"], "/ray")
    }

    func testParseVLESS() throws {
        let yaml = """
        proxies:
          - name: VL
            type: vless
            server: vl.example.com
            port: 443
            uuid: abcd-1234
            tls: true
            servername: vl.example.com
            flow: xtls-rprx-vision
            network: grpc
            grpc-opts:
              grpc-service-name: srv
        """
        let (nodes, _) = try ClashConfigParser.parse(yaml)
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes[0].protocolType, .vless)
        XCTAssertEqual(nodes[0].uuid, "abcd-1234")
        XCTAssertEqual(nodes[0].parameters["security"], "tls")
        XCTAssertEqual(nodes[0].parameters["flow"], "xtls-rprx-vision")
        XCTAssertEqual(nodes[0].parameters["serviceName"], "srv")
    }

    func testParseHysteria2() throws {
        let yaml = """
        proxies:
          - name: HY2
            type: hysteria2
            server: hy.example.com
            port: 36500
            password: hypw
            sni: hy.example.com
        """
        let (nodes, _) = try ClashConfigParser.parse(yaml)
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes[0].protocolType, .hysteria2)
        XCTAssertEqual(nodes[0].password, "hypw")
        XCTAssertEqual(nodes[0].parameters["sni"], "hy.example.com")
    }

    /// Clash.Meta hysteria2 扩展字段：obfs / obfs-password / ports(端口跳跃) / up / down
    /// 都要映射进 parameters —— 不映射 obfs = 带混淆的 hy2 节点转出来握手必失败
    ///（机场兼容审计遗留，对应 share link 路径的同名参数）。
    func testParseHysteria2ObfsAndPortHopping() throws {
        let yaml = """
        proxies:
          - name: HY2-OBFS
            type: hysteria2
            server: hy.example.com
            port: 443
            ports: 443,5000-6000
            password: hypw
            obfs: salamander
            obfs-password: obpw
            up: 100
            down: 500 Mbps
        """
        let (nodes, errs) = try ClashConfigParser.parse(yaml)
        XCTAssertTrue(errs.isEmpty)
        let n = try XCTUnwrap(nodes.first)
        XCTAssertEqual(n.parameters["obfs"], "salamander")
        XCTAssertEqual(n.parameters["obfs-password"], "obpw")
        XCTAssertEqual(n.parameters["mport"], "443,5000-6000", "Clash 的 ports 统一映射到 mport 键")
        XCTAssertEqual(n.parameters["up"], "100")
        XCTAssertEqual(n.parameters["down"], "500 Mbps")
    }

    func testParseUnsupportedTypeSkippedSilently() throws {
        let yaml = """
        proxies:
          - name: SnellNode
            type: snell
            server: x
            port: 1
            psk: y
          - name: Good
            type: trojan
            server: y
            port: 443
            password: pw
        """
        let (nodes, errors) = try ClashConfigParser.parse(yaml)
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes[0].name, "Good")
        XCTAssertTrue(errors.isEmpty, "未知 type 静默跳过，不算错误")
    }

    func testParseInvalidEntryCollectsError() throws {
        let yaml = """
        proxies:
          - name: missing-server
            type: trojan
            port: 443
            password: pw
          - name: ok
            type: trojan
            server: h
            port: 443
            password: pw
        """
        let (nodes, errors) = try ClashConfigParser.parse(yaml)
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors[0].name, "missing-server")
    }

    func testParseRejectsNonClash() {
        XCTAssertThrowsError(try ClashConfigParser.parse("rules:\n  - DOMAIN,a.com,PROXY"))
    }

    func testParseProviderInlinePayload() throws {
        let yaml = """
        proxy-providers:
          local:
            type: http
            payload:
              - name: PA
                type: trojan
                server: pa.example
                port: 443
                password: pw
        """
        let (nodes, _) = try ClashConfigParser.parse(yaml)
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes[0].name, "PA")
    }

    func testPortAsStringStillParses() throws {
        let yaml = """
        proxies:
          - name: PS
            type: trojan
            server: x
            port: "443"
            password: pw
        """
        let (nodes, _) = try ClashConfigParser.parse(yaml)
        XCTAssertEqual(nodes.first?.port, 443)
    }
}
