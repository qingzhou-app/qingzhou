import XCTest
import QingzhouCore
import QingzhouProtocols
import QingzhouLogging
@testable import QingzhouApp

// MARK: - 纯决策逻辑

final class VaultSyncLogicTests: XCTestCase {
    private func header(revision: Int, schemaVersion: Int = VaultDocument.currentSchemaVersion) -> VaultHeader {
        VaultHeader(schemaVersion: schemaVersion, revision: revision, modifiedAt: Date(), deviceName: "test-device")
    }

    func testNoCloudDocumentMirrorsLocal() {
        XCTAssertEqual(
            VaultSyncLogic.startupAction(cloudHeader: nil, lastSyncedRevision: nil),
            .mirrorLocal
        )
        // 本地曾同步过、云文档却没了（用户手删）→ 重新镜像上去
        XCTAssertEqual(
            VaultSyncLogic.startupAction(cloudHeader: nil, lastSyncedRevision: 7),
            .mirrorLocal
        )
    }

    func testFreshInstallWithCloudOffersRestore() {
        // 卸载重装：本地没有同步记录、云端有文档 → 必须提示恢复（核心场景）
        let h = header(revision: 3)
        XCTAssertEqual(
            VaultSyncLogic.startupAction(cloudHeader: h, lastSyncedRevision: nil),
            .offerRestore(h)
        )
    }

    func testCloudNewerOffersRestore() {
        let h = header(revision: 9)
        XCTAssertEqual(
            VaultSyncLogic.startupAction(cloudHeader: h, lastSyncedRevision: 5),
            .offerRestore(h)
        )
    }

    func testInSyncDoesNothing() {
        XCTAssertEqual(
            VaultSyncLogic.startupAction(cloudHeader: header(revision: 5), lastSyncedRevision: 5),
            .alreadyInSync
        )
    }

    func testCloudStaleMirrorsLocal() {
        // 云端比本地记录还旧（云端回滚 / 另一台老版本覆盖）→ 本地权威，镜像上去
        XCTAssertEqual(
            VaultSyncLogic.startupAction(cloudHeader: header(revision: 2), lastSyncedRevision: 5),
            .mirrorLocal
        )
    }

    func testCloudSchemaTooNewIsRefused() {
        let h = header(revision: 9, schemaVersion: VaultDocument.currentSchemaVersion + 1)
        XCTAssertEqual(
            VaultSyncLogic.startupAction(cloudHeader: h, lastSyncedRevision: nil),
            .incompatibleCloud(schemaVersion: VaultDocument.currentSchemaVersion + 1)
        )
    }

    func testNextRevision() {
        XCTAssertEqual(VaultSyncLogic.nextRevision(cloudRevision: nil, lastSyncedRevision: nil), 1)
        XCTAssertEqual(VaultSyncLogic.nextRevision(cloudRevision: 5, lastSyncedRevision: 3), 6)
        // 用户拒绝恢复后继续本地编辑：要盖过云端的更高 revision
        XCTAssertEqual(VaultSyncLogic.nextRevision(cloudRevision: 2, lastSyncedRevision: 4), 5)
    }
}

// MARK: - 文档编解码

final class VaultDocumentTests: XCTestCase {
    private func makeDocument() throws -> VaultDocument {
        let node = try ProxyURLParser.parse("trojan://pw@a.com:443#vault-node")
        var snapshot = Persistence.Snapshot()
        snapshot.nodes = [node]
        snapshot.currentNodeId = node.id
        return VaultDocument(revision: 3, modifiedAt: Date(), deviceName: "MacBook", snapshot: snapshot)
    }

    func testRoundTrip() throws {
        let doc = try makeDocument()
        let data = try doc.encoded()
        let decoded = try VaultDocument.decode(from: data)
        XCTAssertEqual(decoded.schemaVersion, VaultDocument.currentSchemaVersion)
        XCTAssertEqual(decoded.revision, 3)
        XCTAssertEqual(decoded.deviceName, "MacBook")
        XCTAssertEqual(decoded.snapshot.nodes.count, 1)
        XCTAssertEqual(decoded.snapshot.nodes.first?.name, "vault-node")
        XCTAssertEqual(decoded.snapshot.currentNodeId, doc.snapshot.currentNodeId)
    }

    func testHeaderDecodesWithoutFullSnapshot() throws {
        let doc = try makeDocument()
        let data = try doc.encoded()
        let header = try VaultDocument.decodeHeader(from: data)
        XCTAssertEqual(header.schemaVersion, VaultDocument.currentSchemaVersion)
        XCTAssertEqual(header.revision, 3)
        XCTAssertEqual(header.deviceName, "MacBook")
    }

    func testHeaderDecodesEvenIfSnapshotSchemaUnknown() throws {
        // 未来版本的文档：snapshot 结构完全未知，header 仍要能读出 schemaVersion 来拒绝恢复
        let json = """
        {
          "schemaVersion": 99,
          "revision": 42,
          "modifiedAt": "2026-07-02T00:00:00Z",
          "deviceName": "future-device",
          "snapshot": { "somethingNew": [1, 2, 3] }
        }
        """
        let header = try VaultDocument.decodeHeader(from: Data(json.utf8))
        XCTAssertEqual(header.schemaVersion, 99)
        XCTAssertEqual(header.revision, 42)
    }

    func testEncodedJSONIsHumanReadable() throws {
        let data = try makeDocument().encoded()
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\n"), "应当 prettyPrinted，多行可读")
        XCTAssertTrue(text.contains("\"schemaVersion\""))
        XCTAssertTrue(text.contains("\"snapshot\""))
    }
}

// MARK: - CloudVaultStore（用临时目录模拟 ubiquity 容器）

final class CloudVaultStoreTests: XCTestCase {
    var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vault-store-test-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        try await super.tearDown()
    }

    func testUnavailableWhenNoContainer() async throws {
        let store = CloudVaultStore(containerProvider: { nil })
        let available = await store.isAvailable()
        XCTAssertFalse(available)
        let header = try? await store.loadHeader()
        XCTAssertNil(header ?? nil)
    }

    func testSaveThenLoadRoundTrip() async throws {
        let dir = tmpDir!
        let store = CloudVaultStore(containerProvider: { dir })
        let available = await store.isAvailable()
        XCTAssertTrue(available)

        // 空容器：没有文档
        let empty = try await store.loadHeader()
        XCTAssertNil(empty)

        var snapshot = Persistence.Snapshot()
        snapshot.nodes = [try ProxyURLParser.parse("trojan://pw@a.com:443#n1")]
        let doc = VaultDocument(revision: 1, modifiedAt: Date(), deviceName: "dev", snapshot: snapshot)
        try await store.save(doc)

        // 文件落在 Documents/ 子目录（iCloud Drive 里用户可见的位置）
        let expected = dir.appendingPathComponent("Documents/qingzhou-vault.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path))

        let loaded = try await store.loadDocument()
        XCTAssertEqual(loaded?.revision, 1)
        XCTAssertEqual(loaded?.snapshot.nodes.count, 1)
    }
}

// MARK: - AppState 集成（注入假容器）

@MainActor
final class AppStateCloudVaultTests: XCTestCase {
    var tmpDir: URL!
    var cloudDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vault-appstate-test-\(UUID().uuidString)", isDirectory: true)
        cloudDir = tmpDir.appendingPathComponent("cloud", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        try await super.tearDown()
    }

    private func makeStore() -> CloudVaultStore {
        let dir = cloudDir!
        return CloudVaultStore(containerProvider: { dir })
    }

    private func makeState(store: CloudVaultStore, localDirName: String = "local") -> AppState {
        AppState(
            logger: Logger(capacity: 100, minimumLevel: .debug),
            persistence: Persistence(directory: tmpDir.appendingPathComponent(localDirName, isDirectory: true)),
            cloudVault: store
        )
    }

    func testPersistMirrorsToCloud() async throws {
        let store = makeStore()
        let state = makeState(store: store)
        XCTAssertTrue(state.settings.iCloudSyncEnabled, "iCloud 同步默认开启")

        try state.addNode(fromURL: "trojan://pw@a.com:443#first")
        await state.cloudMirrorTask?.value

        let doc = try await store.loadDocument()
        XCTAssertEqual(doc?.revision, 1)
        XCTAssertEqual(doc?.snapshot.nodes.count, 1)
        XCTAssertEqual(doc?.snapshot.nodes.first?.name, "first")
        if case .synced = state.cloudSyncStatus {} else {
            XCTFail("镜像成功后状态应为 synced，实际 \(state.cloudSyncStatus)")
        }
    }

    func testMirrorDisabledDoesNothing() async throws {
        let store = makeStore()
        let state = makeState(store: store)
        state.setCloudSyncEnabled(false)
        try state.addNode(fromURL: "trojan://pw@a.com:443#first")
        await state.cloudMirrorTask?.value
        let doc = try await store.loadDocument()
        XCTAssertNil(doc, "关掉同步后不应写云端")
    }

    func testStartupOffersRestoreAndRestoreApplies() async throws {
        let store = makeStore()
        // 「另一台设备」先写好云端文档
        let node = try ProxyURLParser.parse("trojan://pw@cloud.example.com:443#cloud-node")
        var snapshot = Persistence.Snapshot()
        snapshot.nodes = [node]
        snapshot.currentNodeId = node.id
        try await store.save(VaultDocument(revision: 5, modifiedAt: Date(), deviceName: "other-device", snapshot: snapshot))

        // 新装机：本地空、无同步记录
        let state = makeState(store: store)
        XCTAssertTrue(state.nodes.isEmpty)
        await state.runCloudVaultStartupCheck()
        XCTAssertEqual(state.cloudRestoreOffer?.deviceName, "other-device")
        XCTAssertEqual(state.cloudRestoreOffer?.revision, 5)

        await state.restoreFromCloud()
        XCTAssertNil(state.cloudRestoreOffer)
        XCTAssertEqual(state.nodes.count, 1)
        XCTAssertEqual(state.nodes.first?.name, "cloud-node")
        XCTAssertEqual(state.currentNodeId, node.id)

        state.persistence.waitForPendingWritesForTesting()
        // 覆盖本地前留了备份
        XCTAssertNotNil(state.persistence.load(Persistence.Snapshot.self, name: "state-backup-before-restore"))
        // 同步记录 = 云端 revision，下次启动不再重复提示
        let syncState = state.persistence.load(VaultSyncState.self, name: "vault-sync-state")
        XCTAssertEqual(syncState?.lastSyncedRevision, 5)

        await state.runCloudVaultStartupCheck()
        XCTAssertNil(state.cloudRestoreOffer, "恢复后再次启动检查不应重复提示")
    }

    func testStartupInSyncNoOffer() async throws {
        let store = makeStore()
        let state = makeState(store: store)
        try state.addNode(fromURL: "trojan://pw@a.com:443#first")
        await state.cloudMirrorTask?.value   // 镜像 revision 1 + 记录 lastSynced=1

        await state.runCloudVaultStartupCheck()
        XCTAssertNil(state.cloudRestoreOffer, "云端就是自己刚写的，不应提示恢复")
    }

    func testDeclineRestoreThenLocalEditOverwritesCloud() async throws {
        let store = makeStore()
        var snapshot = Persistence.Snapshot()
        snapshot.nodes = [try ProxyURLParser.parse("trojan://pw@cloud.example.com:443#cloud-node")]
        try await store.save(VaultDocument(revision: 5, modifiedAt: Date(), deviceName: "other", snapshot: snapshot))

        let state = makeState(store: store)
        await state.runCloudVaultStartupCheck()
        XCTAssertNotNil(state.cloudRestoreOffer)
        state.declineCloudRestore()
        XCTAssertNil(state.cloudRestoreOffer)

        // 本地是权威：拒绝恢复后继续编辑，云端被更高 revision 覆盖
        try state.addNode(fromURL: "trojan://pw@local.example.com:443#local-node")
        await state.cloudMirrorTask?.value
        let doc = try await store.loadDocument()
        XCTAssertEqual(doc?.revision, 6)
        XCTAssertEqual(doc?.snapshot.nodes.first?.name, "local-node")
    }

    func testUnavailableContainerDegradesGracefully() async throws {
        let store = CloudVaultStore(containerProvider: { nil })
        let state = makeState(store: store)
        await state.runCloudVaultStartupCheck()
        XCTAssertEqual(state.cloudSyncStatus, .unavailable)
        // 正常功能不受影响
        try state.addNode(fromURL: "trojan://pw@a.com:443#first")
        await state.cloudMirrorTask?.value
        XCTAssertEqual(state.nodes.count, 1)
    }

    func testIncompatibleCloudSchemaBlocksMirrorAndRestore() async throws {
        // 云端是未来版本 App 写的：既不恢复（读不懂）也不镜像（别把人家的新格式盖了）
        let dir = cloudDir!
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        let futureJSON = """
        {
          "schemaVersion": \(VaultDocument.currentSchemaVersion + 1),
          "revision": 10,
          "modifiedAt": "2026-07-02T00:00:00Z",
          "deviceName": "future",
          "snapshot": { "unknown": true }
        }
        """
        try Data(futureJSON.utf8).write(to: dir.appendingPathComponent("Documents/qingzhou-vault.json"))

        let store = makeStore()
        let state = makeState(store: store)
        await state.runCloudVaultStartupCheck()
        XCTAssertNil(state.cloudRestoreOffer)
        XCTAssertEqual(state.cloudSyncStatus, .incompatibleCloud(schemaVersion: VaultDocument.currentSchemaVersion + 1))

        try state.addNode(fromURL: "trojan://pw@a.com:443#first")
        await state.cloudMirrorTask?.value
        let header = try await store.loadHeader()
        XCTAssertEqual(header?.revision, 10, "不兼容的云文档不能被覆盖")
    }
}
