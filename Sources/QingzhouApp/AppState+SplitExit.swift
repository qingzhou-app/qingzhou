import Foundation
import QingzhouCore

extension AppState {
    // MARK: - 分流方案（国内直连 / 海外出口）

    /// 海外出口节点（住宅 SOCKS5）。用户手选，不会被自动择优改动。
    public var splitExitExitNode: Node? {
        guard let id = settings.splitExitExitNodeID else { return nil }
        return nodes.first { $0.id == id }
    }

    /// 跳板节点：出口自己的流量经它出去。
    public var splitExitHopNode: Node? {
        guard let id = settings.splitExitHopNodeID else { return nil }
        return nodes.first { $0.id == id }
    }

    /// 分流方案能否真正启用：开关打开 + 两个节点都在 + 不是同一个节点。
    /// 返回 nil 表示可用，否则是给人看的原因。
    /// iOS 无分流 UI，即使 iCloud 同步了 macOS 的 `splitExitEnabled` 也必须忽略。
    public var splitExitBlockedReason: String? {
        #if os(macOS)
        guard settings.splitExitEnabled else { return nil }
        guard let exit = splitExitExitNode else { return L("未选择「海外出口」节点") }
        guard let hop = splitExitHopNode else { return L("未选择「跳板」节点") }
        if exit.host == hop.host, exit.port == hop.port, exit.protocolType == hop.protocolType {
            return L("「海外出口」和「跳板」是同一个节点，会绕成死循环")
        }
        return nil
        #else
        return nil
        #endif
    }

    /// 当前真正可用的分流节点对；开关关着或配置不完整时 nil。
    var activeSplitExit: (exit: Node, hop: Node)? {
        #if os(macOS)
        guard settings.splitExitEnabled, splitExitBlockedReason == nil,
              let exit = splitExitExitNode, let hop = splitExitHopNode else { return nil }
        return (exit, hop)
        #else
        return nil
        #endif
    }

    /// 可用于「海外出口」的节点：SOCKS5 优先展示，但不禁用其它协议 ——
    /// 静态住宅代理通常是 SOCKS5，用户也可能拿别的协议顶一下。
    public var splitExitCandidates: [Node] { sortedNodes }

    /// 切换分流开关。打开时强制规则模式：分流方案自带完整 routing，
    /// 全局/直连模式那两套 routing 与它互斥，留着只会让人以为「开了没生效」。
    public func setSplitExitEnabled(_ enabled: Bool) {
        #if os(macOS)
        guard settings.splitExitEnabled != enabled else { return }
        settings.splitExitEnabled = enabled
        if enabled, settings.proxyMode != .rule {
            settings.proxyMode = .rule
        }
        if enabled { loadSplitExitListsStatus() }   // 打开时立刻读一次，界面不用等下次启动
        applySettingsSideEffects()
        persist()
        // 分流开关改变出口身份 → VPN 在跑时必须重连，否则还在按旧配置走。
        Task { await reapplyRunningTunnel() }
        #endif
    }

    public func setSplitExitExitNode(_ id: UUID?) {
        #if os(macOS)
        guard settings.splitExitExitNodeID != id else { return }
        settings.splitExitExitNodeID = id
        persist()
        Task { await reapplyRunningTunnel() }
        #endif
    }

    public func setSplitExitHopNode(_ id: UUID?) {
        #if os(macOS)
        guard settings.splitExitHopNodeID != id else { return }
        settings.splitExitHopNodeID = id
        persist()
        Task { await reapplyRunningTunnel() }
        #endif
    }

    public func setSplitExitPolicyGroups(_ groups: [SplitExitPolicyGroup]) {
        #if os(macOS)
        guard settings.splitExitPolicyGroups != groups else { return }
        settings.splitExitPolicyGroups = groups
        persist()
        if settings.splitExitEnabled {
            Task { await reapplyRunningTunnel() }
        }
        #endif
    }
}
