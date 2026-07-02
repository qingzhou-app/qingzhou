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
        //    严格按真机 UI 时序：alert 呈现时捕获 presenting 值 → dismiss 先清 offer →
        //    恢复 Task 才执行（拿捕获值，不能再读 offer）
        state.chooseCloudRestoreCandidate(goodBackup)
        XCTAssertNil(state.cloudVersionOptions)
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

        // 用户点选 → alert 呈现（presenting 捕获）→ 点「恢复」→ dismiss 先清 offer → Task 执行
        state.chooseCloudRestoreCandidate(good)
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
    func testRestorePreservesLocalTransientData() async throws {
        let store = makeStore()
        let state = makeState(store: store)
        try state.addNode(fromURL: "trojan://pw@a.com:443#n1")
        state.select(state.nodes[0])
        await state.cloudMirrorTask?.value

        // 本机测速结果 + 当前选择
        state.nodes[0].lastLatencyMs = 33
        state.nodes[0].lastTestedAt = Date()
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
        XCTAssertEqual(state.nodes.first?.lastLatencyMs, 33, "本机延迟数据不应被恢复清掉")
        XCTAssertNotNil(state.nodes.first?.lastTestedAt)
        XCTAssertEqual(state.currentNodeId, localCurrentId, "本机当前节点选择不应被恢复清掉")
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
