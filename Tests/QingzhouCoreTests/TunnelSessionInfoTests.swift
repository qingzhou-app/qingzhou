import XCTest
@testable import QingzhouCore

/// 隧道会话标记（扩展写 App Group、主 App 读）：
/// 主 App 用「启动时刻 + 时长」推算剩余时间，不依赖和扩展的实时通信。
final class TunnelSessionInfoTests: XCTestCase {

    func testDeadlineIsStartPlusDuration() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let info = TunnelSessionInfo(startedAt: start, autoStopSeconds: 1800)
        XCTAssertEqual(info.deadline, start.addingTimeInterval(1800))
    }

    func testNoDeadlineWhenAutoStopDisabled() {
        let info = TunnelSessionInfo(startedAt: Date(), autoStopSeconds: 0)
        XCTAssertNil(info.deadline)
    }

    func testCodableRoundtripWithISO8601() throws {
        // 编解码策略必须和 AppGroupStorage（iso8601）一致，否则主 App 读不回来
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var info = TunnelSessionInfo(startedAt: Date(timeIntervalSince1970: 1_750_000_000), autoStopSeconds: 3600)
        info.stoppedAt = Date(timeIntervalSince1970: 1_750_003_600)
        let data = try encoder.encode(info)
        let back = try decoder.decode(TunnelSessionInfo.self, from: data)
        XCTAssertEqual(back, info)
        XCTAssertNotNil(back.stoppedAt)
    }

    func testStoppedAtDefaultsToNil() {
        let info = TunnelSessionInfo(startedAt: Date(), autoStopSeconds: 60)
        XCTAssertNil(info.stoppedAt)
    }
}
