import XCTest
import QingzhouCore
import QingzhouSubscription
import QingzhouLogging
@testable import QingzhouApp

/// App 内更新提醒的网络解析层 + AppState 集成测试。
/// 纯版本比较逻辑在 QingzhouCoreTests/UpdateCheckerTests 里。
final class UpdateServiceTests: XCTestCase {

    // MARK: - iTunes Lookup 响应解析

    func testParsesVersionReleaseNotesAndURL() {
        let json = """
        {
          "resultCount": 1,
          "results": [
            {
              "version": "1.4.0",
              "releaseNotes": "修复若干问题并优化性能。",
              "trackViewUrl": "https://apps.apple.com/app/id123456789"
            }
          ]
        }
        """
        let info = AppStoreUpdateFetcher.parse(Data(json.utf8))
        XCTAssertEqual(info?.version, "1.4.0")
        XCTAssertEqual(info?.releaseNotes, "修复若干问题并优化性能。")
        XCTAssertEqual(info?.trackViewURL, URL(string: "https://apps.apple.com/app/id123456789"))
    }

    /// 未上架：resultCount 0 → nil（不提示、不报错）。
    func testResultCountZeroReturnsNil() {
        let json = #"{ "resultCount": 0, "results": [] }"#
        XCTAssertNil(AppStoreUpdateFetcher.parse(Data(json.utf8)))
    }

    /// 缺 releaseNotes / trackViewUrl 也能解析（可选字段）。
    func testMissingOptionalFields() {
        let json = #"{ "resultCount": 1, "results": [ { "version": "2.0.0" } ] }"#
        let info = AppStoreUpdateFetcher.parse(Data(json.utf8))
        XCTAssertEqual(info?.version, "2.0.0")
        XCTAssertNil(info?.releaseNotes)
        XCTAssertNil(info?.trackViewURL)
    }

    func testMalformedJSONReturnsNil() {
        XCTAssertNil(AppStoreUpdateFetcher.parse(Data("not json".utf8)))
        XCTAssertNil(AppStoreUpdateFetcher.parse(Data()))
    }

    // MARK: - 假查询器（AppState 集成用）

    struct StubLookup: AppStoreVersionLookup {
        let info: AppStoreVersionInfo?
        func fetchLatest(bundleId: String, country: String) async -> AppStoreVersionInfo? { info }
    }

    @MainActor
    private func makeState(lookup: any AppStoreVersionLookup) -> AppState {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("update-test-\(UUID().uuidString)", isDirectory: true)
        return AppState(
            logger: Logger(capacity: 100, minimumLevel: .debug),
            persistence: Persistence(directory: tmp),
            updateFetcher: lookup
        )
    }

    // MARK: - AppState.checkForAppUpdate

    /// 有更新版本 → availableUpdate 被设上，且带 release notes（供 UI 展示）。
    @MainActor
    func testCheckSetsAvailableUpdateWithReleaseNotes() async {
        let state = makeState(lookup: StubLookup(info: AppStoreVersionInfo(
            version: "1.5.0", releaseNotes: "新增更新提醒。",
            trackViewURL: URL(string: "https://apps.apple.com/app/id1"))))
        await state.checkForAppUpdate(bundleId: "com.example.app", currentVersion: "1.0.0")
        XCTAssertEqual(state.availableUpdate?.version, "1.5.0")
        XCTAssertEqual(state.availableUpdate?.releaseNotes, "新增更新提醒。")
        XCTAssertNotNil(state.availableUpdate?.trackViewURL)
    }

    /// 无结果（未上架）→ 不提示。
    @MainActor
    func testCheckWithNoResultDoesNotPrompt() async {
        let state = makeState(lookup: StubLookup(info: nil))
        await state.checkForAppUpdate(bundleId: "com.example.app", currentVersion: "1.0.0")
        XCTAssertNil(state.availableUpdate)
    }

    /// 已是最新 → 不提示。
    @MainActor
    func testCheckWhenUpToDateDoesNotPrompt() async {
        let state = makeState(lookup: StubLookup(info: AppStoreVersionInfo(version: "1.0.0")))
        await state.checkForAppUpdate(bundleId: "com.example.app", currentVersion: "1.0.0")
        XCTAssertNil(state.availableUpdate)
    }

    /// 已忽略该版本 → 不提示。
    @MainActor
    func testCheckRespectsIgnoredVersion() async {
        let state = makeState(lookup: StubLookup(info: AppStoreVersionInfo(version: "1.5.0")))
        state.settings.ignoredUpdateVersion = "1.5.0"
        await state.checkForAppUpdate(bundleId: "com.example.app", currentVersion: "1.0.0")
        XCTAssertNil(state.availableUpdate)
    }

    /// 忽略此版本：写入 settings（持久化）并收起提示。
    @MainActor
    func testIgnoreUpdatePersistsAndDismisses() async {
        let state = makeState(lookup: StubLookup(info: AppStoreVersionInfo(version: "1.5.0")))
        await state.checkForAppUpdate(bundleId: "com.example.app", currentVersion: "1.0.0")
        XCTAssertNotNil(state.availableUpdate)
        state.ignoreUpdate("1.5.0")
        XCTAssertNil(state.availableUpdate)
        XCTAssertEqual(state.settings.ignoredUpdateVersion, "1.5.0")
    }

    /// 忽略旧版本后，App Store 出了更新版本 → 再次提示。
    @MainActor
    func testNewerThanIgnoredPromptsAgain() async {
        let state = makeState(lookup: StubLookup(info: AppStoreVersionInfo(version: "1.6.0")))
        state.settings.ignoredUpdateVersion = "1.5.0"
        await state.checkForAppUpdate(bundleId: "com.example.app", currentVersion: "1.0.0")
        XCTAssertEqual(state.availableUpdate?.version, "1.6.0")
    }

    /// 稍后：仅收起提示，不写忽略记录。
    @MainActor
    func testDismissDoesNotRecordIgnore() async {
        let state = makeState(lookup: StubLookup(info: AppStoreVersionInfo(version: "1.5.0")))
        await state.checkForAppUpdate(bundleId: "com.example.app", currentVersion: "1.0.0")
        state.dismissUpdate()
        XCTAssertNil(state.availableUpdate)
        XCTAssertEqual(state.settings.ignoredUpdateVersion, "")
    }
}
