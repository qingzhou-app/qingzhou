import XCTest
import QingzhouCore
import QingzhouProtocols
import QingzhouLogging
import QingzhouSpeedTest
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

    // MARK: 弹窗降噪（#启动恢复弹窗优化）

    func testCloudNewerButSameContentAdoptsSilently() {
        // 云端 revision 更高、但规范化内容和本机一致（例如另一台设备恢复历史版本后回推）
        // → 静默采认云端 revision，不弹恢复确认
        let h = header(revision: 9)
        XCTAssertEqual(
            VaultSyncLogic.startupAction(
                cloudHeader: h, lastSyncedRevision: 5,
                cloudContentHash: "same-hash", localContentHash: "same-hash"),
            .adoptCloudRevision(h)
        )
        // 卸载重装、云端内容恰好与本机一致（都为空）→ 同样不弹
        XCTAssertEqual(
            VaultSyncLogic.startupAction(
                cloudHeader: h, lastSyncedRevision: nil,
                cloudContentHash: "same-hash", localContentHash: "same-hash"),
            .adoptCloudRevision(h)
        )
    }

    func testCloudNewerWithDifferentContentStillOffers() {
        let h = header(revision: 9)
        XCTAssertEqual(
            VaultSyncLogic.startupAction(
                cloudHeader: h, lastSyncedRevision: 5,
                cloudContentHash: "cloud-hash", localContentHash: "local-hash"),
            .offerRestore(h)
        )
        // 任一侧哈希缺失（旧文档 / 计算失败）→ 无从比较，保守起见照旧提示
        XCTAssertEqual(
            VaultSyncLogic.startupAction(
                cloudHeader: h, lastSyncedRevision: 5,
                cloudContentHash: nil, localContentHash: "local-hash"),
            .offerRestore(h)
        )
    }

    func testDeclinedRevisionDoesNotRePrompt() {
        // 用户对 rev 9 点过「暂不恢复」→ 下次启动同一个 rev 9 不再弹
        let h = header(revision: 9)
        XCTAssertEqual(
            VaultSyncLogic.startupAction(
                cloudHeader: h, lastSyncedRevision: 5, lastDeclinedRevision: 9,
                cloudContentHash: "cloud-hash", localContentHash: "local-hash"),
            .skipDeclinedRevision(h)
        )
        // 云端出了新 revision（真有新变化）→ 恢复提示
        let h10 = header(revision: 10)
        XCTAssertEqual(
            VaultSyncLogic.startupAction(
                cloudHeader: h10, lastSyncedRevision: 5, lastDeclinedRevision: 9,
                cloudContentHash: "cloud-hash", localContentHash: "local-hash"),
            .offerRestore(h10)
        )
    }

    func testSameContentAdoptTakesPrecedenceOverDecline() {
        // 内容一致时静默采认（并顺带更新同步记录），优先于「拒绝过」判断
        let h = header(revision: 9)
        XCTAssertEqual(
            VaultSyncLogic.startupAction(
                cloudHeader: h, lastSyncedRevision: 5, lastDeclinedRevision: 9,
                cloudContentHash: "same", localContentHash: "same"),
            .adoptCloudRevision(h)
        )
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

    func testHeaderCarriesContentCounts() throws {
        // 计数冗余在头部：恢复弹窗 / 版本列表不解码 snapshot 也能显示「N 订阅 · M 节点」
        let data = try makeDocument().encoded()
        let header = try VaultDocument.decodeHeader(from: data)
        XCTAssertEqual(header.subscriptionCount, 0)
        XCTAssertEqual(header.nodeCount, 1)
        XCTAssertEqual(header.contentSummary, "0 个订阅 · 1 个节点")
    }

    func testHeaderWithoutCountsShowsUnknown() throws {
        // 计数字段引入前写的旧文档：显示「未知」而不是崩 / 显示 0
        let json = """
        {
          "schemaVersion": 1,
          "revision": 1,
          "modifiedAt": "2026-07-01T00:00:00Z",
          "deviceName": "old-device",
          "snapshot": {}
        }
        """
        let header = try VaultDocument.decodeHeader(from: Data(json.utf8))
        XCTAssertNil(header.nodeCount)
        XCTAssertEqual(header.contentSummary, "内容数量未知（旧版本文档）")
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

// MARK: - 镜像内容规范化

final class VaultSnapshotNormalizerTests: XCTestCase {
    private func makeSnapshot() throws -> Persistence.Snapshot {
        var node = try ProxyURLParser.parse("trojan://pw@a.com:443#n1")
        node.lastLatencyMs = 123
        node.lastTestedAt = Date()
        var sub = Subscription(name: "s", url: URL(string: "https://example.com/sub")!)
        sub.lastUpdatedAt = Date()
        sub.usedBytes = 1024
        sub.totalBytes = 4096
        var snapshot = Persistence.Snapshot()
        snapshot.nodes = [node]
        snapshot.subscriptions = [sub]
        snapshot.currentNodeId = node.id
        return snapshot
    }

    func testStripsDeviceLocalTransientFields() throws {
        let normalized = VaultSnapshotNormalizer.normalized(try makeSnapshot())
        XCTAssertNil(normalized.currentNodeId, "当前节点是设备本地选择，不上云")
        XCTAssertNil(normalized.nodes.first?.lastLatencyMs)
        XCTAssertNil(normalized.nodes.first?.lastTestedAt)
        XCTAssertNil(normalized.subscriptions.first?.lastUpdatedAt)
        XCTAssertNil(normalized.subscriptions.first?.usedBytes)
        // 服务端事实保留
        XCTAssertEqual(normalized.subscriptions.first?.totalBytes, 4096)
        XCTAssertEqual(normalized.nodes.first?.name, "n1")
    }

    func testContentHashIgnoresTransientsButSeesRealChanges() throws {
        let base = try makeSnapshot()
        var latencyChanged = base
        latencyChanged.nodes[0].lastLatencyMs = 999
        latencyChanged.nodes[0].lastTestedAt = Date(timeIntervalSinceNow: 100)
        latencyChanged.nodes[0].lastProxiedLatencyMs = 456
        latencyChanged.nodes[0].lastProxiedTestedAt = Date(timeIntervalSinceNow: 50)
        latencyChanged.currentNodeId = nil
        latencyChanged.subscriptions[0].usedBytes = 9999

        let h1 = try VaultSnapshotNormalizer.contentHash(of: VaultSnapshotNormalizer.normalized(base))
        let h2 = try VaultSnapshotNormalizer.contentHash(of: VaultSnapshotNormalizer.normalized(latencyChanged))
        XCTAssertEqual(h1, h2, "只有瞬态字段不同 → 规范化后哈希应一致")

        var ruleChanged = base
        ruleChanged.customRules = [Rule(type: .domainSuffix, value: "example.com", target: .proxy)]
        let h3 = try VaultSnapshotNormalizer.contentHash(of: VaultSnapshotNormalizer.normalized(ruleChanged))
        XCTAssertNotEqual(h1, h3, "实质内容变化 → 哈希必须不同")
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

    func testRollingBackupsKeptAndPruned() async throws {
        let dir = tmpDir!
        let store = CloudVaultStore(containerProvider: { dir })
        var snapshot = Persistence.Snapshot()
        snapshot.nodes = [try ProxyURLParser.parse("trojan://pw@a.com:443#n1")]
        for rev in 1...(CloudVaultStore.maxBackups + 2) {
            try await store.save(VaultDocument(
                revision: rev, modifiedAt: Date(), deviceName: "dev", snapshot: snapshot))
        }
        let backups = await store.listBackups()
        XCTAssertEqual(backups.count, CloudVaultStore.maxBackups, "历史版本应裁剪到最近 \(CloudVaultStore.maxBackups) 份")
        XCTAssertEqual(backups.map(\.header.revision), [7, 6, 5, 4, 3], "按 revision 降序、保最新")
        // 历史版本文件人类可读、名字带 revision 和设备
        XCTAssertEqual(backups.first?.fileName, "qingzhou-vault-r7-dev.json")

        // 从历史版本能读回完整文档
        let doc = try await store.loadBackupDocument(fileName: "qingzhou-vault-r3-dev.json")
        XCTAssertEqual(doc?.revision, 3)
        XCTAssertEqual(doc?.snapshot.nodes.count, 1)
    }

    func testNotYetDownloadedPlaceholderIsNotTreatedAsMissing() async throws {
        // 云端有文档但本机只有 .icloud 占位符（还没下载完）：必须报「下载中」，
        // 不能当「没有文档」—— 否则启动检查会用空本地盖掉云端
        let dir = tmpDir!
        let docs = dir.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: docs.appendingPathComponent(".qingzhou-vault.json.icloud"))

        let store = CloudVaultStore(containerProvider: { dir })
        do {
            _ = try await store.loadHeader()
            XCTFail("应当抛 notYetDownloaded")
        } catch let error as CloudVaultStore.StoreError {
            XCTAssertEqual(error, .notYetDownloaded)
        }
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

    /// 可变的容器指针：模拟「先未登录 iCloud（容器 nil）→ 登录后容器出现」的重试场景。
    private final class ContainerBox: @unchecked Sendable {
        var url: URL?
    }

    /// 按 host 返回固定延迟的假探针 —— 恢复后会自动全量测速，测试不能真发 TCP 探测
    /// （*.example.com 解析失败 + 5s 超时会把测试拖爆）。
    private struct FakeLatencyProber: LatencyProber {
        var latencyByHost: [String: Int] = [:]
        func probe(_ url: URL, timeout: TimeInterval) async -> LatencyResult {
            LatencyResult(url: url, latencyMs: latencyByHost[url.host ?? ""] ?? 42)
        }
    }

    private func makeState(
        store: CloudVaultStore,
        localDirName: String = "local",
        latencyByHost: [String: Int] = [:]
    ) -> AppState {
        AppState(
            logger: Logger(capacity: 100, minimumLevel: .debug),
            persistence: Persistence(directory: tmpDir.appendingPathComponent(localDirName, isDirectory: true)),
            nodeSelector: NodeSelector(prober: FakeLatencyProber(latencyByHost: latencyByHost)),
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
        XCTAssertEqual(state.cloudRestoreOffer?.header.deviceName, "other-device")
        XCTAssertEqual(state.cloudRestoreOffer?.header.revision, 5)
        XCTAssertEqual(state.cloudRestoreOffer?.header.contentSummary, "0 个订阅 · 1 个节点")

        await state.restoreFromCloud(candidate: state.cloudRestoreOffer)
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

    /// #启动恢复弹窗优化 之一：用户点过「暂不恢复」→ 杀掉 App 重开（同一本地目录、
    /// 同一个云端 revision）→ 不再重复弹。这是「每次打开都弹」的直接根因。
    func testDeclinePersistsAcrossRelaunch() async throws {
        let store = makeStore()
        var snapshot = Persistence.Snapshot()
        snapshot.nodes = [try ProxyURLParser.parse("trojan://pw@cloud.example.com:443#cloud-node")]
        try await store.save(VaultDocument(revision: 5, modifiedAt: Date(), deviceName: "other", snapshot: snapshot))

        let state = makeState(store: store)
        await state.runCloudVaultStartupCheck()
        XCTAssertNotNil(state.cloudRestoreOffer)
        state.declineCloudRestore()

        // 「重启 App」：同一本地目录新建 AppState
        let relaunched = makeState(store: store)
        await relaunched.runCloudVaultStartupCheck()
        XCTAssertNil(relaunched.cloudRestoreOffer, "拒绝过的 revision 重启后不应再弹")

        // 云端出了真正的新变化（新 revision + 新内容）→ 恢复提示
        snapshot.customRules = [Rule(type: .domainSuffix, value: "example.com", target: .proxy)]
        try await store.save(VaultDocument(revision: 6, modifiedAt: Date(), deviceName: "other", snapshot: snapshot))
        let relaunched2 = makeState(store: store)
        await relaunched2.runCloudVaultStartupCheck()
        XCTAssertEqual(relaunched2.cloudRestoreOffer?.header.revision, 6, "云端真有新变化时必须恢复提示")
    }

    /// #启动恢复弹窗优化 之二：云端 revision 更高但用户内容与本机一致 → 静默采认，
    /// 不弹窗；同步记录跟进云端 revision，下次启动 alreadyInSync。
    func testCloudNewerSameContentAdoptedWithoutPrompt() async throws {
        let store = makeStore()
        let state = makeState(store: store)
        try state.addNode(fromURL: "trojan://pw@a.com:443#n1")
        await state.cloudMirrorTask?.value   // rev 1，header 带 contentHash

        // 另一台设备以更高 revision 回推了**内容相同**的文档（如恢复历史版本后回推）
        let mirrored = try await store.loadDocument()!
        try await store.save(VaultDocument(
            revision: 7, modifiedAt: Date(), deviceName: "other",
            snapshot: mirrored.snapshot,
            contentHash: mirrored.contentHash))

        let relaunched = makeState(store: store)
        await relaunched.runCloudVaultStartupCheck()
        XCTAssertNil(relaunched.cloudRestoreOffer, "内容一致只是 revision 更高 → 不该打扰用户")
        relaunched.persistence.waitForPendingWritesForTesting()
        let syncState = relaunched.persistence.load(VaultSyncState.self, name: "vault-sync-state")
        XCTAssertEqual(syncState?.lastSyncedRevision, 7, "应静默采认云端 revision")
    }

    /// #启动恢复弹窗优化 之三：旧版云文档（头部没有 contentHash）→ 回退读全文算哈希，
    /// 内容一致同样不弹。
    func testLegacyCloudDocWithoutHashFallsBackToFullDocCompare() async throws {
        let store = makeStore()
        let state = makeState(store: store)
        try state.addNode(fromURL: "trojan://pw@a.com:443#n1")
        await state.cloudMirrorTask?.value

        // 同内容、更高 revision，但不带 contentHash（模拟旧版本 App 写的文档）
        let mirrored = try await store.loadDocument()!
        try await store.save(VaultDocument(
            revision: 7, modifiedAt: Date(), deviceName: "old-app",
            snapshot: mirrored.snapshot,
            contentHash: nil))

        let relaunched = makeState(store: store)
        await relaunched.runCloudVaultStartupCheck()
        XCTAssertNil(relaunched.cloudRestoreOffer, "旧文档也应通过全文哈希比对识别出内容一致")
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

    /// 用户真机踩到的完整场景：删空 → 空数据镜像上云（LWW，主文档被覆盖）→
    /// 「立即恢复」列出历史版本（计数可见）→ 选删空前那份 → 数据找回、云端主文档也被救回。
    func testDeleteAllThenRecoverFromRollingBackup() async throws {
        let store = makeStore()
        let state = makeState(store: store)

        // 1) 正常使用：两个节点，镜像 rev1（同时落历史版本 r1）
        try state.addNode(fromURL: "trojan://pw@a.com:443#keep-1")
        try state.addNode(fromURL: "trojan://pw@b.com:443#keep-2")
        await state.cloudMirrorTask?.value

        // 2) 用户删光所有节点 → 空快照以 rev2 覆盖云端主文档（这就是事故现场）
        for node in state.nodes { state.removeNode(node) }
        await state.cloudMirrorTask?.value
        let mainDoc = try await store.loadDocument()
        XCTAssertEqual(mainDoc?.snapshot.nodes.count, 0, "主文档确实被空数据覆盖（复现事故）")
        let mainRev = try XCTUnwrap(mainDoc?.revision)

        // 3) 「立即恢复」→ 版本列表：云端当前版（0 节点）+ 历史版本（2 节点），计数可见
        await state.requestManualCloudRestore()
        let options = try XCTUnwrap(state.cloudVersionOptions, "多个版本应弹选择列表")
        XCTAssertEqual(options.first?.backupFileName, nil, "第一项是云端当前版")
        XCTAssertEqual(options.first?.header.nodeCount, 0, "当前版计数 0 —— 用户一眼看出是空的")
        let goodBackup = try XCTUnwrap(
            options.first(where: { ($0.header.nodeCount ?? 0) == 2 }),
            "删空前的历史版本应在列表里")

        // 4) 选历史版本 → 确认恢复 → 节点找回。
        //    严格按真机 UI 时序：选中先收 sheet（候选暂存）→ sheet onDismiss 才呈现 alert →
        //    alert 呈现时捕获 presenting 值 → dismiss 先清 offer →
        //    恢复 Task 才执行（拿捕获值，不能再读 offer）
        state.chooseCloudRestoreCandidate(goodBackup)
        XCTAssertNil(state.cloudVersionOptions)
        state.presentPendingCloudRestoreOffer()          // sheet onDismiss
        XCTAssertEqual(state.cloudRestoreOffer, goodBackup)
        let presented = state.cloudRestoreOffer          // alert 的 presenting 捕获
        state.declineCloudRestore()                      // dismiss：isPresented → false
        await state.restoreFromCloud(candidate: presented)
        XCTAssertEqual(state.nodes.count, 2)
        XCTAssertEqual(Set(state.nodes.map(\.name)), ["keep-1", "keep-2"])

        // 5) 云端主文档也被救回：恢复的内容以更高 revision 回推
        let rescued = try await store.loadDocument()
        XCTAssertEqual(rescued?.snapshot.nodes.count, 2, "云端主文档应被恢复内容回推救回")
        XCTAssertGreaterThan(try XCTUnwrap(rescued?.revision), mainRev)
    }

    /// 真机事故 #2 的复现：版本列表摘要正确（1 订阅 30 节点），选它恢复却得到 0/0。
    /// 根因：确认 alert 的 dismiss 会先把 cloudRestoreOffer 清成 nil，恢复 Task 里再读
    /// offer 恒为 nil → 用户选的历史版本被忽略、恢复成了（该设备视角仍是空的）云端主文档。
    /// 修复后：候选经 alert presenting 参数显式传入，与 offer 生命周期解耦。
    func testChosenBackupSurvivesAlertDismissClearingOffer() async throws {
        let store = makeStore()

        // 云端：历史版本 r1 = 1 订阅 + 30 节点；主文档 rev2 = 空（被某台设备删空后镜像）
        var full = Persistence.Snapshot()
        full.subscriptions = [Subscription(name: "my-sub", url: URL(string: "https://example.com/sub")!)]
        full.nodes = try (1...30).map { try ProxyURLParser.parse("trojan://pw@host\($0).example.com:443#node-\($0)") }
        try await store.save(VaultDocument(revision: 1, modifiedAt: Date(), deviceName: "mac", snapshot: full))
        try await store.save(VaultDocument(revision: 2, modifiedAt: Date(), deviceName: "phone", snapshot: Persistence.Snapshot()))

        let state = makeState(store: store)
        XCTAssertTrue(state.nodes.isEmpty && state.subscriptions.isEmpty)

        // 「立即恢复」→ 版本列表里有摘要正确的历史版本
        await state.requestManualCloudRestore()
        let options = try XCTUnwrap(state.cloudVersionOptions)
        let good = try XCTUnwrap(options.first(where: { $0.header.nodeCount == 30 }))
        XCTAssertEqual(good.header.contentSummary, "1 个订阅 · 30 个节点")
        XCTAssertNotNil(good.backupFileName, "1/30 那份是历史版本，不是主文档")

        // 用户点选 → sheet 收起（onDismiss 呈现 alert，presenting 捕获）→ 点「恢复」→
        // dismiss 先清 offer → Task 执行
        state.chooseCloudRestoreCandidate(good)
        state.presentPendingCloudRestoreOffer()          // sheet onDismiss
        let presented = state.cloudRestoreOffer
        state.declineCloudRestore()                      // 真机上先于恢复 Task 发生
        XCTAssertNil(state.cloudRestoreOffer, "复现前提：恢复执行时 offer 已被 dismiss 清空")
        await state.restoreFromCloud(candidate: presented)

        // 修复前这里恢复出的是主文档（空）→ 0/0；修复后必须是选中的那份
        XCTAssertEqual(state.subscriptions.count, 1, "恢复后订阅应非空（事故里这里是 0）")
        XCTAssertEqual(state.nodes.count, 30, "恢复后节点应非空（事故里这里是 0）")
        XCTAssertEqual(state.subscriptions.first?.name, "my-sub")

        // UI 可观察状态 + 本地持久化也都是恢复后的数据
        XCTAssertEqual(state.sortedNodes.count, 30)
        state.persistence.waitForPendingWritesForTesting()
        let persisted = state.persistence.loadSnapshot()
        XCTAssertEqual(persisted.nodes.count, 30)
        XCTAssertEqual(persisted.subscriptions.count, 1)
    }

    /// 真机事故 #3：版本选择 sheet 里点选 → 确认 alert 第一次弹出后自动消失，再来一遍才正常。
    /// 根因：chooseCloudRestoreCandidate 在 sheet 开始收起的同一刻就置 cloudRestoreOffer，
    /// alert 在 sheet dismiss 动画进行中呈现 → iOS 呈现层冲突把 alert 吞掉；且系统 dismiss
    /// 走 isPresented binding 的 set(false) 顺手 declineCloudRestore() 清掉了 offer。
    /// 修复后：候选暂存在 pendingCloudRestoreCandidate，sheet 的 onDismiss（呈现层已空闲）
    /// 才经 presentPendingCloudRestoreOffer() 进确认弹窗。
    func testChooseCandidateDefersConfirmAlertUntilSheetDismissed() async throws {
        let store = makeStore()
        var full = Persistence.Snapshot()
        full.nodes = [try ProxyURLParser.parse("trojan://pw@a.example.com:443#n1")]
        try await store.save(VaultDocument(revision: 1, modifiedAt: Date(), deviceName: "mac", snapshot: full))
        try await store.save(VaultDocument(revision: 2, modifiedAt: Date(), deviceName: "phone", snapshot: Persistence.Snapshot()))

        let state = makeState(store: store)
        await state.requestManualCloudRestore()
        let options = try XCTUnwrap(state.cloudVersionOptions, "两个版本应弹选择列表")
        let good = try XCTUnwrap(options.first(where: { $0.header.nodeCount == 1 }))

        // 点选：sheet 收起、候选暂存 —— 此刻绝不能置 offer（alert 会被收起中的 sheet 吞掉）
        state.chooseCloudRestoreCandidate(good)
        XCTAssertNil(state.cloudVersionOptions, "选中后 sheet 应收起")
        XCTAssertNil(state.cloudRestoreOffer, "sheet 收起动画期间不能呈现确认 alert（iOS 会吞掉）")
        XCTAssertEqual(state.pendingCloudRestoreCandidate, good)

        // sheet onDismiss（收起完成、呈现层空闲）→ 确认弹窗此刻才呈现
        state.presentPendingCloudRestoreOffer()
        XCTAssertEqual(state.cloudRestoreOffer, good)
        XCTAssertNil(state.pendingCloudRestoreCandidate, "候选已交接给确认弹窗")
    }

    /// 版本选择 sheet 被取消（点「取消」/ 下滑关闭）→ onDismiss 照样触发，但没有暂存候选，
    /// 不该凭空弹出确认弹窗。
    func testCancelledVersionSheetPresentsNothingOnDismiss() async throws {
        let store = makeStore()
        var full = Persistence.Snapshot()
        full.nodes = [try ProxyURLParser.parse("trojan://pw@a.example.com:443#n1")]
        try await store.save(VaultDocument(revision: 1, modifiedAt: Date(), deviceName: "mac", snapshot: full))
        try await store.save(VaultDocument(revision: 2, modifiedAt: Date(), deviceName: "phone", snapshot: Persistence.Snapshot()))

        let state = makeState(store: store)
        await state.requestManualCloudRestore()
        XCTAssertNotNil(state.cloudVersionOptions)

        state.dismissCloudVersionOptions()       // 用户取消
        state.presentPendingCloudRestoreOffer()  // sheet onDismiss 无条件触发
        XCTAssertNil(state.cloudRestoreOffer, "没选任何版本，不该弹确认")
        XCTAssertNil(state.pendingCloudRestoreCandidate)
    }

    /// 复验 #18：点「立即恢复」后 sheet 出现有可感知延迟 —— 旧实现在呈现 sheet 前同步
    /// await 了 iCloud 读取。新实现：点击瞬间置 .loading（sheet 立即呈现），读取异步填充。
    func testManualRestoreLoadsAsyncIntoAlreadyPresentedSheet() async throws {
        let store = makeStore()
        var full = Persistence.Snapshot()
        full.nodes = [try ProxyURLParser.parse("trojan://pw@a.example.com:443#n1")]
        try await store.save(VaultDocument(revision: 1, modifiedAt: Date(), deviceName: "mac", snapshot: full))
        try await store.save(VaultDocument(revision: 2, modifiedAt: Date(), deviceName: "phone", snapshot: Persistence.Snapshot()))

        let state = makeState(store: store)
        // .loading 中间态由 requestManualCloudRestore 第一行同步置入 —— sheet 的呈现
        // 不等任何 await（这正是修复点）；读取完成后落到 .loaded。
        await state.requestManualCloudRestore()
        XCTAssertEqual(state.cloudVersionOptions?.count, 2)
        if case .loaded = state.cloudVersionLoad {} else {
            XCTFail("读取完成后应为 .loaded，实际 \(String(describing: state.cloudVersionLoad))")
        }
    }

    /// 只有一份可恢复版本：也进列表（点一下即确认弹窗）—— sheet 已经在屏，
    /// 不再走旧的「跳过 sheet 直进确认弹窗」路径（sheet 自动收起再弹 alert 很突兀）。
    func testManualRestoreSingleVersionShowsInSheetList() async throws {
        let store = makeStore()
        var full = Persistence.Snapshot()
        full.nodes = [try ProxyURLParser.parse("trojan://pw@a.example.com:443#n1")]
        try await store.save(VaultDocument(revision: 1, modifiedAt: Date(), deviceName: "mac", snapshot: full))

        let state = makeState(store: store)
        await state.requestManualCloudRestore()
        XCTAssertEqual(state.cloudVersionOptions?.count, 1, "单版本也应显示在列表里")
        XCTAssertNil(state.cloudRestoreOffer, "sheet 在屏时不能直接弹确认（会撞呈现层）")
    }

    /// iCloud 不可用 → 错误留在 sheet 内展示（不再是 toast 一闪而过）；
    /// 「重试」在容器恢复后应加载出列表。
    func testManualRestoreFailureShownInSheetAndRetryRecovers() async throws {
        // 先往云端目录写好一份文档（供重试成功时读到）
        let seeded = makeStore()
        var full = Persistence.Snapshot()
        full.nodes = [try ProxyURLParser.parse("trojan://pw@a.example.com:443#n1")]
        try await seeded.save(VaultDocument(revision: 1, modifiedAt: Date(), deviceName: "mac", snapshot: full))

        // 容器先不可用（未登录 iCloud 的效果）
        let box = ContainerBox()
        let state = makeState(store: CloudVaultStore(containerProvider: { box.url }))
        await state.requestManualCloudRestore()
        guard case .failed(let message) = state.cloudVersionLoad else {
            return XCTFail("不可用应变 .failed，实际 \(String(describing: state.cloudVersionLoad))")
        }
        XCTAssertTrue(message.contains("iCloud 不可用"), "错误文案要说清原因：\(message)")
        XCTAssertNil(state.cloudVersionOptions)

        // 用户登录了 iCloud → 点 sheet 内「重试」
        box.url = cloudDir
        await state.loadCloudVersionOptions()
        XCTAssertEqual(state.cloudVersionOptions?.count, 1, "重试成功应填充列表")
    }

    /// 云端空空如也：错误信息也留在 sheet 内（iCloud 元数据可能还没同步完，重试常常就有了）。
    func testManualRestoreEmptyCloudShowsFailedInSheet() async throws {
        let state = makeState(store: makeStore())
        await state.requestManualCloudRestore()
        XCTAssertEqual(state.cloudVersionLoad, .failed("iCloud 上没有找到备份"))
    }

    /// 用户在读取完成前就关掉了 sheet → 迟到的结果必须被丢弃，不能把 sheet 复活。
    func testDismissedSheetDropsLateLoadResult() async throws {
        let store = makeStore()
        var full = Persistence.Snapshot()
        full.nodes = [try ProxyURLParser.parse("trojan://pw@a.example.com:443#n1")]
        try await store.save(VaultDocument(revision: 1, modifiedAt: Date(), deviceName: "mac", snapshot: full))

        let state = makeState(store: store)
        state.dismissCloudVersionOptions()       // sheet 不在屏（等价于读取中途被关掉）
        await state.loadCloudVersionOptions()
        XCTAssertNil(state.cloudVersionLoad, "sheet 已关，迟到的读取结果不能复活 sheet")
        XCTAssertFalse(state.isCloudVersionSheetPresented)
    }

    /// 复验 #18 二次打回：sheet 弹出后立即自己沉下去。根因是 isPresented binding 依赖
    /// 会中途变化的加载态（.loading→.loaded 落在呈现动画进行中，mid-transition 重渲染
    /// 打断呈现簿记 / 重建 Form cell 的 hosting view）。修复后呈现开关是独立稳定 Bool：
    /// **加载完成 / 失败都绝不能碰它**，只有显式关闭（取消 / 点选）才能关。
    func testSheetPresenceStaysOnAcrossLoadTransitions() async throws {
        // 成功路径：加载完成后呈现开关必须还开着
        let store = makeStore()
        var full = Persistence.Snapshot()
        full.nodes = [try ProxyURLParser.parse("trojan://pw@a.example.com:443#n1")]
        try await store.save(VaultDocument(revision: 1, modifiedAt: Date(), deviceName: "mac", snapshot: full))
        let state = makeState(store: store)
        XCTAssertFalse(state.isCloudVersionSheetPresented)
        await state.requestManualCloudRestore()
        XCTAssertTrue(state.isCloudVersionSheetPresented, ".loading→.loaded 不能收 sheet（弹出即沉的根因）")
        XCTAssertNotNil(state.cloudVersionOptions)

        // 失败路径（iCloud 不可用）：错误留在 sheet 内，呈现开关同样不能动
        let state2 = makeState(
            store: CloudVaultStore(containerProvider: { nil }), localDirName: "local2")
        await state2.requestManualCloudRestore()
        XCTAssertTrue(state2.isCloudVersionSheetPresented, ".loading→.failed 也不能收 sheet")
        if case .failed = state2.cloudVersionLoad {} else {
            XCTFail("应为 .failed，实际 \(String(describing: state2.cloudVersionLoad))")
        }

        // 只有显式关闭才关呈现开关
        state.dismissCloudVersionOptions()
        XCTAssertFalse(state.isCloudVersionSheetPresented)
        XCTAssertNil(state.cloudVersionLoad)
    }

    /// 点选版本：呈现开关与内容态一起清（sheet 收起），候选暂存等 onDismiss 接棒。
    func testChoosingCandidateClosesSheetPresence() async throws {
        let store = makeStore()
        var full = Persistence.Snapshot()
        full.nodes = [try ProxyURLParser.parse("trojan://pw@a.example.com:443#n1")]
        try await store.save(VaultDocument(revision: 1, modifiedAt: Date(), deviceName: "mac", snapshot: full))
        let state = makeState(store: store)
        await state.requestManualCloudRestore()
        let option = try XCTUnwrap(state.cloudVersionOptions?.first)

        state.chooseCloudRestoreCandidate(option)
        XCTAssertFalse(state.isCloudVersionSheetPresented, "点选后 sheet 应收起")
        XCTAssertNil(state.cloudVersionLoad)
        XCTAssertEqual(state.pendingCloudRestoreCandidate, option)
    }

    /// 恢复成功后应与「首次添加订阅」一致：自动全量测速 + 择优选延迟最低节点，
    /// 而不是留一列没有延迟数据的裸节点。
    func testRestoreAutoMeasuresAndPicksBestNode() async throws {
        let store = makeStore()
        var snapshot = Persistence.Snapshot()
        snapshot.nodes = [
            try ProxyURLParser.parse("trojan://pw@slow.example.com:443#slow"),
            try ProxyURLParser.parse("trojan://pw@fast.example.com:443#fast"),
            try ProxyURLParser.parse("trojan://pw@mid.example.com:443#mid"),
        ]
        try await store.save(VaultDocument(revision: 3, modifiedAt: Date(), deviceName: "other", snapshot: snapshot))

        let state = makeState(store: store, latencyByHost: [
            "slow.example.com": 300, "fast.example.com": 20, "mid.example.com": 80,
        ])
        await state.runCloudVaultStartupCheck()
        XCTAssertNotNil(state.cloudRestoreOffer)
        await state.restoreFromCloud(candidate: state.cloudRestoreOffer)

        XCTAssertTrue(state.nodes.allSatisfy { $0.lastLatencyMs != nil }, "恢复后应自动全量测速")
        XCTAssertEqual(state.currentNode?.name, "fast", "应自动择优选中延迟最低的节点")
        XCTAssertEqual(state.toast, "已为你选择延迟最优节点：fast")
    }

    /// 恢复出来是空快照（0 节点）→ 没什么可测的，不触发测速，toast 保持原样。
    func testRestoreEmptySnapshotSkipsSpeedTest() async throws {
        let store = makeStore()
        try await store.save(VaultDocument(
            revision: 1, modifiedAt: Date(), deviceName: "other", snapshot: Persistence.Snapshot()))

        let state = makeState(store: store)
        await state.runCloudVaultStartupCheck()
        await state.restoreFromCloud(candidate: state.cloudRestoreOffer)

        XCTAssertTrue(state.nodes.isEmpty)
        XCTAssertNil(state.currentNodeId)
        XCTAssertEqual(state.toast, "已从 iCloud 恢复（0 个订阅、0 个节点）")
    }

    /// 测速 / 自动择优只改瞬态字段（延迟 / 当前节点）→ 镜像应当被内容去重跳过，
    /// 不产生新 revision、不写新备份（否则 5 份滚动备份很快全是雷同版本）。
    func testLatencyAndSelectionChangesDoNotCreateNewRevision() async throws {
        let store = makeStore()
        let state = makeState(store: store)
        try state.addNode(fromURL: "trojan://pw@a.com:443#n1")
        try state.addNode(fromURL: "trojan://pw@b.com:443#n2")
        await state.cloudMirrorTask?.value
        let rev1 = try await store.loadHeader()?.revision
        XCTAssertEqual(rev1, 1)

        // 模拟自动测速落库：改延迟字段 + persist（measureAllNodes 的持久化路径就是这两步）
        state.nodes[0].lastLatencyMs = 42
        state.nodes[0].lastTestedAt = Date()
        state.nodes[1].lastLatencyMs = 88
        state.nodes[1].lastTestedAt = Date()
        state.persist()
        await state.cloudMirrorTask?.value
        // 模拟自动择优：切换当前节点（也会 persist）
        state.select(state.nodes[1])
        await state.cloudMirrorTask?.value

        let header = try await store.loadHeader()
        XCTAssertEqual(header?.revision, 1, "只有瞬态字段变化不应产生新 revision")
        let backups = await store.listBackups()
        XCTAssertEqual(backups.count, 1, "不应写出新备份")
        if case .synced = state.cloudSyncStatus {} else {
            XCTFail("去重跳过也应显示已同步，实际 \(state.cloudSyncStatus)")
        }
    }

    func testRealConfigChangeStillCreatesNewRevision() async throws {
        let store = makeStore()
        let state = makeState(store: store)
        try state.addNode(fromURL: "trojan://pw@a.com:443#n1")
        await state.cloudMirrorTask?.value
        let revAfterAdd = try await store.loadHeader()?.revision
        XCTAssertEqual(revAfterAdd, 1)

        // 实质变化：加一条自定义规则 → 新 revision + 新备份
        state.addCustomRule(Rule(type: .domainSuffix, value: "example.com", target: .proxy))
        await state.cloudMirrorTask?.value
        let revAfterRule = try await store.loadHeader()?.revision
        XCTAssertEqual(revAfterRule, 2)
        let backups = await store.listBackups()
        XCTAssertEqual(backups.count, 2)
    }

    func testIdenticalContentMirroredOnlyOnce() async throws {
        let store = makeStore()
        let state = makeState(store: store)
        try state.addNode(fromURL: "trojan://pw@a.com:443#n1")
        await state.cloudMirrorTask?.value
        // 内容没变，连续 persist 两次 → 不应产生新 revision
        state.persist()
        await state.cloudMirrorTask?.value
        state.persist()
        await state.cloudMirrorTask?.value
        let revision = try await store.loadHeader()?.revision
        XCTAssertEqual(revision, 1)
        let backups = await store.listBackups()
        XCTAssertEqual(backups.count, 1)
    }

    /// vault 不带瞬态字段 → 恢复时必须从本地回填，别把本机刚测的延迟 / 正在用的节点清掉。
    /// 恢复后会自动全量测速：非排除节点随即拿到新鲜延迟（回填值被覆盖是预期）；
    /// 排除节点不参与测速 —— 回填的本机数据必须原样保留（回填在新流水线下的可观察效果）。
    func testRestorePreservesLocalTransientData() async throws {
        let store = makeStore()
        let state = makeState(store: store, latencyByHost: ["a.com": 55])
        try state.addNode(fromURL: "trojan://pw@a.com:443#n1")
        try state.addNode(fromURL: "trojan://pw@b.com:443#n2")
        state.nodes[1].isExcluded = true
        state.select(state.nodes[0])
        await state.cloudMirrorTask?.value

        // 本机测速结果 + 当前选择
        state.nodes[0].lastLatencyMs = 33
        state.nodes[0].lastTestedAt = Date()
        state.nodes[1].lastLatencyMs = 33
        state.nodes[1].lastTestedAt = Date()
        let localCurrentId = state.currentNodeId

        // 云端来了一份更新的规范化文档（同一批节点 + 新增规则），模拟另一台设备的编辑
        var cloudSnapshot = VaultSnapshotNormalizer.normalized(
            Persistence.Snapshot(nodes: state.nodes, settings: state.settings))
        cloudSnapshot.customRules = [Rule(type: .domainSuffix, value: "example.com", target: .proxy)]
        try await store.save(VaultDocument(
            revision: 9, modifiedAt: Date(), deviceName: "other", snapshot: cloudSnapshot))

        await state.restoreFromCloud(candidate: VaultRestoreCandidate(
            header: VaultHeader(schemaVersion: 1, revision: 9, modifiedAt: Date(), deviceName: "other")))

        XCTAssertEqual(state.customRules.count, 1, "云端的实质变化要恢复进来")
        XCTAssertEqual(state.nodes[0].lastLatencyMs, 55, "非排除节点：恢复后自动重测，拿到新鲜延迟")
        XCTAssertEqual(state.nodes[1].lastLatencyMs, 33, "排除节点不参与测速 —— 回填的本机延迟不应被清掉")
        XCTAssertNotNil(state.nodes[1].lastTestedAt)
        XCTAssertEqual(state.currentNodeId, localCurrentId, "本机当前节点选择不应被恢复清掉")
    }

    /// 恢复确认弹窗要带「与本机配置的差异摘要」：启动检查发现云端更新时，
    /// offer 里应算好 diff —— 用户在确认前就知道恢复会加 / 删 / 改什么。
    func testStartupOfferCarriesDiffSummary() async throws {
        let store = makeStore()
        var snapshot = Persistence.Snapshot()
        snapshot.nodes = [try ProxyURLParser.parse("trojan://pw@cloud.example.com:443#cloud-node")]
        snapshot.customRules = [Rule(type: .domainSuffix, value: "example.com", target: .proxy)]
        try await store.save(VaultDocument(revision: 5, modifiedAt: Date(), deviceName: "other", snapshot: snapshot))

        // 本机已有一个不同的节点：恢复会 +1（云端节点）−1（本机节点），规则 +1
        let state = makeState(store: store)
        try state.addNode(fromURL: "trojan://pw@local.example.com:443#local-node")
        await state.runCloudVaultStartupCheck()
        XCTAssertNotNil(state.cloudRestoreOffer)
        XCTAssertEqual(state.cloudRestoreOffer?.diffSummary, "与本机相比：节点 +1 −1 · 规则 +1")
    }

    /// 手动「立即恢复」路径：版本列表里的候选也要带差异摘要（选中后经 pending →
    /// presentPendingCloudRestoreOffer 原样进确认弹窗，与启动路径汇流到同一 alert）。
    func testManualRestoreCandidatesCarryDiffSummary() async throws {
        let store = makeStore()
        let state = makeState(store: store)
        try state.addNode(fromURL: "trojan://pw@a.com:443#n1")
        await state.cloudMirrorTask?.value   // 云端主文档 = 本机内容

        await state.requestManualCloudRestore()
        let options = try XCTUnwrap(state.cloudVersionOptions)
        // 云端主文档与本机一致 → 摘要明说「一致」，用户不会被吓到
        XCTAssertEqual(options.first?.diffSummary, "与本机配置一致")

        // 选中 → sheet 收起 → onDismiss 呈现确认弹窗：摘要原样跟着候选走
        let chosen = try XCTUnwrap(options.first)
        state.chooseCloudRestoreCandidate(chosen)
        state.presentPendingCloudRestoreOffer()
        XCTAssertEqual(state.cloudRestoreOffer?.diffSummary, "与本机配置一致")
    }

    func testStartupWithEmptyLocalAndEmptyCloudDoesNotCreateEmptyVault() async throws {
        // 新装机、云端也没有文档：没什么值得镜像的 —— 不要抢着写一份空 vault
        //（iCloud 元数据可能还没同步完，写空文档有覆盖真数据的风险）
        let store = makeStore()
        let state = makeState(store: store)
        await state.runCloudVaultStartupCheck()
        XCTAssertEqual(state.cloudSyncStatus, .idle)
        let doc = try await store.loadDocument()
        XCTAssertNil(doc, "空本地 + 空云端不应写出空 vault")
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
