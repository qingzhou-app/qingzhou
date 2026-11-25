import Foundation
import QingzhouCore

extension AppState {
    // MARK: - iCloud vault（配置的云端镜像，详见 CloudVault.swift 头注释）

    public func runCloudVaultStartupCheck() async {
        await CloudSyncCoordinator.wait(for: cloudSyncCoordinator.startupCheck())
    }

    /// 候选由 alert presenting 参数显式传入，不从已关闭的 offer 再读取。
    public func restoreFromCloud(candidate: VaultRestoreCandidate?) async {
        await CloudSyncCoordinator.wait(for: cloudSyncCoordinator.restore(candidate: candidate))
    }

    public func declineCloudRestore() { cloudSyncCoordinator.declineRestore() }

    func cancelCloudRestorePresentation() { cloudRestoreCoordinator.cancelAll() }

    /// 应用已确认云快照；任务顺序/读取校验由 CloudSyncCoordinator 管理。
    func applyCloudSnapshot(_ document: VaultDocument) -> Task<Bool, Never> {
        var snapshot = document.snapshot
        let localNodes = Dictionary(nodes.map { ($0.identityFingerprint, $0) }, uniquingKeysWith: { first, _ in first })
        for i in snapshot.nodes.indices {
            // 云端含旧版本瞬态值也不信任；只按完整身份接回本机当前网络的观测。
            let local = localNodes[snapshot.nodes[i].identityFingerprint]
            snapshot.nodes[i].lastLatencyMs = local?.lastLatencyMs
            snapshot.nodes[i].lastTestedAt = local?.lastTestedAt
            snapshot.nodes[i].lastProxiedLatencyMs = local?.lastProxiedLatencyMs
            snapshot.nodes[i].lastProxiedTestedAt = local?.lastProxiedTestedAt
            snapshot.nodes[i].observedPeakDownBps = local?.observedPeakDownBps
            snapshot.nodes[i].observedBandwidthAt = local?.observedBandwidthAt
        }
        let localSubTransients = Dictionary(
            subscriptions.map { ($0.url, (updatedAt: $0.lastUpdatedAt, used: $0.usedBytes)) },
            uniquingKeysWith: { first, _ in first }
        )
        for i in snapshot.subscriptions.indices {
            if snapshot.subscriptions[i].lastUpdatedAt == nil,
               let local = localSubTransients[snapshot.subscriptions[i].url] {
                snapshot.subscriptions[i].lastUpdatedAt = local.updatedAt
                snapshot.subscriptions[i].usedBytes = local.used
            }
        }
        // 当前节点：新 vault 不带 currentNodeId（设备本地选择）→ 尽量沿用本机的；
        // 旧文档带了就尊重它。恢复后指向的节点不存在则清空。
        let preservedCurrentId = currentNodeId

        subscriptions = snapshot.subscriptions
        nodes = snapshot.nodes
        customRules = snapshot.customRules
        settings = snapshot.settings
        currentNodeId = snapshot.currentNodeId ?? preservedCurrentId
        if let id = currentNodeId, !nodes.contains(where: { $0.id == id }) {
            currentNodeId = nil
        }
        applySettingsSideEffects()
        let saved = saveCurrentSnapshot()
        // 恢复替换了节点 / 模式 / 规则 —— VPN 在跑就热切换到恢复后的配置（没跑时内部 guard 直接返回）
        Task { await reapplyRunningTunnel() }
        logger.info("Restored from iCloud vault rev \(document.revision) (\(document.deviceName))", category: "cloud")
        if snapshot.nodes.isEmpty {
            showToast(L("已从 iCloud 恢复（\(snapshot.subscriptions.count) 个订阅、0 个节点）"))
        } else {
            showToast(L("已恢复（\(snapshot.subscriptions.count) 个订阅、\(snapshot.nodes.count) 个节点），正在测速择优…"))
        }

        if !settings.iCloudSyncEnabled { cloudSyncStatus = .disabled }
        return saved
    }

    /// 设置页「立即恢复 iCloud 数据」：列出云端当前版 + 最近几份历史版本（含来源设备 /
    /// 时间 / 内容计数），让用户挑 —— 即使主文档被某台设备的空数据覆盖，旧版本仍可找回。
    ///
    /// sheet **立即**呈现（.loading），iCloud 读取异步填充 —— 之前在呈现前同步 await
    /// 读取，真机上按钮点了却要等一两秒 sheet 才出现（复验 #18 反馈）。
    public func requestManualCloudRestore() async {
        cloudRestoreCoordinator.presentVersions()    // 先呈现 sheet，别让用户干等
        await loadCloudVersionOptions()
    }

    /// 读取云端版本列表填充 sheet；sheet 内「重试」也走这里。
    /// 结果只对仍在屏的同一读取轮次落地：关闭重开或重试后，旧结果不能覆盖新列表。
    /// ⚠️ 这里只写 `cloudVersionLoad`（内容态），绝不碰 `isCloudVersionSheetPresented`
    /// （呈现开关）—— 加载完成落在呈现动画中，动开关会把呈现中的 sheet 顶掉。
    public func loadCloudVersionOptions() async {
        guard let requestID = cloudRestoreCoordinator.beginVersionLoad() else { return }
        let result = await fetchCloudVersionOptions()
        cloudRestoreCoordinator.finishVersionLoad(result, requestID: requestID)
    }

    /// 纯读取：把云端主文档 + 历史备份拼成候选列表，不碰 UI 状态。
    private func fetchCloudVersionOptions() async -> CloudVersionLoadState {
        guard await cloudVault.isAvailable() else {
            return .failed(L("iCloud 不可用（未登录或未开启 iCloud Drive）"))
        }
        let mainHeader: VaultHeader?
        do {
            mainHeader = try await cloudVault.loadHeader()
        } catch let error as CloudVaultStore.StoreError where error == .notYetDownloaded {
            return .failed(L("iCloud 数据还在下载中，稍等片刻再试"))
        } catch {
            return .failed(L("读取 iCloud 数据失败：\(error.localizedDescription)"))
        }
        var options: [VaultRestoreCandidate] = []
        if let mainHeader, mainHeader.schemaVersion <= VaultDocument.currentSchemaVersion {
            options.append(VaultRestoreCandidate(header: mainHeader))
        }
        for backup in await cloudVault.listBackups()
        where backup.header.schemaVersion <= VaultDocument.currentSchemaVersion
            && backup.header.revision != mainHeader?.revision {
            options.append(VaultRestoreCandidate(
                header: backup.header, backupFileName: backup.fileName,
                replacementContext: mainHeader.map(VaultReplacementContext.existing) ?? .absent))
        }
        guard !options.isEmpty else {
            // 也走 .failed 留在 sheet 内展示（带重试）—— iCloud 元数据可能还没同步完，
            // 稍后重试常常就有了；比 toast 一闪而过可操作性强。
            return .failed(mainHeader != nil
                ? L("iCloud 数据来自更新版本的轻舟，请先升级 App")
                : L("iCloud 上没有找到备份"))
        }
        // 差异摘要在这里（sheet 的异步加载）就算好：候选经 pending → onDismiss 原样进
        // 确认弹窗，与启动路径汇流到同一 alert；alert 呈现后 message 定格，事后补不进去。
        // 最多主文档 + maxBackups 份全文读取，都是本地已下载的小 JSON，可接受。
        for i in options.indices {
            options[i].diffSummary = await cloudRestoreDiffSummary(for: options[i])
        }
        // 只有一份也在列表里展示（点一下即进确认弹窗）——sheet 已经在屏了，
        // 自动收起再弹 alert 反而突兀。
        return .loaded(options)
    }

    /// 读取候选对应的云端全文，算「与本机配置的差异」一行摘要（确认弹窗展示）。
    /// 读不到 / schema 过新 → nil，弹窗降级为只显示云端计数 —— 摘要是锦上添花，不挡恢复。
    func cloudRestoreDiffSummary(for candidate: VaultRestoreCandidate) async -> String? {
        let document: VaultDocument?
        if let fileName = candidate.backupFileName {
            document = try? await cloudVault.loadBackupDocument(fileName: fileName)
        } else {
            document = try? await cloudVault.loadDocument()
        }
        guard let document, document.schemaVersion <= VaultDocument.currentSchemaVersion else {
            return nil
        }
        return VaultDiff.between(local: currentSnapshot(), cloud: document.snapshot).summaryText
    }

    /// 用户在版本列表里选了一份 → 先收起 sheet，候选暂存；等 sheet 的 onDismiss
    /// （收起动画完成、呈现层空闲）再经 `presentPendingCloudRestoreOffer()` 进确认弹窗。
    ///
    /// ⚠️ 不能在这里直接置 `cloudRestoreOffer`：确认 alert 挂在 RootView，sheet 还在收起
    /// 时呈现 alert 会撞呈现层 —— iOS 上 alert 被系统吞掉 / 自动消失，且系统 dismiss 会经
    /// isPresented binding 的 set(false) 调 declineCloudRestore() 把候选也清掉，用户得再
    /// 走一遍流程（真机踩过：确认弹窗第一次自动消失，第二次才正常）。
    public func chooseCloudRestoreCandidate(_ candidate: VaultRestoreCandidate) {
        cloudRestoreCoordinator.choose(candidate)
    }

    /// 版本选择 sheet 的 onDismiss 回调：呈现层已空闲，暂存的候选此刻才进确认弹窗。
    /// 取消关闭（没点选任何版本）时没有暂存候选，这里自然是 no-op。
    public func presentPendingCloudRestoreOffer() {
        cloudRestoreCoordinator.presentPendingOffer()
    }

    /// 关闭版本选择列表（含加载中 / 失败态）。在途的读取结果会被 loadCloudVersionOptions
    /// 的轮次校验丢弃，不会把 sheet 复活或覆盖随后重开的列表。
    public func dismissCloudVersionOptions() {
        cloudRestoreCoordinator.dismissVersions()
    }

    public func setCloudSyncEnabled(_ enabled: Bool) { cloudSyncCoordinator.setEnabled(enabled) }
}
