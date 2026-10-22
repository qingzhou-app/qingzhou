import Foundation
import Observation
import QingzhouCore
#if canImport(UIKit)
import UIKit
#endif

/// 云同步任务的执行顺序与取消边界。UI 呈现仍由 CloudRestoreCoordinator 管理，
/// 配置应用/VPN/测速仍由 AppState 适配，协调读写及版本 CAS 仍由 CloudVaultStore 执行。
@MainActor
@Observable
final class CloudSyncCoordinator {
    var status: CloudSyncStatus = .unknown
    static let vaultSyncStateName = "vault-sync-state"
    private static let restoreBackupName = "state-backup-before-restore"
    @ObservationIgnored private weak var state: AppState?
    @ObservationIgnored private(set) var mirrorTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var activeTask: Task<Void, Never>?
    @ObservationIgnored private var activeTicket: Ticket?
    @ObservationIgnored private var activeKind: Kind?
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private let retryDelay: Duration

    private enum Kind { case startup, mirror, restore }
    private struct Ticket: Equatable, Sendable { let id: UUID; let epoch: UUID }
    private enum MirrorAuthorization {
        case normal
        case restoredHistory(VaultReplacementContext)
    }

    init(state: AppState, retryDelay: Duration = .seconds(15)) {
        self.state = state
        self.retryDelay = retryDelay
    }

    /// 取消调用方等待时也取消实际工作；取消旧等待者不会误取消更新的任务。
    static func wait(for task: Task<Void, Never>) async {
        await withTaskCancellationHandler {
            await task.value
        } onCancel: { task.cancel() }
    }

    func startupCheck() -> Task<Void, Never> {
        guard let state, state.settings.iCloudSyncEnabled else {
            status = .disabled
            return Task {}
        }
        // 显式恢复优先；启动检查不能把正在恢复的任务顶掉。
        if activeKind == .restore, activeTicket?.epoch == epoch, activeTask?.isCancelled == false {
            return Task {}
        }
        retryTask?.cancel(); retryTask = nil
        return replaceOperation(.startup) { coordinator, ticket in
            await coordinator.performStartup(ticket: ticket)
        }
    }

    func scheduleMirror(after saved: Task<Bool, Never>, snapshot: Persistence.Snapshot) {
        guard let state, state.settings.iCloudSyncEnabled, state.cloudRestoreOffer == nil else { return }
        mirrorTask?.cancel()
        let scheduledEpoch = epoch
        mirrorTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, await saved.value, !Task.isCancelled, let self,
                  self.epoch == scheduledEpoch else { return }
            // 自动镜像只等待，不取消启动检查或显式恢复。新 persist 会替换本防抖任务。
            while let operation = self.activeTask {
                await operation.value
                guard !Task.isCancelled, self.epoch == scheduledEpoch else { return }
            }
            guard let state = self.state, state.settings.iCloudSyncEnabled,
                  state.cloudRestoreOffer == nil else { return }
            // 前驱恢复可能已应用另一份配置；旧 persist 的保存结果不能授权上传新内存内容。
            guard self.contentHash(state.currentSnapshot()) == self.contentHash(snapshot) else { return }
            let task = self.replaceOperation(.mirror) { coordinator, ticket in
                await coordinator.performMirror(snapshot: snapshot, ticket: ticket)
            }
            await Self.wait(for: task)
        }
    }

    func restore(candidate: VaultRestoreCandidate?) -> Task<Void, Never> {
        guard let state, state.settings.iCloudSyncEnabled else { return Task {} }
        state.cloudRestoreOffer = nil
        mirrorTask?.cancel(); mirrorTask = nil
        retryTask?.cancel(); retryTask = nil
        let localHash = contentHash(state.currentSnapshot())
        return replaceOperation(.restore) { coordinator, ticket in
            await coordinator.performRestore(candidate: candidate, localHash: localHash, ticket: ticket)
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard let state, state.settings.iCloudSyncEnabled != enabled else { return }
        state.settings.iCloudSyncEnabled = enabled
        invalidateOperations()
        state.saveCurrentSnapshot() // 只保存本地；开启后先比对云版本，不直接镜像。
        if enabled {
            _ = startupCheck()
        } else {
            state.cancelCloudRestorePresentation()
            status = .disabled
        }
        state.logger.info("iCloud sync \(enabled ? "enabled" : "disabled")", category: "cloud")
    }

    func declineRestore() {
        guard let state, let offer = state.cloudRestoreOffer else { return }
        // 已作出的用户决策也使旧启动检查/镜像提示失效。
        invalidateOperations()
        if offer.backupFileName == nil {
            var sync = state.persistence.load(VaultSyncState.self, name: Self.vaultSyncStateName)
                ?? VaultSyncState(lastSyncedRevision: 0, lastSyncedAt: .distantPast)
            sync.lastDeclinedRevision = offer.header.revision
            try? state.persistence.save(sync, name: Self.vaultSyncStateName)
        }
        state.cloudRestoreOffer = nil
    }

    private func invalidateOperations() {
        epoch = UUID()
        retryTask?.cancel(); retryTask = nil
        mirrorTask?.cancel(); mirrorTask = nil
        activeTask?.cancel()
        // 保留被取消任务作为写入屏障：不能让新恢复越过尚未返回的旧提交。
    }

    private func replaceOperation(_ kind: Kind,
        perform: @escaping @MainActor (CloudSyncCoordinator, Ticket) async -> Void
    ) -> Task<Void, Never> {
        let previous = activeTask
        previous?.cancel()
        let ticket = Ticket(id: UUID(), epoch: epoch)
        activeTicket = ticket; activeKind = kind
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            defer {
                if self.activeTicket == ticket {
                    self.activeTicket = nil; self.activeKind = nil; self.activeTask = nil
                }
            }
            guard self.isCurrent(ticket) else { return }
            await perform(self, ticket)
        }
        activeTask = task
        return task
    }

    private func isCurrent(_ ticket: Ticket) -> Bool {
        activeTicket == ticket && epoch == ticket.epoch && !Task.isCancelled
            && state?.settings.iCloudSyncEnabled == true
    }

    private func contentHash(_ snapshot: Persistence.Snapshot) -> String? {
        try? VaultSnapshotNormalizer.contentHash(of: VaultSnapshotNormalizer.normalized(snapshot))
    }

    private static func syncedStatus(from state: VaultSyncState?) -> CloudSyncStatus? {
        guard let state, state.lastSyncedRevision > 0 else { return nil }
        return .synced(state.lastSyncedAt)
    }

    private static var deviceName: String {
        #if os(macOS)
        Host.current().localizedName ?? "Mac"
        #else
        UIDevice.current.name
        #endif
    }

    private func performRestore(candidate: VaultRestoreCandidate?, localHash: String?, ticket: Ticket) async {
        guard let state, isCurrent(ticket) else { return }
        let document: VaultDocument?
        var authorization: MirrorAuthorization = .normal
        do {
            if let fileName = candidate?.backupFileName {
                if let context = candidate?.replacementContext { authorization = .restoredHistory(context) }
                document = try await state.cloudVault.loadBackupDocument(fileName: fileName)
            } else {
                document = try await state.cloudVault.loadDocument()
            }
            guard isCurrent(ticket) else { return }
        } catch {
            guard isCurrent(ticket) else { return }
            state.showToast(L("读取 iCloud 数据失败：\(error.localizedDescription)"))
            state.logger.error("iCloud vault restore read failed: \(error)", category: "cloud")
            return
        }
        guard let document else {
            state.showToast(L("iCloud 上没有找到备份"))
            return
        }
        guard document.schemaVersion <= VaultDocument.currentSchemaVersion else {
            status = .incompatibleCloud(schemaVersion: document.schemaVersion)
            state.showToast(L("iCloud 数据来自更新版本的轻舟，请先升级 App"))
            return
        }
        // 确认期间云主文档/所选备份被替换，不能静默恢复用户没确认过的内容。
        if let candidate, (try? VaultDocument.decodeHeader(from: document.encoded())) != candidate.header {
            status = .error(CloudVaultStore.StoreError.conflict.localizedDescription)
            state.showToast(L("iCloud 配置已变化，请重新选择恢复版本"))
            return
        }
        guard contentHash(state.currentSnapshot()) == localHash else {
            reportRestoreEdited(state)
            return
        }
        // 备份失败就保留本地原配置；不是尽力写一份后仍继续覆盖。
        do { try state.persistence.save(state.currentSnapshot(), name: Self.restoreBackupName) }
        catch {
            status = .error(error.localizedDescription)
            state.showToast(L("恢复前备份失败，已保留本机配置"))
            state.logger.error("Before-restore backup failed: \(error)", category: "cloud")
            return
        }
        let saved = state.applyCloudSnapshot(document)
        let restoredSnapshot = state.currentSnapshot()
        let restoredHash = contentHash(restoredSnapshot)
        guard await saved.value else {
            if isCurrent(ticket) { status = .error(L("恢复后的配置保存失败")) }
            return
        }
        guard isCurrent(ticket) else { return }
        // 等待落盘期间的本地编辑要由对应 persist 成功后再镜像，不能借旧保存的授权上传。
        guard contentHash(state.currentSnapshot()) == restoredHash else {
            reportRestoreEdited(state)
            return
        }
        if candidate?.backupFileName != nil {
            await performMirror(snapshot: restoredSnapshot, authorization: authorization, ticket: ticket)
        } else {
            let now = Date()
            try? state.persistence.save(VaultSyncState(lastSyncedRevision: document.revision,
                lastSyncedAt: now, lastMirroredContentHash: restoredHash), name: Self.vaultSyncStateName)
            status = .synced(now)
        }
        guard isCurrent(ticket) else { return }
        // 恢复后设备测速/择优仍沿用 AppState；瞬态字段不改变云内容哈希。
        if !state.nodes.isEmpty {
            await state.autoSelectBestNode()
            guard isCurrent(ticket) else { return }
            if let best = state.currentNode { state.showToast(L("已为你选择延迟最优节点：\(best.name)")) }
        }
    }

    private func reportRestoreEdited(_ state: AppState) {
        status = .error(L("恢复期间本机配置已变化，请重新确认恢复"))
        state.showToast(L("恢复期间本机配置已变化，请重新确认恢复"))
    }

    private func performStartup(ticket: Ticket) async {
        guard let state, isCurrent(ticket) else { return }
        guard state.settings.iCloudSyncEnabled else {
            status = .disabled
            return
        }
        let available = await state.cloudVault.isAvailable()
        guard isCurrent(ticket) else { return }
        guard available else {
            status = .unavailable
            return
        }
        let header: VaultHeader?
        do {
            header = try await state.cloudVault.loadHeader()
        } catch let error as CloudVaultStore.StoreError where error == .notYetDownloaded {
            // 云端有文档、本机还没下载完（新装机首启常见）：绝不能当「云端没有」去镜像覆盖。
            // 显示同步中，15 秒后重试。
            guard isCurrent(ticket) else { return }
            status = .syncing
            let retryEpoch = epoch
            retryTask?.cancel()
            retryTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: self?.retryDelay ?? .seconds(15))
                guard !Task.isCancelled, let self, self.epoch == retryEpoch else { return }
                self.retryTask = nil // 当前重试已开始，startupCheck 不能取消它自己的等待者。
                await Self.wait(for: self.startupCheck())
            }
            return
        } catch {
            guard isCurrent(ticket) else { return }
            status = .error("\(error)")
            state.logger.warn("iCloud vault read failed: \(error)", category: "cloud")
            return
        }
        guard isCurrent(ticket) else { return }
        let lastSynced = state.persistence.load(VaultSyncState.self, name: Self.vaultSyncStateName)
        // 旧版云文档头部没有 contentHash → 回退读全文计算一次（下次本机镜像后头部就有了）。
        // 只在「不比对就会弹窗」的情形下才多读这一次全文。
        var cloudContentHash = header?.contentHash
        if cloudContentHash == nil, let header,
           header.schemaVersion <= VaultDocument.currentSchemaVersion,
           header.revision > (lastSynced?.lastSyncedRevision ?? Int.min),
           let document = try? await state.cloudVault.loadDocument() {
            cloudContentHash = try? VaultSnapshotNormalizer.contentHash(
                of: VaultSnapshotNormalizer.normalized(document.snapshot))
        }
        guard isCurrent(ticket) else { return }
        let localContentHash = contentHash(state.currentSnapshot())
        switch VaultSyncLogic.startupAction(
            cloudHeader: header,
            lastSyncedRevision: lastSynced?.lastSyncedRevision,
            lastDeclinedRevision: lastSynced?.lastDeclinedRevision,
            cloudContentHash: cloudContentHash,
            localContentHash: localContentHash
        ) {
        case .mirrorLocal:
            // 防呆：本机是空的且从没同步过（新装机）→ 没什么值得镜像的，也避免在 iCloud
            // 元数据尚未同步完时把「空」推上去盖掉真数据。等用户真加了配置，persist 会镜像。
            let snapshot = state.currentSnapshot()
            let localHasContent = !snapshot.subscriptions.isEmpty || !snapshot.nodes.isEmpty
                || !snapshot.customRules.isEmpty
            if localHasContent || lastSynced != nil {
                let saved = state.saveCurrentSnapshot(snapshot)
                guard await saved.value else {
                    if isCurrent(ticket) { status = .error(L("配置保存失败，未同步到 iCloud")) }
                    return
                }
                guard isCurrent(ticket), contentHash(state.currentSnapshot()) == contentHash(snapshot) else { return }
                await performMirror(snapshot: snapshot, ticket: ticket)
            } else {
                status = .idle
            }
        case .offerRestore(let cloud):
            // 自动检查只更新设置页状态。恢复必须由用户在设置页选择版本发起。
            // 不记录“已拒绝”，不采认不同内容的新revision，避免间接授权自动覆盖。
            status = .manualRestoreAvailable(revision: cloud.revision)
            state.logger.info("iCloud has a newer version; waiting for manual restore in Settings", category: "cloud")
        case .adoptCloudRevision(let cloud):
            // 云端 revision 更高但用户内容与本机一致 → 静默跟进同步记录，不打扰用户
            let now = Date()
            try? state.persistence.save(
                VaultSyncState(lastSyncedRevision: cloud.revision, lastSyncedAt: now, lastMirroredContentHash: localContentHash),
                name: Self.vaultSyncStateName
            )
            status = .synced(now)
            state.logger.info("iCloud vault rev \(cloud.revision) has identical content — adopted silently", category: "cloud")
        case .skipDeclinedRevision(let cloud):
            status = Self.syncedStatus(from: lastSynced) ?? .unknown
            state.logger.info("iCloud vault rev \(cloud.revision) was declined before — not prompting again", category: "cloud")
        case .alreadyInSync:
            status = .synced(lastSynced?.lastSyncedAt ?? Date())
        case .incompatibleCloud(let version):
            status = .incompatibleCloud(schemaVersion: version)
            state.logger.warn("iCloud vault schema v\(version) is newer than supported — not touching it", category: "cloud")
        }
    }

    private func performMirror(snapshot savedSnapshot: Persistence.Snapshot,
        authorization: MirrorAuthorization = .normal, ticket: Ticket) async {
        guard let state, isCurrent(ticket) else { return }
        guard state.settings.iCloudSyncEnabled, state.cloudRestoreOffer == nil else { return }
        let available = await state.cloudVault.isAvailable()
        guard isCurrent(ticket) else { return }
        guard available else {
            status = .unavailable
            return
        }
        // 固定使用对应本地保存成功的快照；任何 IO await 后都不能重抓尚未落盘的新编辑。
        let snapshot = VaultSnapshotNormalizer.normalized(savedSnapshot)
        let contentHash = try? VaultSnapshotNormalizer.contentHash(of: snapshot)
        let lastSynced = state.persistence.load(VaultSyncState.self, name: Self.vaultSyncStateName)

        status = .syncing
        do {
            let header = try await state.cloudVault.loadHeader()
            guard isCurrent(ticket) else { return }
            guard state.cloudRestoreOffer == nil else {
                status = Self.syncedStatus(from: lastSynced) ?? .unknown
                return
            }
            if let header, header.schemaVersion > VaultDocument.currentSchemaVersion {
                // 云端是新版 App 写的：别用旧格式盖掉
                status = .incompatibleCloud(schemaVersion: header.schemaVersion)
                return
            }
            // 运行期间另一台设备写了新内容：保留两边，等待设置页中的显式恢复决策。
            // 用户已拒绝这个revision，才允许下次本地编辑将它覆盖（现有约定）。
            if case .restoredHistory(let confirmed) = authorization, header != confirmed.header {
                throw CloudVaultStore.StoreError.conflict
            }
            if case .normal = authorization, let header, header.revision > (lastSynced?.lastSyncedRevision ?? 0),
               lastSynced?.lastDeclinedRevision != header.revision {
                var remoteHash = header.contentHash
                if remoteHash == nil, let remote = try await state.cloudVault.loadDocument() {
                    remoteHash = try VaultSnapshotNormalizer.contentHash(of: VaultSnapshotNormalizer.normalized(remote.snapshot))
                }
                guard isCurrent(ticket) else { return }
                if remoteHash != contentHash {
                    status = .manualRestoreAvailable(revision: header.revision)
                    return
                }
            }
            // 内容去重：云端就是本机上次写的那个 revision、且规范化内容没变 → 什么都不做
            if let header, let lastSynced, let contentHash,
               header.revision == lastSynced.lastSyncedRevision,
               lastSynced.lastMirroredContentHash == contentHash {
                status = .synced(lastSynced.lastSyncedAt)
                return
            }
            let revision = VaultSyncLogic.nextRevision(
                cloudRevision: header?.revision,
                lastSyncedRevision: lastSynced?.lastSyncedRevision
            )
            let document = VaultDocument(
                revision: revision,
                modifiedAt: Date(),
                deviceName: Self.deviceName,
                snapshot: snapshot,
                contentHash: contentHash
            )
            guard isCurrent(ticket) else { return }
            guard state.cloudRestoreOffer == nil else {
                status = Self.syncedStatus(from: lastSynced) ?? .unknown
                return
            }
            try await state.cloudVault.save(document, expecting: header)
            guard isCurrent(ticket) else { return }
            let now = Date()
            try? state.persistence.save(
                VaultSyncState(lastSyncedRevision: revision, lastSyncedAt: now, lastMirroredContentHash: contentHash),
                name: Self.vaultSyncStateName
            )
            status = .synced(now)
        } catch {
            guard isCurrent(ticket) else { return }
            status = .error("\(error)")
            state.logger.warn("iCloud vault mirror failed: \(error)", category: "cloud")
        }
    }
}
