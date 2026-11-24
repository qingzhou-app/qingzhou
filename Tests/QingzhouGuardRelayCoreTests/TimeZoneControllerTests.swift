import XCTest
import Foundation
@testable import QingzhouGuardRelayCore

private final class MockTimeZoneProvider: TimeZoneProviding, @unchecked Sendable {
    private let lock = NSLock()
    var current: String
    var setCalls: [String] = []
    var shouldFailSet = false
    var validZones: Set<String> = ["Asia/Shanghai", "America/New_York", "Europe/London", "Asia/Tokyo", "UTC"]

    init(initial: String) {
        self.current = initial
    }

    func currentTimeZone() -> String {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func setSystemTimeZone(_ identifier: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        setCalls.append(identifier)
        guard !shouldFailSet, validZones.contains(identifier) else { return false }
        current = identifier
        return true
    }

    func isValidTimeZone(_ identifier: String) -> Bool {
        guard !identifier.isEmpty,
              !identifier.contains(".."),
              !identifier.hasPrefix("/"),
              !identifier.contains("\\"),
              !identifier.contains(where: { $0.isWhitespace }) else {
            return false
        }
        return validZones.contains(identifier)
    }
}

final class TimeZoneControllerTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("tz-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testSetTZSwitchesAndSwitchesBackToOriginal() throws {
        let origPath = tempDir.appendingPathComponent("timezone-orig").path
        let provider = MockTimeZoneProvider(initial: "Asia/Shanghai")
        let ctrl = TimeZoneController(tzOrigPath: origPath, provider: provider)

        // 1. 切换到 America/New_York：记录原时区 Asia/Shanghai，并真正切换
        XCTAssertEqual(ctrl.setTimeZone("America/New_York"), .ok)
        XCTAssertEqual(provider.currentTimeZone(), "America/New_York")
        XCTAssertEqual(provider.setCalls, ["America/New_York"])
        let recordedOrig = try String(contentsOfFile: origPath, encoding: .utf8)
        XCTAssertEqual(recordedOrig, "Asia/Shanghai")

        // 2. 再次设置当前已激活的 America/New_York：与 currentTimeZone() 相等，应为 no-op
        XCTAssertEqual(ctrl.setTimeZone("America/New_York"), .ok)
        XCTAssertEqual(provider.setCalls, ["America/New_York"])

        // 3. 切回原时区 Asia/Shanghai：即使与 tzOrigPath 相同，由于当前是 America/New_York，
        // 必须真正调用 setSystemTimeZone 切回，不能被 tzOrigPath 短路！
        XCTAssertEqual(ctrl.setTimeZone("Asia/Shanghai"), .ok)
        XCTAssertEqual(provider.currentTimeZone(), "Asia/Shanghai")
        XCTAssertEqual(provider.setCalls, ["America/New_York", "Asia/Shanghai"])
    }

    func testRestoreReadsOrigFileAndRestores() {
        let origPath = tempDir.appendingPathComponent("timezone-orig").path
        let provider = MockTimeZoneProvider(initial: "Asia/Shanghai")
        let ctrl = TimeZoneController(tzOrigPath: origPath, provider: provider)

        // 尚未切换过，没有 orig 文件
        XCTAssertEqual(ctrl.restore(), .noOriginal)

        XCTAssertEqual(ctrl.setTimeZone("Asia/Tokyo"), .ok)
        XCTAssertEqual(provider.currentTimeZone(), "Asia/Tokyo")

        XCTAssertEqual(ctrl.restore(), .ok)
        XCTAssertEqual(provider.currentTimeZone(), "Asia/Shanghai")
        XCTAssertEqual(provider.setCalls, ["Asia/Tokyo", "Asia/Shanghai"])
    }

    func testInvalidTimeZoneRejectedWithoutTouchingProvider() {
        let origPath = tempDir.appendingPathComponent("timezone-orig").path
        let provider = MockTimeZoneProvider(initial: "Asia/Shanghai")
        let ctrl = TimeZoneController(tzOrigPath: origPath, provider: provider)

        XCTAssertEqual(ctrl.setTimeZone(""), .invalidZone)
        XCTAssertEqual(ctrl.setTimeZone("../etc/passwd"), .invalidZone)
        XCTAssertEqual(ctrl.setTimeZone("America/../UTC"), .invalidZone)
        XCTAssertEqual(ctrl.setTimeZone("/Asia/Shanghai"), .invalidZone)
        XCTAssertEqual(ctrl.setTimeZone("Invalid/Zone"), .invalidZone)
        XCTAssertTrue(provider.setCalls.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: origPath))

        // 验证真实 SystemTimeZoneProvider 拒绝目录、+VERSION、路径遍历，接受真实时区
        let realProvider = SystemTimeZoneProvider()
        XCTAssertFalse(realProvider.isValidTimeZone(""))
        XCTAssertFalse(realProvider.isValidTimeZone("../passwd"))
        XCTAssertFalse(realProvider.isValidTimeZone("America"))
        XCTAssertFalse(realProvider.isValidTimeZone("+VERSION"))
        XCTAssertFalse(realProvider.isValidTimeZone("/Asia/Shanghai"))
        XCTAssertFalse(realProvider.isValidTimeZone("zone.tab"))
        XCTAssertFalse(realProvider.isValidTimeZone("iso3166.tab"))
        XCTAssertFalse(realProvider.isValidTimeZone("leapseconds"))
        XCTAssertFalse(realProvider.isValidTimeZone("tzdata.zi"))
        XCTAssertFalse(realProvider.isValidTimeZone("posixrules"))
        XCTAssertTrue(realProvider.isValidTimeZone("Asia/Shanghai"))
        XCTAssertTrue(realProvider.isValidTimeZone("UTC"))
    }
}
