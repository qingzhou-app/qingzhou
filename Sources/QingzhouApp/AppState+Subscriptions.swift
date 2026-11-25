import Foundation
import QingzhouCore
import QingzhouSubscription

extension AppState {
    // MARK: - 订阅

    public func addSubscription(name: String, url: URL) async {
        let sub = Subscription(name: name.isEmpty ? (url.host ?? "Subscription") : name, url: url)
        subscriptions.append(sub)
        persist()
        await refreshSubscription(sub)
        // 首次拉到节点后自动测速 + 选延迟最优节点，并 toast 告知用户（不打断操作）。
        if subscriptionErrors[sub.id] == nil, !nodes.isEmpty {
            await autoSelectBestNode()
            if let best = currentNode {
                showToast(L("已为你选择延迟最优节点：\(best.name)"))
            }
        }
    }

    /// 轻量非阻塞反馈：设置 toast 文案，3 秒后自动清空。
    public func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    public func refreshSubscription(_ subscription: Subscription) async {
        guard subscriptions.contains(where: { $0.id == subscription.id }), !Task.isCancelled else { return }
        let refreshID = UUID()
        subscriptionRefreshIDs[subscription.id] = refreshID
        defer { if subscriptionRefreshIDs[subscription.id] == refreshID { subscriptionRefreshIDs[subscription.id] = nil } }
        do {
            let result = try await subscriptionFetcher.refresh(subscription)
            var updated = result.updated
            let payload = result.payload
            guard !Task.isCancelled, subscriptionRefreshIDs[subscription.id] == refreshID,
                  let idx = subscriptions.firstIndex(where: { $0.id == subscription.id && $0.url == subscription.url }) else { return }
            merge(newNodes: payload.nodes, fromSubscription: updated.id)
            updated.name = subscriptions[idx].name // 刷新期间的本地改名优先
            updated.nodeCount = nodes.filter { $0.subscriptionId == updated.id }.count
            subscriptions[idx] = updated
            subscriptionErrors[subscription.id] = nil
            persist()
        } catch {
            guard !Task.isCancelled, subscriptionRefreshIDs[subscription.id] == refreshID,
                  subscriptions.contains(where: { $0.id == subscription.id }) else { return }
            switch error {
            case SubscriptionRefreshError.httpStatus(let code):
                subscriptionErrors[subscription.id] = L("订阅服务器返回 HTTP \(code)，已保留原有节点")
            case SubscriptionRefreshError.unrecognizedFormat:
                subscriptionErrors[subscription.id] = L("订阅格式无法识别，请确认链接正确（能否在浏览器里直接打开）")
            case SubscriptionRefreshError.noSupportedNodes:
                subscriptionErrors[subscription.id] = L("订阅中的节点均无法解析或暂不支持，已保留原有节点")
            default: subscriptionErrors[subscription.id] = error.localizedDescription
            }
            logger.error("Refresh subscription \(subscription.name) failed: \(error)", category: "subscription")
        }
    }

    public func removeSubscription(_ subscription: Subscription) {
        subscriptionRefreshIDs[subscription.id] = nil
        subscriptions.removeAll { $0.id == subscription.id }
        nodes.removeAll { $0.subscriptionId == subscription.id }
        if let cn = currentNode, cn.subscriptionId == subscription.id { currentNodeId = nil }
        subscriptionErrors[subscription.id] = nil
        persist()
    }

    public func merge(newNodes incoming: [Node], fromSubscription subId: UUID) {
        let oldBySub = nodes.filter { $0.subscriptionId == subId }
        let oldByFingerprint = Dictionary(oldBySub.map { ($0.identityFingerprint, $0) }, uniquingKeysWith: { first, _ in first })

        var preserved: [Node] = []
        var seen = Set<String>()
        for n in incoming {
            guard seen.insert(n.identityFingerprint).inserted else { continue }
            var merged = n
            merged.subscriptionId = subId
            if let prev = oldByFingerprint[n.identityFingerprint] {
                merged.id = prev.id
                merged.isExcluded = prev.isExcluded
                merged.lastLatencyMs = prev.lastLatencyMs
                merged.lastTestedAt = prev.lastTestedAt
                merged.lastProxiedLatencyMs = prev.lastProxiedLatencyMs
                merged.lastProxiedTestedAt = prev.lastProxiedTestedAt
                merged.observedPeakDownBps = prev.observedPeakDownBps
                merged.observedBandwidthAt = prev.observedBandwidthAt
            }
            preserved.append(merged)
        }
        nodes.removeAll { $0.subscriptionId == subId }
        nodes.append(contentsOf: preserved)

        // 选中的节点可能被上游删了，或它的 host/port/凭据变了 → identityFingerprint 变了
        // → 被当成新节点、老 id 丢失。此时 currentNodeId 会悬空指向一个已不存在的节点
        //（currentNode 变 nil，热切换也察觉不到——id 没"变"，只是指向了空）。
        // 跟 removeSubscription / toggleExclusion 等所有改动路径保持一致：悬空就清掉。
        if let id = currentNodeId, !nodes.contains(where: { $0.id == id }) {
            currentNodeId = nil
            logger.info("Selected node gone after subscription refresh — cleared selection", category: "subscription")
        }
    }
}
