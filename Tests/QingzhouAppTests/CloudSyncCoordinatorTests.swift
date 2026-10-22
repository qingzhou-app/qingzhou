import XCTest
import Observation
import QingzhouCore
@testable import QingzhouApp

/// Tests release each IO explicitly; no sleeps or real iCloud/network access.
actor CloudIOGate {
    private var release: CheckedContinuation<Void, Never>?
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var entered = false
    func suspend() async {
        entered = true
        arrivals.forEach { $0.resume() }
        arrivals.removeAll()
        await withCheckedContinuation { release = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { arrivals.append($0) }
    }
    func resume() { release?.resume(); release = nil }
}

actor ControlledCloudVault: CloudVaultAccess {
    var document: VaultDocument?
    var backup: VaultDocument?
    var nextHeaderGate: CloudIOGate?
    var nextDocumentGate: CloudIOGate?
    var nextSaveGate: CloudIOGate?
    var nextAvailableGate: CloudIOGate?
    var ignoreSaveCancellation = false
    var onBackupRead: (@Sendable () -> Void)?
    var onHeaderRead: (@Sendable (Int) -> Void)?
    var nextHeaderError: CloudVaultStore.StoreError?
    private var headerReads = 0
    private(set) var saves = 0
    init(document: VaultDocument? = nil, backup: VaultDocument? = nil) {
        self.document = document; self.backup = backup
    }
    func setDocument(_ value: VaultDocument?) { document = value }
    func pauseHeader(_ gate: CloudIOGate) { nextHeaderGate = gate }
    func pauseDocument(_ gate: CloudIOGate) { nextDocumentGate = gate }
    func pauseSave(_ gate: CloudIOGate, ignoreCancellation: Bool = false) {
        nextSaveGate = gate; ignoreSaveCancellation = ignoreCancellation
    }
    func observeBackupRead(_ callback: (@Sendable () -> Void)?) { onBackupRead = callback }
    func observeHeaderRead(_ callback: @escaping @Sendable (Int) -> Void) { onHeaderRead = callback }
    func failNextHeader(_ error: CloudVaultStore.StoreError) { nextHeaderError = error }
    func pauseAvailable(_ gate: CloudIOGate) { nextAvailableGate = gate }
    func isAvailable() async -> Bool {
        let gate = nextAvailableGate; nextAvailableGate = nil
        if let gate { await gate.suspend() }
        return true
    }
    func loadHeader() async throws -> VaultHeader? {
        headerReads += 1
        onHeaderRead?(headerReads)
        let error = nextHeaderError; nextHeaderError = nil
        let captured = try header()
        let gate = nextHeaderGate; nextHeaderGate = nil
        if let gate { await gate.suspend() }
        if let error { throw error }
        return captured
    }
    func loadDocument() async throws -> VaultDocument? {
        let captured = document
        let gate = nextDocumentGate; nextDocumentGate = nil
        if let gate { await gate.suspend() }
        return captured
    }
    func loadBackupDocument(fileName: String) async throws -> VaultDocument? {
        onBackupRead?()
        let captured = backup
        let gate = nextDocumentGate; nextDocumentGate = nil
        if let gate { await gate.suspend() }
        return captured
    }
    func listBackups() -> [CloudVaultStore.BackupEntry] { [] }
    func save(_ value: VaultDocument, expecting expected: VaultHeader?) async throws {
        saves += 1
        let gate = nextSaveGate; nextSaveGate = nil
        if let gate { await gate.suspend() }
        if !ignoreSaveCancellation { try Task.checkCancellation() }
        guard try header() == expected else { throw CloudVaultStore.StoreError.conflict }
        document = value
    }
    func header() throws -> VaultHeader? {
        try document.map { try VaultDocument.decodeHeader(from: $0.encoded()) }
    }
}

@MainActor
final class CloudSyncCoordinatorTests: XCTestCase {
    private var directory: URL!
    override func setUp() async throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cloud-jobs-\(UUID())")
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }
    private func snapshot(_ domain: String) -> Persistence.Snapshot {
        var s = Persistence.Snapshot()
        s.customRules = [Rule(type: .domain, value: domain, target: .proxy)]
        return s
    }
    private func document(_ revision: Int, _ domain: String) throws -> VaultDocument {
        let s = snapshot(domain)
        return VaultDocument(revision: revision, modifiedAt: Date(timeIntervalSince1970: 100),
            deviceName: "test", snapshot: s, contentHash: try VaultSnapshotNormalizer.contentHash(of: s))
    }
    private func state(_ store: ControlledCloudVault) -> AppState {
        AppState(persistence: Persistence(directory: directory), cloudVault: store)
    }

    func testStartupAndNewRevisionsStaySilentWithoutOverwritingEitherSide() async throws {
        let store = ControlledCloudVault(document: try document(5, "remote.example"))
        for revision in [5, 6] {
            await store.setDocument(try document(revision, "remote-\(revision).example"))
            let app = state(store)
            app.customRules = snapshot("local.example").customRules
            await app.runCloudVaultStartupCheck()
            XCTAssertNil(app.cloudRestoreOffer, "启动或其他设备新版本都不应弹恢复")
            XCTAssertEqual(app.customRules.first?.value, "local.example")
            app.persist()
            await app.cloudMirrorTask?.value
            XCTAssertNil(app.cloudRestoreOffer, "后台镜像冲突也不能弹恢复")
            let cloud = await store.document
            XCTAssertEqual(cloud?.revision, revision)
            XCTAssertEqual(cloud?.snapshot.customRules.first?.value, "remote-\(revision).example")
            app.persistence.waitForPendingWritesForTesting()
        }
        let saves = await store.saves
        XCTAssertEqual(saves, 0, "静默不等于批准覆盖云端")
    }

    func testDisablingSyncRejectsLateStartupOfferAndStatus() async throws {
        let store = ControlledCloudVault(document: try document(5, "cloud.example"))
        let app = state(store)
        let gate = CloudIOGate()
        await store.pauseHeader(gate)
        let startup = Task { await app.runCloudVaultStartupCheck() }
        await gate.waitUntilEntered()
        app.setCloudSyncEnabled(false)
        await gate.resume()
        await startup.value
        XCTAssertEqual(app.cloudSyncStatus, .disabled)
        XCTAssertNil(app.cloudRestoreOffer)
        app.persistence.waitForPendingWritesForTesting()
    }

    func testCancelledStartupCallerCannotPublishOffer() async throws {
        let store = ControlledCloudVault(document: try document(5, "cloud.example"))
        let app = state(store)
        let gate = CloudIOGate()
        await store.pauseHeader(gate)
        let startup = Task { await app.runCloudVaultStartupCheck() }
        await gate.waitUntilEntered()
        startup.cancel()
        await gate.resume()
        await startup.value
        XCTAssertNil(app.cloudRestoreOffer)
    }

    func testHistoryRestoreDoesNotMirrorWhenLocalSaveFails() async throws {
        let store = ControlledCloudVault(document: try document(5, "current.example"),
            backup: try document(2, "restored.example"))
        let app = state(store)
        let loadedHeader = try await store.header()
        let header = try XCTUnwrap(loadedHeader)
        let backupDocument = await store.backup
        let candidate = VaultRestoreCandidate(header: try VaultDocument.decodeHeader(from: XCTUnwrap(backupDocument).encoded()),
            backupFileName: "history.json", replacementContext: .existing(header))
        // Make only the main snapshot destination unwritable; the before-restore backup is still possible.
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("state.json"), withIntermediateDirectories: true)
        await app.restoreFromCloud(candidate: candidate)
        app.persistence.waitForPendingWritesForTesting()
        XCTAssertEqual(app.customRules.map(\.value), ["restored.example"], "实际走到恢复应用及本地保存失败，而不是候选失效路径")
        let saves = await store.saves
        XCTAssertEqual(saves, 0, "恢复本地落盘失败不能先回推云端")
        let revision = await store.document?.revision
        XCTAssertEqual(revision, 5)
    }

    func testHistoryBackpushUsesSavedSnapshotWhenLaterEditFailsToSave() async throws {
        let backup = try document(2, "restored.example")
        let store = ControlledCloudVault(document: try document(5, "current.example"), backup: backup)
        let app = state(store)
        let loadedHeader = try await store.header()
        let candidate = VaultRestoreCandidate(header: try VaultDocument.decodeHeader(from: backup.encoded()),
            backupFileName: "history.json", replacementContext: .existing(try XCTUnwrap(loadedHeader)))
        let gate = CloudIOGate()
        await store.pauseAvailable(gate)
        let restore = app.cloudSyncCoordinator.restore(candidate: candidate)
        await gate.waitUntilEntered() // 恢复已成功落盘，回推暂停在可用性检查。
        let path = directory.appendingPathComponent("state.json")
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        app.customRules = snapshot("unsaved-edit.example").customRules
        app.persist()
        await gate.resume()
        await restore.value
        await app.cloudMirrorTask?.value
        let cloud = await store.document
        XCTAssertEqual(cloud?.snapshot.customRules.map(\.value), ["restored.example"],
            "历史恢复授权只能上传这次已保存的快照，不能借给未保存的新编辑")
        XCTAssertEqual(app.customRules.map(\.value), ["unsaved-edit.example"])
        app.persistence.waitForPendingWritesForTesting()
    }

    func testStartupDoesNotMirrorWhenLocalSaveFails() async throws {
        let store = ControlledCloudVault()
        let app = state(store)
        app.customRules = snapshot("local.example").customRules
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("state.json"), withIntermediateDirectories: true)
        await app.runCloudVaultStartupCheck()
        let saves = await store.saves
        XCTAssertEqual(saves, 0, "启动镜像也必须先确认本地配置落盘成功")
        app.persistence.waitForPendingWritesForTesting()
    }

    func testNewStartupSupersedesOldRead() async throws {
        let store = ControlledCloudVault(document: try document(1, "old.example"))
        let app = state(store)
        let gate = CloudIOGate()
        await store.pauseHeader(gate)
        let old = app.cloudSyncCoordinator.startupCheck()
        await gate.waitUntilEntered()
        await store.setDocument(try document(2, "new.example"))
        let new = app.cloudSyncCoordinator.startupCheck() // 提交本身同步完成，避免调度时序假设。
        await gate.resume()
        await old.value
        await new.value
        XCTAssertNil(app.cloudRestoreOffer)
        XCTAssertEqual(app.cloudSyncStatus, .manualRestoreAvailable(revision: 2))
    }

    func testDisableThenReenableRejectsOldEpoch() async throws {
        let store = ControlledCloudVault(document: try document(1, "old.example"))
        let app = state(store)
        let gate = CloudIOGate()
        await store.pauseHeader(gate)
        let old = app.cloudSyncCoordinator.startupCheck()
        await gate.waitUntilEntered()
        app.setCloudSyncEnabled(false)
        await store.setDocument(try document(2, "new.example"))
        app.setCloudSyncEnabled(true)
        let new = app.cloudSyncCoordinator.startupCheck()
        await gate.resume()
        await old.value
        await new.value
        XCTAssertNil(app.cloudRestoreOffer)
        XCTAssertEqual(app.cloudSyncStatus, .manualRestoreAvailable(revision: 2))
        app.persistence.waitForPendingWritesForTesting()
    }

    func testDisablingSyncDuringRestoreReadKeepsLocalConfiguration() async throws {
        let store = ControlledCloudVault(document: try document(5, "cloud.example"))
        let app = state(store)
        app.customRules = snapshot("local.example").customRules
        let gate = CloudIOGate()
        await store.pauseDocument(gate)
        let restore = app.cloudSyncCoordinator.restore(candidate: nil)
        await gate.waitUntilEntered()
        app.setCloudSyncEnabled(false)
        await gate.resume()
        await restore.value
        XCTAssertEqual(app.customRules.map(\.value), ["local.example"])
        XCTAssertEqual(app.cloudSyncStatus, .disabled)
        app.persistence.waitForPendingWritesForTesting()
    }

    func testEditingWhileRestoreReadsDoesNotLoseNewLocalChange() async throws {
        let store = ControlledCloudVault(document: try document(5, "cloud.example"))
        let app = state(store)
        let gate = CloudIOGate()
        await store.pauseDocument(gate)
        let restore = app.cloudSyncCoordinator.restore(candidate: nil)
        await gate.waitUntilEntered()
        app.customRules = snapshot("new-local.example").customRules
        app.persist()
        await gate.resume()
        await restore.value
        XCTAssertEqual(app.customRules.map(\.value), ["new-local.example"])
        if case .error = app.cloudSyncStatus {} else { XCTFail("本地编辑应要求重新确认恢复") }
        app.cloudMirrorTask?.cancel()
        await app.cloudMirrorTask?.value
        app.persistence.waitForPendingWritesForTesting()
    }

    func testChangedMainDocumentIsNotRestoredUnderOldConfirmation() async throws {
        let store = ControlledCloudVault(document: try document(1, "confirmed.example"))
        let app = state(store)
        let header = try await store.header()
        let candidate = VaultRestoreCandidate(header: try XCTUnwrap(header))
        await store.setDocument(try document(2, "unconfirmed.example"))
        await app.restoreFromCloud(candidate: candidate)
        XCTAssertTrue(app.customRules.isEmpty)
        XCTAssertNil(app.persistence.load(VaultSyncState.self, name: "vault-sync-state"))
    }

    func testBackupFailureKeepsLocalConfiguration() async throws {
        let store = ControlledCloudVault(document: try document(5, "cloud.example"))
        let app = state(store)
        app.customRules = snapshot("local.example").customRules
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("state-backup-before-restore.json"),
            withIntermediateDirectories: true)
        await app.restoreFromCloud(candidate: nil)
        XCTAssertEqual(app.customRules.map(\.value), ["local.example"])
        if case .error = app.cloudSyncStatus {} else { XCTFail("备份失败应中止恢复") }
    }

    func testAlreadyCommittingWriteCannotPublishSyncedAfterDisable() async throws {
        let store = ControlledCloudVault()
        let app = state(store)
        app.customRules = snapshot("local.example").customRules
        let gate = CloudIOGate()
        await store.pauseSave(gate, ignoreCancellation: true) // 模拟已进入原子提交的不可撤销写。
        app.persist()
        let mirror = app.cloudMirrorTask
        await gate.waitUntilEntered()
        app.setCloudSyncEnabled(false)
        await gate.resume()
        await mirror?.value
        let revision = await store.document?.revision
        XCTAssertEqual(revision, 1, "已开始的提交允许返回成功，不能声称取消回滚了系统写入")
        XCTAssertEqual(app.cloudSyncStatus, .disabled)
        XCTAssertNil(app.persistence.load(VaultSyncState.self, name: "vault-sync-state"))
        app.persistence.waitForPendingWritesForTesting()
    }

    func testRestoreWaitsForOldCommittingWriterBeforeReadingBackup() async throws {
        let store = ControlledCloudVault(backup: try document(2, "restored.example"))
        let app = state(store)
        app.customRules = snapshot("old-local.example").customRules
        let gate = CloudIOGate()
        await store.pauseSave(gate, ignoreCancellation: true)
        app.persist()
        let mirror = app.cloudMirrorTask
        await gate.waitUntilEntered()
        let read = XCTestExpectation(description: "backup read cannot overtake old write")
        read.isInverted = true
        await store.observeBackupRead { read.fulfill() }
        let backup = await store.backup
        let candidate = VaultRestoreCandidate(header: try VaultDocument.decodeHeader(from: XCTUnwrap(backup).encoded()),
            backupFileName: "history.json", replacementContext: .absent)
        let restore = app.cloudSyncCoordinator.restore(candidate: candidate)
        await fulfillment(of: [read], timeout: 0.02)
        await store.observeBackupRead(nil)
        await gate.resume()
        await mirror?.value
        await restore.value
        XCTAssertEqual(app.customRules.map(\.value), ["restored.example"])
        let cloud = await store.document
        XCTAssertEqual(cloud?.snapshot.customRules.map(\.value), ["old-local.example"],
            "不可撤销的旧写入改变了确认上下文，历史恢复不能扩大云覆盖授权")
        if case .error = app.cloudSyncStatus {} else { XCTFail("云覆盖上下文变化应报告冲突") }
        app.persistence.waitForPendingWritesForTesting()
    }

    func testNewRestoreSupersedesOlderRead() async throws {
        let store = ControlledCloudVault(document: try document(1, "old.example"))
        let app = state(store)
        let gate = CloudIOGate()
        await store.pauseDocument(gate)
        let old = app.cloudSyncCoordinator.restore(candidate: nil)
        await gate.waitUntilEntered()
        await store.setDocument(try document(2, "new.example"))
        let new = app.cloudSyncCoordinator.restore(candidate: nil)
        await gate.resume()
        await old.value
        await new.value
        XCTAssertEqual(app.customRules.map(\.value), ["new.example"])
        XCTAssertEqual(app.persistence.load(VaultSyncState.self, name: "vault-sync-state")?.lastSyncedRevision, 2)
        app.persistence.waitForPendingWritesForTesting()
    }

    func testLateAlertDismissWithNoOfferDoesNotCancelConfirmedRestore() async throws {
        let store = ControlledCloudVault(document: try document(5, "cloud.example"))
        let app = state(store)
        let gate = CloudIOGate()
        await store.pauseDocument(gate)
        let restore = app.cloudSyncCoordinator.restore(candidate: nil)
        await gate.waitUntilEntered()
        app.declineCloudRestore() // starter 已清 offer，迟到的 SwiftUI dismiss 应是 no-op。
        await gate.resume()
        await restore.value
        XCTAssertEqual(app.customRules.map(\.value), ["cloud.example"])
        app.persistence.waitForPendingWritesForTesting()
    }

    func testBackgroundStartupAndMirrorCannotInterruptRestore() async throws {
        let store = ControlledCloudVault(document: try document(5, "cloud.example"))
        let app = state(store)
        let gate = CloudIOGate()
        await store.pauseDocument(gate)
        let restore = app.cloudSyncCoordinator.restore(candidate: nil)
        await gate.waitUntilEntered()
        let startup = app.cloudSyncCoordinator.startupCheck()
        await startup.value
        app.persist() // 内容不变，仅请求后台保存/镜像；不扩大显式恢复权限。
        let mirror = app.cloudMirrorTask
        await gate.resume()
        await restore.value
        await mirror?.value
        XCTAssertEqual(app.customRules.map(\.value), ["cloud.example"])
        let saves = await store.saves
        XCTAssertEqual(saves, 0, "恢复当前主文档后镜像应去重，不产生新revision")
        app.persistence.waitForPendingWritesForTesting()
    }

    func testSyncStatusStillNotifiesViews() {
        let app = state(ControlledCloudVault())
        let changed = XCTestExpectation(description: "view observes disabled sync")
        withObservationTracking { _ = app.cloudSyncStatus } onChange: { changed.fulfill() }
        app.setCloudSyncEnabled(false)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 0.1), .completed)
        XCTAssertEqual(app.cloudSyncStatus, .disabled)
        app.persistence.waitForPendingWritesForTesting()
    }

    func testDownloadRetryDoesNotCancelItsOwnStartup() async throws {
        let store = ControlledCloudVault(document: try document(5, "cloud.example"))
        let app = state(store)
        let coordinator = CloudSyncCoordinator(state: app, retryDelay: .zero)
        let retried = XCTestExpectation(description: "placeholder download retries the header read")
        await store.failNextHeader(.notYetDownloaded)
        await store.observeHeaderRead { count in if count == 2 { retried.fulfill() } }
        await coordinator.startupCheck().value
        await fulfillment(of: [retried], timeout: 1)
    }

    func testManualRestoreOfferStopsMirrorThatWasAlreadyReading() async throws {
        let backup = try document(2, "backup.example")
        let store = ControlledCloudVault(backup: backup)
        let app = state(store)
        app.customRules = snapshot("local.example").customRules
        let gate = CloudIOGate()
        await store.pauseHeader(gate)
        app.persist()
        let mirror = app.cloudMirrorTask
        await gate.waitUntilEntered()
        let chosen = VaultRestoreCandidate(header: try VaultDocument.decodeHeader(from: backup.encoded()),
            backupFileName: "history.json", replacementContext: .absent)
        app.chooseCloudRestoreCandidate(chosen)
        app.presentPendingCloudRestoreOffer()
        await gate.resume()
        await mirror?.value
        let saves = await store.saves
        XCTAssertEqual(saves, 0, "确认提示出现后，在途镜像也不能写云")
        XCTAssertEqual(app.cloudRestoreOffer, chosen)
        app.persistence.waitForPendingWritesForTesting()
    }

    func testAutomaticHeaderReadCannotReplaceManuallyChosenOffer() async throws {
        for mirroring in [false, true] {
            let store = ControlledCloudVault(document: try document(5, "cloud.example"))
            let app = state(store)
            app.customRules = snapshot("local.example").customRules
            let gate = CloudIOGate()
            await store.pauseHeader(gate)
            let operation: Task<Void, Never>
            if mirroring {
                app.persist()
                operation = try XCTUnwrap(app.cloudMirrorTask)
            } else { operation = app.cloudSyncCoordinator.startupCheck() }
            await gate.waitUntilEntered()
            let chosen = VaultRestoreCandidate(header: try VaultDocument.decodeHeader(from: document(2, "chosen.example").encoded()),
                backupFileName: "history.json")
            app.chooseCloudRestoreCandidate(chosen)
            app.presentPendingCloudRestoreOffer()
            await gate.resume()
            await operation.value
            XCTAssertEqual(app.cloudRestoreOffer, chosen, "自动路径不能在diff读取之后替换手动候选，mirror=\(mirroring)")
            app.persistence.waitForPendingWritesForTesting()
        }
    }
}
