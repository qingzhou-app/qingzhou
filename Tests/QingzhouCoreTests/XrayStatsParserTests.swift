import XCTest
@testable import QingzhouCore

final class XrayStatsParserTests: XCTestCase {

    /// 顶层 expvar 变量形态（xray 默认）。
    func testParsesFlatTopLevelCounters() {
        let json = """
        {
          "cmdline": ["xray"],
          "memstats": {"Alloc": 123},
          "outbound>>>proxy>>>traffic>>>uplink": 1000,
          "outbound>>>proxy>>>traffic>>>downlink": 5000,
          "outbound>>>direct>>>traffic>>>uplink": 10,
          "outbound>>>direct>>>traffic>>>downlink": 20,
          "inbound>>>tun-in>>>traffic>>>uplink": 6000,
          "inbound>>>tun-in>>>traffic>>>downlink": 6100
        }
        """
        let c = XrayStatsParser.parse(json)
        XCTAssertEqual(c.proxy, DirectedBytes(uplink: 1000, downlink: 5000))
        XCTAssertEqual(c.outbound["direct"], DirectedBytes(uplink: 10, downlink: 20))
        XCTAssertEqual(c.inbound["tun-in"], DirectedBytes(uplink: 6000, downlink: 6100))
    }

    /// 兼容嵌在 "stats" 对象里的形态。
    func testParsesNestedStatsObject() {
        let json = #"{"stats": {"outbound>>>proxy>>>traffic>>>uplink": 42}}"#
        XCTAssertEqual(XrayStatsParser.parse(json).proxy.uplink, 42)
    }

    /// 大数走 Double 也能取整（expvar 大计数可能被 JSON 解析成 Double）。
    func testHandlesLargeNumbers() {
        let json = #"{"outbound>>>proxy>>>traffic>>>downlink": 9000000000}"#
        XCTAssertEqual(XrayStatsParser.parse(json).proxy.downlink, 9_000_000_000)
    }

    /// 垃圾 / 空输入不崩，返回空计数。
    func testGarbageReturnsEmpty() {
        XCTAssertEqual(XrayStatsParser.parse("not json"), XrayTrafficCounters())
        XCTAssertTrue(XrayStatsParser.parse("{}").outbound.isEmpty)
    }
}
