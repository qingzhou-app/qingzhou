import XCTest
import CryptoKit
import QingzhouCore
@testable import QingzhouApp

/// GeoDataManager —— 完整版 geoip.dat 的主备源下载 / sha256 校验 / 版本管理。
/// 核心保障：
/// 1) 主源（qingzhou-app/geo-data）优先，失败（网络错 / 校验不过）自动切备源（v2fly 官方）
/// 2) 校验不过绝不落盘 —— 双源全挂时保留现有数据原样
/// 3) 版本比较（checkForUpdate）拿远端 sha256 和本地记录比
@MainActor
final class GeoDataManagerTests: XCTestCase {

    // MARK: - 测试基建

    /// 按 URL 精确匹配返回结果的假下载器 —— 单测不出网。
    private struct FakeDownloader: GeoDataDownloading {
        var responses: [URL: Result<Data, Error>]
        func fetch(_ url: URL, progress: @escaping @Sendable (Double?) -> Void) async throws -> Data {
            guard let result = responses[url] else { throw URLError(.unsupportedURL) }
            progress(1.0)
            return try result.get()
        }
    }

    private let primary = GeoDataSource(
        id: "qingzhou", displayName: "轻舟源",
        datURL: URL(string: "https://primary.test/geoip.dat")!,
        checksumURL: URL(string: "https://primary.test/geoip.dat.sha256sum")!
    )
    private let backup = GeoDataSource(
        id: "v2fly", displayName: "v2fly 官方",
        datURL: URL(string: "https://backup.test/geoip.dat")!,
        checksumURL: URL(string: "https://backup.test/geoip.dat.sha256sum")!
    )

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("geo-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 上游 .sha256sum 文件的真实格式："<hex>  <文件名>\n"
    private func checksumFile(for data: Data, name: String = "geoip.dat") -> Data {
        Data("\(sha256Hex(data))  \(name)\n".utf8)
    }

    private func makeManager(_ responses: [URL: Result<Data, Error>]) -> GeoDataManager {
        GeoDataManager(
            downloader: FakeDownloader(responses: responses),
            directory: tempDir,
            sources: [primary, backup]
        )
    }

    // MARK: - 主源成功

    func testPrimarySourceSuccessWritesFileAndInfo() async throws {
        let payload = Data("full-geoip-payload".utf8)
        let manager = makeManager([
            primary.checksumURL: .success(checksumFile(for: payload)),
            primary.datURL: .success(payload)
        ])

        let ok = await manager.downloadFullGeoIP()

        XCTAssertTrue(ok)
        XCTAssertTrue(manager.hasFullGeoIP)
        let written = try Data(contentsOf: tempDir.appendingPathComponent("geoip.dat"))
        XCTAssertEqual(written, payload)
        XCTAssertEqual(manager.info?.sourceID, "qingzhou", "主源可用时必须用主源")
        XCTAssertEqual(manager.info?.sha256, sha256Hex(payload))
        XCTAssertEqual(manager.info?.sizeBytes, Int64(payload.count))
    }

    // MARK: - 主备切换

    func testPrimaryNetworkFailureFallsBackToBackup() async throws {
        let payload = Data("backup-geoip-payload".utf8)
        let manager = makeManager([
            primary.checksumURL: .failure(URLError(.timedOut)),
            backup.checksumURL: .success(checksumFile(for: payload)),
            backup.datURL: .success(payload)
        ])

        let ok = await manager.downloadFullGeoIP()

        XCTAssertTrue(ok)
        XCTAssertEqual(manager.info?.sourceID, "v2fly", "主源超时必须自动切到备源")
        XCTAssertEqual(try Data(contentsOf: tempDir.appendingPathComponent("geoip.dat")), payload)
    }

    func testPrimaryChecksumMismatchFallsBackToBackup() async throws {
        let goodPayload = Data("good-payload".utf8)
        let tampered = Data("tampered-payload".utf8)
        let manager = makeManager([
            // 主源：校验和与内容对不上（下载损坏 / 被劫持）
            primary.checksumURL: .success(checksumFile(for: goodPayload)),
            primary.datURL: .success(tampered),
            backup.checksumURL: .success(checksumFile(for: goodPayload)),
            backup.datURL: .success(goodPayload)
        ])

        let ok = await manager.downloadFullGeoIP()

        XCTAssertTrue(ok)
        XCTAssertEqual(manager.info?.sourceID, "v2fly", "主源校验不过必须切备源")
        XCTAssertEqual(try Data(contentsOf: tempDir.appendingPathComponent("geoip.dat")), goodPayload)
    }

    // MARK: - 双源全挂：保留现状

    func testAllSourcesFailKeepsExistingData() async throws {
        // 先用一次成功下载铺好"现有数据"
        let existing = Data("existing-payload".utf8)
        let seeder = makeManager([
            primary.checksumURL: .success(checksumFile(for: existing)),
            primary.datURL: .success(existing)
        ])
        _ = await seeder.downloadFullGeoIP()

        // 双源全挂再下一次
        let manager = makeManager([
            primary.checksumURL: .failure(URLError(.cannotConnectToHost)),
            backup.checksumURL: .failure(URLError(.cannotConnectToHost))
        ])
        let ok = await manager.downloadFullGeoIP()

        XCTAssertFalse(ok)
        XCTAssertEqual(try Data(contentsOf: tempDir.appendingPathComponent("geoip.dat")), existing,
                       "全部源失败时现有 geoip.dat 必须原样保留")
        XCTAssertEqual(manager.info?.sha256, sha256Hex(existing), "info 也不能被失败的下载弄脏")
        XCTAssertTrue(manager.hasFullGeoIP)
        if case .failed(let message) = manager.phase {
            XCTAssertTrue(message.contains("VPN"), "错误文案要引导「开启 VPN 后重试」，实际：\(message)")
        } else {
            XCTFail("双源全挂后 phase 应为 .failed，实际：\(manager.phase)")
        }
    }

    func testChecksumFileGarbageTreatedAsSourceFailure() async throws {
        let payload = Data("payload".utf8)
        let manager = makeManager([
            // 主源校验和文件是 HTML（GitHub 404 页之类）→ 当源失败处理
            primary.checksumURL: .success(Data("<html>Not Found</html>".utf8)),
            backup.checksumURL: .success(checksumFile(for: payload)),
            backup.datURL: .success(payload)
        ])

        let ok = await manager.downloadFullGeoIP()

        XCTAssertTrue(ok)
        XCTAssertEqual(manager.info?.sourceID, "v2fly")
    }

    // MARK: - 版本比较 / 状态判定

    func testCheckForUpdateComparesRemoteSha() async throws {
        let payload = Data("payload-v1".utf8)
        let manager = makeManager([
            primary.checksumURL: .success(checksumFile(for: payload)),
            primary.datURL: .success(payload)
        ])
        _ = await manager.downloadFullGeoIP()

        // 远端没变 → 无更新
        let same = await manager.checkForUpdate()
        XCTAssertEqual(same, false)

        // 远端换了新数据 → 有更新
        let v2 = Data("payload-v2".utf8)
        let manager2 = makeManager([
            primary.checksumURL: .success(checksumFile(for: v2))
        ])
        let changed = await manager2.checkForUpdate()
        XCTAssertEqual(changed, true)
    }

    func testCheckForUpdateWithoutLocalFullDataReportsUpdate() async throws {
        // 还没下载过完整版 → "检查更新"应报告有可下载的完整版
        let payload = Data("payload".utf8)
        let manager = makeManager([
            primary.checksumURL: .success(checksumFile(for: payload))
        ])
        let result = await manager.checkForUpdate()
        XCTAssertEqual(result, true)
    }

    func testCheckForUpdateFallsBackToBackupSource() async throws {
        let payload = Data("payload".utf8)
        let manager = makeManager([
            primary.checksumURL: .failure(URLError(.timedOut)),
            backup.checksumURL: .success(checksumFile(for: payload))
        ])
        let result = await manager.checkForUpdate()
        XCTAssertEqual(result, true, "主源挂了检查更新也要走备源")
    }

    func testHasFullGeoIPFalseWhenFileMissing() async throws {
        let payload = Data("payload".utf8)
        let manager = makeManager([
            primary.checksumURL: .success(checksumFile(for: payload)),
            primary.datURL: .success(payload)
        ])
        _ = await manager.downloadFullGeoIP()
        XCTAssertTrue(manager.hasFullGeoIP)

        // 文件被外力删掉（清缓存等）→ info 还在也不能算"完整版就位"
        try FileManager.default.removeItem(at: tempDir.appendingPathComponent("geoip.dat"))
        XCTAssertFalse(manager.hasFullGeoIP)
    }

    func testInfoPersistsAcrossManagerInstances() async throws {
        let payload = Data("payload".utf8)
        let manager = makeManager([
            primary.checksumURL: .success(checksumFile(for: payload)),
            primary.datURL: .success(payload)
        ])
        _ = await manager.downloadFullGeoIP()

        // 新实例（App 重启）从磁盘恢复 info
        let reloaded = makeManager([:])
        XCTAssertEqual(reloaded.info?.sha256, sha256Hex(payload))
        XCTAssertTrue(reloaded.hasFullGeoIP)
    }
}
