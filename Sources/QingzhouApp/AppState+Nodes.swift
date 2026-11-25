import Foundation
import QingzhouCore
import QingzhouProtocols

extension AppState {
    // MARK: - 节点 & 地区

    public var sortedNodes: [Node] { nodes.sorted(by: settings.nodeSortOrder) }
    public var currentNode: Node? { nodes.first { $0.id == currentNodeId } }

    /// 当前所有节点覆盖的地区 → 节点数，按节点数降序。用于设置页地区列表。
    public var regionCounts: [(region: String, count: Int)] {
        var counts: [String: Int] = [:]
        for n in nodes { counts[n.region, default: 0] += 1 }
        return counts.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
            .map { (region: $0.key, count: $0.value) }
    }

    /// 节点是否被「有效排除」：手动排除 OR 所在地区被排除。
    public func isEffectivelyExcluded(_ node: Node) -> Bool {
        node.isExcluded || settings.excludedRegions.contains(node.region)
    }

    /// 切换某地区的排除状态。排除时若当前节点在该地区，清空当前选择。
    public func toggleRegionExclusion(_ region: String) {
        if settings.excludedRegions.contains(region) {
            settings.excludedRegions.remove(region)
        } else {
            settings.excludedRegions.insert(region)
            if let cur = currentNode, cur.region == region { currentNodeId = nil }
        }
        logger.info("Region \(region) excluded=\(settings.excludedRegions.contains(region))", category: "app")
        persist()
    }

    public func toggleExclusion(_ node: Node) {
        guard let idx = nodes.firstIndex(where: { $0.id == node.id }) else { return }
        nodes[idx].isExcluded.toggle()
        logger.info("Toggled exclusion for \(nodes[idx].name) → \(nodes[idx].isExcluded)", category: "app")
        if nodes[idx].isExcluded && currentNodeId == node.id {
            currentNodeId = nil
        }
        persist()
    }

    public func select(_ node: Node) {
        guard nodes.contains(where: { $0.id == node.id }) else { return }
        let changed = currentNodeId != node.id
            || (isVPNRunning && appliedTunnelConfiguration?.matches(node) != true)
        currentNodeId = node.id
        logger.info("Selected node \(node.name)", category: "app")
        persist()
        // 手动切节点时若 VPN 在跑，也热切换立即生效（只换节点 → 走原地换出口快路径）
        if changed {
            Task { await reapplyRunningTunnel(scope: .nodeOnly) }
        }
    }

    public func addNode(fromURL urlString: String) throws {
        let node = try ProxyURLParser.parse(urlString)
        merge(node: node)
        logger.info("Added node \(node.name)", category: "app")
        persist()
    }

    /// 批量解析输入（多行链接 **或** Clash YAML），成功的入库，失败的回传。
    @discardableResult
    public func addNodes(fromText text: String) -> (added: Int, errors: [(String, Error)]) {
        // Clash YAML 优先识别 —— 看到 `proxies:` 顶层 key 就走 YAML 解析路径
        if ClashConfigParser.isClashConfig(text) {
            do {
                let (parsed, errs) = try ClashConfigParser.parse(text)
                for node in parsed { merge(node: node) }
                if !parsed.isEmpty {
                    logger.info("Imported \(parsed.count) Clash nodes", category: "app")
                    persist()
                }
                let errors = errs.map { ($0.name, NSError(
                    domain: "ClashConfig", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: $0.reason]) as Error) }
                return (parsed.count, errors)
            } catch {
                logger.warn("Clash YAML parse failed: \(error)", category: "app")
                // 失败就退回到链接解析路径
            }
        }
        let (parsed, errors) = ProxyURLParser.parseBatch(text)
        for node in parsed { merge(node: node) }
        if !parsed.isEmpty {
            logger.info("Manually added \(parsed.count) nodes", category: "app")
            persist()
        }
        return (parsed.count, errors)
    }

    /// 节点入库：同身份指纹更新，否则追加。不写日志、不 persist —— 调用方决定。
    private func merge(node: Node) {
        if let idx = nodes.firstIndex(where: { $0.identityFingerprint == node.identityFingerprint }) {
            var existing = nodes[idx]
            existing.name = node.name
            existing.parameters = node.parameters
            nodes[idx] = existing
        } else {
            nodes.append(node)
        }
    }

    public func updateNode(_ edited: Node) {
        guard let index = nodes.firstIndex(where: { $0.id == edited.id }) else { return }
        let live = nodes[index]
        let sameConnection = live.identityFingerprint == edited.identityFingerprint
        var updated = edited
        updated.lastLatencyMs = sameConnection ? live.lastLatencyMs : nil
        updated.lastTestedAt = sameConnection ? live.lastTestedAt : nil
        updated.lastProxiedLatencyMs = sameConnection ? live.lastProxiedLatencyMs : nil
        updated.lastProxiedTestedAt = sameConnection ? live.lastProxiedTestedAt : nil
        updated.observedPeakDownBps = sameConnection ? live.observedPeakDownBps : nil
        updated.observedBandwidthAt = sameConnection ? live.observedBandwidthAt : nil
        nodes[index] = updated
        persist()
    }

    public func removeNode(_ node: Node) {
        nodes.removeAll { $0.id == node.id }
        if currentNodeId == node.id { currentNodeId = nil }
        persist()
    }
}
