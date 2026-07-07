import XCTest
import QingzhouCore
import QingzhouProtocols
import XrayConfig
@testable import XrayCore

/// hysteria2 原生转换的**真实性校验**：share link → ProxyURLParser → NodeConverter →
/// XrayConfigComposer → `XrayCore.testConfig` 真跑一遍 xray-core (v26.6.27) 的配置构建。
/// 无网络依赖 —— testConfig 只验配置合法性，不拨号。
///
/// 这组测试的价值：NodeConverterTests 只断言我们**自己认为**的 JSON 形态；这里让
/// 打包的 xray-core 亲口确认 finalmask/quicParams/salamander 这些 v26.6.27 字段拼对了。
/// tunInterfaceName 用 "utun9"：预检路径没有 TUN fd，xray 严格校验接口名（见
/// XrayConfigComposer 的注释，真机踩过）。
final class Hysteria2ConfigPrecheckTests: XCTestCase {

    private func precheck(_ link: String) throws {
        let node = try ProxyURLParser.parse(link)
        let outbounds = try NodeConverter.toOutboundsJSON(node)
        let config = try XrayConfigComposer.compose(
            outboundsJSON: outbounds,
            mode: .global,
            tunInterfaceName: "utun9"
        )
        try XrayCore.testConfig(configJSON: config, datDir: "")
    }

    /// 最普通的 hy2 链接（无 obfs / 无跳跃）——升级 schema 后老节点不许回归。
    func testPlainHysteria2LinkPassesPrecheck() throws {
        XCTAssertNoThrow(try precheck(
            "hysteria2://letmein@hy.example.com:36500?sni=hy.example.com&insecure=1#hy2"
        ))
    }

    /// 全参数链接：端口跳跃（authority 区间写法）+ salamander obfs + hopInterval +
    /// brutal 带宽 + congestion + pinSHA256 —— 每个 v26.6.27 新字段都过一遍 xray 的 Build()。
    func testFullFeatureHysteria2LinkPassesPrecheck() throws {
        let pin = String(repeating: "ab", count: 32)   // 32 字节 sha256 的合法 hex
        XCTAssertNoThrow(try precheck(
            "hysteria2://letmein@hy.example.com:40000-50000?sni=hy.example.com"
            + "&obfs=salamander&obfs-password=ob-pass&hopInterval=30"
            + "&up=100&down=500&congestion=bbr&pinSHA256=\(pin)#hy2-full"
        ))
    }

    /// 反证：precheck 真的走到了 hysteria 构建路径 —— version != 2 必须被 xray 拒绝
    ///（infra/conf 里 settings 和 hysteriaSettings 双处 version 校验）。
    func testHysteriaVersionOtherThan2RejectedByXray() {
        let config = #"""
        {
          "inbounds": [{"tag": "in", "protocol": "socks", "listen": "127.0.0.1", "port": 61996,
                        "settings": {"udp": false}}],
          "outbounds": [{
            "tag": "out", "protocol": "hysteria",
            "settings": {"version": 3, "address": "h.example", "port": 443},
            "streamSettings": {
              "network": "hysteria", "security": "tls",
              "tlsSettings": {"serverName": "h.example", "alpn": ["h3"]},
              "hysteriaSettings": {"version": 3, "auth": "pwd"}
            }
          }]
        }
        """#
        XCTAssertThrowsError(try XrayCore.testConfig(configJSON: config, datDir: "")) { error in
            let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertTrue(msg.lowercased().contains("version"), "报错该点名 version：\(msg)")
        }
    }
}
