import XCTest
import QingzhouCore
@testable import QingzhouProtocols

final class QingzhouProtocolsTests: XCTestCase {

    // MARK: - trojan

    func testParseTrojanBasic() throws {
        let url = "trojan://my%20pass@example.com:443?sni=example.com&type=tcp#%E9%A6%99%E6%B8%AF"
        let node = try ProxyURLParser.parse(url)
        XCTAssertEqual(node.protocolType, .trojan)
        XCTAssertEqual(node.host, "example.com")
        XCTAssertEqual(node.port, 443)
        XCTAssertEqual(node.password, "my pass")
        XCTAssertEqual(node.parameters["sni"], "example.com")
        XCTAssertEqual(node.parameters["type"], "tcp")
        XCTAssertEqual(node.name, "香港")
    }

    func testParseTrojanMissingPort() {
        let url = "trojan://pw@example.com#x"
        XCTAssertThrowsError(try ProxyURLParser.parse(url)) { err in
            XCTAssertEqual(err as? ProxyURLParseError, .missingPort)
        }
    }

    func testParseTrojanMissingPassword() {
        let url = "trojan://@example.com:443#x"
        XCTAssertThrowsError(try ProxyURLParser.parse(url)) { err in
            XCTAssertEqual(err as? ProxyURLParseError, .missingCredential)
        }
    }

    // MARK: - shadowsocks SIP002

    func testParseShadowsocksSIP002() throws {
        // base64("aes-128-gcm:password") = "YWVzLTEyOC1nY206cGFzc3dvcmQ="
        let url = "ss://YWVzLTEyOC1nY206cGFzc3dvcmQ=@1.2.3.4:8388#SS-Node"
        let node = try ProxyURLParser.parse(url)
        XCTAssertEqual(node.protocolType, .shadowsocks)
        XCTAssertEqual(node.host, "1.2.3.4")
        XCTAssertEqual(node.port, 8388)
        XCTAssertEqual(node.cipher, "aes-128-gcm")
        XCTAssertEqual(node.password, "password")
        XCTAssertEqual(node.name, "SS-Node")
    }

    func testParseShadowsocks2022PlaintextUserInfo() throws {
        // ss-2022 / 部分面板：userinfo 是明文 method:password（非 base64，含 `:`/`-`）。
        // 旧实现只认 base64 会抛错丢节点（机场兼容审计 P0）。
        let url = "ss://2022-blake3-aes-256-gcm:mypasswd123@1.2.3.4:8388#SS2022"
        let node = try ProxyURLParser.parse(url)
        XCTAssertEqual(node.cipher, "2022-blake3-aes-256-gcm")
        XCTAssertEqual(node.password, "mypasswd123")
        XCTAssertEqual(node.host, "1.2.3.4")
        XCTAssertEqual(node.port, 8388)
    }

    func testParseShadowsocksPlaintextPercentEncodedPassword() throws {
        // 明文 userinfo 里密码含特殊字符 percent-encode
        let url = "ss://aes-256-gcm:p%40ss%3Aword@host.example:443#n"
        let node = try ProxyURLParser.parse(url)
        XCTAssertEqual(node.cipher, "aes-256-gcm")
        XCTAssertEqual(node.password, "p@ss:word", "第一个 : 后全是密码，含解码后的特殊字符")
    }

    func testParseShadowsocksLegacy() throws {
        // base64("aes-128-gcm:password@1.2.3.4:8388") =
        // "YWVzLTEyOC1nY206cGFzc3dvcmRAMS4yLjMuNDo4Mzg4"
        let url = "ss://YWVzLTEyOC1nY206cGFzc3dvcmRAMS4yLjMuNDo4Mzg4#legacy"
        let node = try ProxyURLParser.parse(url)
        XCTAssertEqual(node.protocolType, .shadowsocks)
        XCTAssertEqual(node.host, "1.2.3.4")
        XCTAssertEqual(node.port, 8388)
        XCTAssertEqual(node.cipher, "aes-128-gcm")
        XCTAssertEqual(node.password, "password")
        XCTAssertEqual(node.name, "legacy")
    }

    func testParseShadowsocksURLSafeBase64WithoutPadding() throws {
        // base64url 不含 padding，且使用 - / _ 替代 + / 的场景
        // base64url("aes-256-gcm:pw") = "YWVzLTI1Ni1nY206cHc"
        let url = "ss://YWVzLTI1Ni1nY206cHc@host.example:9999"
        let node = try ProxyURLParser.parse(url)
        XCTAssertEqual(node.cipher, "aes-256-gcm")
        XCTAssertEqual(node.password, "pw")
        XCTAssertEqual(node.port, 9999)
    }

    // MARK: - vmess

    func testParseVMess() throws {
        let json = #"""
        {"v":"2","ps":"vmess-node","add":"vm.example.com","port":"443","id":"11111111-2222-3333-4444-555555555555","aid":0,"scy":"auto","net":"ws","type":"none","host":"vm.example.com","path":"/ray","tls":"tls","sni":"vm.example.com"}
        """#
        let b64 = Data(json.utf8).base64EncodedString()
        let node = try ProxyURLParser.parse("vmess://" + b64)
        XCTAssertEqual(node.protocolType, .vmess)
        XCTAssertEqual(node.host, "vm.example.com")
        XCTAssertEqual(node.port, 443)
        XCTAssertEqual(node.uuid, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(node.alterId, 0)
        XCTAssertEqual(node.cipher, "auto")
        XCTAssertEqual(node.parameters["net"], "ws")
        XCTAssertEqual(node.parameters["path"], "/ray")
        XCTAssertEqual(node.parameters["tls"], "tls")
        XCTAssertEqual(node.name, "vmess-node")
    }

    func testParseVMessPortAsNumber() throws {
        // 部分客户端会把 port 写成数字
        let json = #"{"ps":"x","add":"h","port":1234,"id":"abc","aid":0}"#
        let b64 = Data(json.utf8).base64EncodedString()
        let node = try ProxyURLParser.parse("vmess://" + b64)
        XCTAssertEqual(node.port, 1234)
    }

    func testParseVMessInvalidBase64() {
        XCTAssertThrowsError(try ProxyURLParser.parse("vmess://!!!not_base64!!!"))
    }

    func testParseVMessInvalidJSON() {
        let b64 = Data("not json".utf8).base64EncodedString()
        XCTAssertThrowsError(try ProxyURLParser.parse("vmess://" + b64)) { err in
            if case .invalidJSON = err as? ProxyURLParseError { /* ok */ } else {
                XCTFail("Expected invalidJSON, got \(err)")
            }
        }
    }

    // MARK: - vless

    func testParseVLESS() throws {
        let url = "vless://abcd-1234@v.example.com:8443?encryption=none&security=tls&type=ws&path=%2Fpath&sni=v.example.com#%E6%B4%9B%E6%9D%89%E7%9F%B6"
        let node = try ProxyURLParser.parse(url)
        XCTAssertEqual(node.protocolType, .vless)
        XCTAssertEqual(node.uuid, "abcd-1234")
        XCTAssertEqual(node.host, "v.example.com")
        XCTAssertEqual(node.port, 8443)
        XCTAssertEqual(node.parameters["security"], "tls")
        XCTAssertEqual(node.parameters["path"], "/path")
    }

    func testParseVLESSReality() throws {
        // 典型 vless + REALITY 分享链接：security=reality，带 pbk/sid/spx/fp/flow/sni
        let url = "vless://11111111-2222-3333-4444-555555555555@real.example.com:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=xN-public-key-base64&sid=0123abcd&spx=%2F&type=tcp#REALITY-Node"
        let node = try ProxyURLParser.parse(url)
        XCTAssertEqual(node.protocolType, .vless)
        XCTAssertEqual(node.uuid, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(node.host, "real.example.com")
        XCTAssertEqual(node.port, 443)
        XCTAssertEqual(node.name, "REALITY-Node")
        XCTAssertEqual(node.parameters["encryption"], "none")
        XCTAssertEqual(node.parameters["security"], "reality")
        XCTAssertEqual(node.parameters["flow"], "xtls-rprx-vision")
        XCTAssertEqual(node.parameters["sni"], "www.microsoft.com")
        XCTAssertEqual(node.parameters["fp"], "chrome")
        XCTAssertEqual(node.parameters["pbk"], "xN-public-key-base64")
        XCTAssertEqual(node.parameters["sid"], "0123abcd")
        XCTAssertEqual(node.parameters["spx"], "/")   // %2F 解码回 "/"
        XCTAssertEqual(node.parameters["type"], "tcp")
    }

    // MARK: - hysteria2

    func testParseHysteria2() throws {
        let url = "hysteria2://pwd@hy.example.com:36500?sni=hy.example.com&insecure=1#HY2"
        let node = try ProxyURLParser.parse(url)
        XCTAssertEqual(node.protocolType, .hysteria2)
        XCTAssertEqual(node.host, "hy.example.com")
        XCTAssertEqual(node.port, 36500)
        XCTAssertEqual(node.password, "pwd")
        XCTAssertEqual(node.parameters["insecure"], "1")
    }

    func testParseHy2Alias() throws {
        let url = "hy2://pwd@hy.example.com:36500#X"
        let node = try ProxyURLParser.parse(url)
        XCTAssertEqual(node.protocolType, .hysteria2)
    }

    /// hysteria2 官方 URI 支持端口跳跃：authority 里直接写 `host:40000-50000`。
    /// URLComponents 解析不了非数字端口 —— parser 预处理：node.port 取首端口，
    /// 完整端口串挪到 parameters["mport"]（converter 再转成 finalmask.quicParams.udpHop）。
    func testParseHysteria2PortHoppingRange() throws {
        let url = "hysteria2://pwd@hy.example.com:40000-50000?sni=hy.example.com#hop"
        let node = try ProxyURLParser.parse(url)
        XCTAssertEqual(node.host, "hy.example.com")
        XCTAssertEqual(node.port, 40000)
        XCTAssertEqual(node.parameters["mport"], "40000-50000")
        XCTAssertEqual(node.password, "pwd")
        XCTAssertEqual(node.name, "hop")
    }

    /// 逗号 + 区间混写（`443,8443-8500`）也认；其余 query 照常解析。
    func testParseHysteria2PortHoppingCommaList() throws {
        let url = "hy2://pwd@hy.example.com:443,8443-8500/?obfs=salamander&obfs-password=op#hop"
        let node = try ProxyURLParser.parse(url)
        XCTAssertEqual(node.port, 443)
        XCTAssertEqual(node.parameters["mport"], "443,8443-8500")
        XCTAssertEqual(node.parameters["obfs"], "salamander")
        XCTAssertEqual(node.parameters["obfs-password"], "op")
    }

    /// 跳跃端口段里混了越界端口 → 整条链接拒收（别让垃圾进 xray 再炸）。
    func testParseHysteria2PortHoppingOutOfRangeRejected() {
        XCTAssertThrowsError(try ProxyURLParser.parse("hysteria2://p@h.example:70000-70010#bad"))
    }

    /// `mport=` 查询参数写法（v2rayN / Shadowrocket 惯用）原样保留。
    func testParseHysteria2MportQueryParam() throws {
        let url = "hysteria2://pwd@hy.example.com:443?mport=443,5000-6000#m"
        let node = try ProxyURLParser.parse(url)
        XCTAssertEqual(node.port, 443)
        XCTAssertEqual(node.parameters["mport"], "443,5000-6000")
    }

    /// 官方 URI 全参数（apernet/hysteria discussions/716）：sni / insecure / obfs /
    /// obfs-password / pinSHA256 全部落进 parameters（pinSHA256 冒号原样保留）。
    func testParseHysteria2OfficialFullParams() throws {
        let url = "hysteria2://auth-token@hy.example.com:443?sni=real.example&insecure=1"
            + "&obfs=salamander&obfs-password=ob-pass&pinSHA256=AB:CD:EF:01#full"
        let node = try ProxyURLParser.parse(url)
        XCTAssertEqual(node.password, "auth-token")
        XCTAssertEqual(node.parameters["sni"], "real.example")
        XCTAssertEqual(node.parameters["insecure"], "1")
        XCTAssertEqual(node.parameters["obfs"], "salamander")
        XCTAssertEqual(node.parameters["obfs-password"], "ob-pass")
        XCTAssertEqual(node.parameters["pinSHA256"], "AB:CD:EF:01")
    }

    // MARK: - Dispatcher

    func testParseUnknownScheme() {
        XCTAssertThrowsError(try ProxyURLParser.parse("wireguard://x@y:1#z")) { err in
            if case .unsupportedScheme(let s) = err as? ProxyURLParseError {
                XCTAssertEqual(s, "wireguard")
            } else {
                XCTFail("Wrong error: \(err)")
            }
        }
    }

    func testParseBatchKeepsGoodLinesAndCollectsErrors() {
        let text = """
        trojan://pw@example.com:443#ok
        garbage
        hy2://p@h.example:443#hy
        """
        let (nodes, errors) = ProxyURLParser.parseBatch(text)
        XCTAssertEqual(nodes.count, 2)
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors[0].0, "garbage")
    }
}
