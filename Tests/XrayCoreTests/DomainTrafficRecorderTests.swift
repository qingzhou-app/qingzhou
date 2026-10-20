import XCTest
import QingzhouCore
@testable import XrayCore

final class DomainTrafficRecorderTests: XCTestCase {
    func testWriterRestartsWithoutDoubleCountingAndWithoutMainApp() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let snapshot = DomainTrafficSnapshot(session: "core", entries: [.init(domain: "video.example.com", route: "proxy", upload: 100, download: 200)])
        let now = Date()
        try DomainTrafficRecorder(url: url).record(snapshot, at: now)
        try DomainTrafficRecorder(url: url).record(snapshot, at: now.addingTimeInterval(10))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let ledger = try decoder.decode(DomainTrafficLedger.self, from: Data(contentsOf: url))
        XCTAssertEqual(ledger.months.values.first?.rows.first?.proxy.total, 300)
    }
    func testUnreadableExistingLedgerIsNotOverwritten() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let original = Data("broken history".utf8); try original.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try DomainTrafficRecorder(url: url))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
    func testFailedWriteDoesNotAdvanceBaseline() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let recorder = try DomainTrafficRecorder(url: url)
        let snapshot = DomainTrafficSnapshot(session: "core", entries: [.init(domain: "a.example", route: "proxy", upload: 10, download: 20)])
        let now = Date()
        XCTAssertThrowsError(try recorder.record(snapshot, at: now))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try recorder.record(snapshot, at: now.addingTimeInterval(10))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let ledger = try decoder.decode(DomainTrafficLedger.self, from: Data(contentsOf: url))
        XCTAssertEqual(ledger.months.values.first?.rows.first?.proxy.total, 30)
    }
}
