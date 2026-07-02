#if os(macOS)
import NetworkExtension
import SystemExtensions

/// 启用 / 停用 macOS 内容过滤（来源 App 标注）。System Extension 形态，两步：
///   ① OSSystemExtensionRequest 激活扩展 —— 首次用户要在「系统设置 → 通用 → 登录项与扩展」批准
///   ② NEFilterManager 配置并启用 —— 弹「允许过滤网络内容」授权
/// 需要 content-filter-provider（扩展）+ system-extension.install（主 App）两个 entitlement + 用户两段批准。
@MainActor
public final class ContentFilterManager: NSObject {
    public static let shared = ContentFilterManager()
    private let extensionID = "com.sbraveyoung.qingzhou.mac.filter"
    private var activation: CheckedContinuation<Void, Error>?
    /// 必须持有 request —— 否则 submitRequest 之后 ARC 释放它，激活请求会被取消
    /// （sysextd 日志里的 "client cancelled the connection" 就是这个）。
    private var pendingRequest: OSSystemExtensionRequest?
    /// 系统提示"需要用户去系统设置批准扩展"时回调，UI 用来引导。
    public var onNeedsApproval: (() -> Void)?

    public func activateAndEnable() async throws {
        try await activateExtension()
        try await enableFilter()
    }

    public static var isEnabled: Bool { NEFilterManager.shared().isEnabled }

    /// 先 loadFromPreferences 再读 isEnabled —— 进程启动后没 load 过时
    /// shared() 的 isEnabled 恒 false，直接读会误判「未启用」。
    public static func loadIsEnabled() async -> Bool {
        let m = NEFilterManager.shared()
        try? await m.loadFromPreferences()
        return m.isEnabled
    }

    private func activateExtension() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            activation = cont
            let req = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: extensionID, queue: .main)
            req.delegate = self
            pendingRequest = req
            OSSystemExtensionManager.shared.submitRequest(req)
        }
    }

    private func enableFilter() async throws {
        let m = NEFilterManager.shared()
        try await m.loadFromPreferences()
        if m.providerConfiguration == nil {
            let c = NEFilterProviderConfiguration()
            c.filterSockets = true
            c.filterPackets = false
            m.providerConfiguration = c
        }
        m.localizedDescription = "轻舟 · 来源 App 标注"
        m.isEnabled = true
        try await m.saveToPreferences()
    }

    public func disable() async throws {
        let m = NEFilterManager.shared()
        try await m.loadFromPreferences()
        guard m.providerConfiguration != nil else { return }
        m.isEnabled = false
        try await m.saveToPreferences()
    }
}

extension ContentFilterManager: OSSystemExtensionRequestDelegate {
    public nonisolated func request(_ request: OSSystemExtensionRequest,
                                    didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor in self.activation?.resume(); self.activation = nil; self.pendingRequest = nil }
    }
    public nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in self.activation?.resume(throwing: error); self.activation = nil; self.pendingRequest = nil }
    }
    public nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in self.onNeedsApproval?() }
    }
    public nonisolated func request(_ request: OSSystemExtensionRequest,
                                    actionForReplacingExtension existing: OSSystemExtensionProperties,
                                    withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }
}
#endif
