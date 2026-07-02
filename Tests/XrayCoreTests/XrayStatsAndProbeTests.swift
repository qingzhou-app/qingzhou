import XCTest
@testable import XrayCore

/// QueryStats 解析 + 空闲端口 + TestXray/Ping 的可离线部分。
final class XrayStatsAndProbeTests: XCTestCase {

    // MARK: - parseOutboundStats（纯解析，不碰 LibXray）

    func testParseOutboundStatsExtractsPerTagCounters() {
        let expvar = #"""
        {
          "memstats": {"Alloc": 12345678},
          "stats": {
            "inbound": {"tun-in": {"downlink": 0, "uplink": 0}},
            "outbound": {
              "proxy":  {"downlink": 1048576, "uplink": 65536},
              "direct": {"downlink": 2048,    "uplink": 512},
              "reject": {"downlink": 0,       "uplink": 0}
            }
          }
        }
        """#
        let parsed = XrayCore.parseOutboundStats(expvar)
        XCTAssertEqual(parsed["proxy"]?.downlink, 1_048_576)
        XCTAssertEqual(parsed["proxy"]?.uplink, 65_536)
        XCTAssertEqual(parsed["direct"]?.downlink, 2_048)
        XCTAssertEqual(parsed["reject"]?.uplink, 0)
        XCTAssertNil(parsed["tun-in"], "inbound 计数不该混进 outbound 结果")
    }

    func testParseOutboundStatsToleratesGarbage() {
        XCTAssertTrue(XrayCore.parseOutboundStats("not json").isEmpty)
        XCTAssertTrue(XrayCore.parseOutboundStats("{}").isEmpty)
        XCTAssertTrue(XrayCore.parseOutboundStats(#"{"stats":{}}"#).isEmpty)
    }

    // MARK: - getFreePorts（真走 libXray，但只 bind loopback :0，离线可跑）

    func testGetFreePortsReturnsUsablePorts() throws {
        let ports = try XrayCore.getFreePorts(2)
        XCTAssertEqual(ports.count, 2)
        for p in ports {
            XCTAssertTrue((1...65535).contains(p), "非法端口 \(p)")
        }
    }

    // MARK: - testConfig（真走 xray-core 配置构建，无网络依赖）

    func testTestConfigAcceptsMinimalValidConfig() throws {
        let config = #"""
        {
          "log": {"loglevel": "warning"},
          "inbounds": [{"tag": "in", "protocol": "socks", "listen": "127.0.0.1", "port": 61999,
                        "settings": {"udp": false}}],
          "outbounds": [{"tag": "out", "protocol": "freedom", "settings": {}}]
        }
        """#
        XCTAssertNoThrow(try XrayCore.testConfig(configJSON: config, datDir: ""))
    }

    func testTestConfigRejectsBrokenConfigWithReadableError() {
        // trojan servers 缺 address/port —— xray-core 构建期就该报错
        let config = #"""
        {
          "inbounds": [{"tag": "in", "protocol": "socks", "listen": "127.0.0.1", "port": 61998,
                        "settings": {"udp": false}}],
          "outbounds": [{"tag": "out", "protocol": "trojan", "settings": {"servers": [{}]}}]
        }
        """#
        XCTAssertThrowsError(try XrayCore.testConfig(configJSON: config, datDir: "")) { error in
            let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertFalse(msg.isEmpty)
        }
    }

    func testTestConfigRejectsNonJSON() {
        XCTAssertThrowsError(try XrayCore.testConfig(configJSON: "not a config", datDir: ""))
    }
}
