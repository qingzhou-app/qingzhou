import XCTest
import QingzhouLogging
@testable import QingzhouApp

final class LogExportTextTests: XCTestCase {
    func testRenderMatchesFileSinkLineFormat() {
        let ts = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14T22:13:20Z
        let entries = [
            LogEntry(timestamp: ts, level: .info, category: "vpn", message: "tunnel started"),
            LogEntry(timestamp: ts, level: .error, category: "subscription", message: "刷新失败: timeout"),
        ]
        let text = LogExportText.render(entries)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)

        XCTAssertEqual(lines.count, 3, "两条日志 + 末尾换行")
        XCTAssertEqual(lines[0], "2023-11-14T22:13:20.000Z [INFO] [vpn] tunnel started")
        XCTAssertEqual(lines[1], "2023-11-14T22:13:20.000Z [ERROR] [subscription] 刷新失败: timeout")
        XCTAssertEqual(lines[2], "")
    }

    func testSuggestedFileNameHasStampAndExtension() {
        let name = LogExportText.suggestedFileName(now: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(name.hasPrefix("Qingzhou-logs-"))
        XCTAssertTrue(name.hasSuffix(".log"))
    }
}
