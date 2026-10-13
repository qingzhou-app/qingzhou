import Foundation
import Observation

/// 云恢复的呈现与候选交接状态。无 IO；各字段分别触发 Observation。
/// 云文档读写、覆盖授权检查及恢复后的配置副作用仍在现有服务/编排中。
/// 必须逐字段观察：加载变化不能使只观察 sheet Bool 的呈现层失效。
@MainActor
@Observable
final class CloudRestoreCoordinator {
    var offer: VaultRestoreCandidate?
    private(set) var isVersionSheetPresented = false
    private(set) var versionLoad: CloudVersionLoadState?
    private(set) var pendingCandidate: VaultRestoreCandidate?
    @ObservationIgnored private var versionLoadID: UUID?

    var versionOptions: [VaultRestoreCandidate]? {
        if case .loaded(let options) = versionLoad { return options }
        return nil
    }

    func presentVersions() {
        pendingCandidate = nil
        versionLoadID = nil
        isVersionSheetPresented = true
        versionLoad = .loading
    }

    func beginVersionLoad() -> UUID? {
        guard isVersionSheetPresented else { return nil }
        let requestID = UUID()
        versionLoadID = requestID
        versionLoad = .loading
        return requestID
    }

    func finishVersionLoad(_ result: CloudVersionLoadState, requestID: UUID) {
        // Bool 不能区分关闭后重开，也不能区分同一列表里的两次重试。
        guard isVersionSheetPresented, versionLoadID == requestID else { return }
        versionLoadID = nil
        versionLoad = result
    }

    func choose(_ candidate: VaultRestoreCandidate) {
        pendingCandidate = candidate
        dismissVersions()
    }

    func presentPendingOffer() {
        guard !isVersionSheetPresented, let candidate = pendingCandidate else { return }
        pendingCandidate = nil
        offer = candidate
    }

    func dismissVersions() {
        isVersionSheetPresented = false
        versionLoad = nil
        versionLoadID = nil
        // 点选后 SwiftUI binding 也可能调用关闭；保留 pending 直到 onDismiss 接棒。
    }
}
