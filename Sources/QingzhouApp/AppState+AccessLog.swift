import Foundation
import QingzhouCore
import QingzhouRules

extension AppState {
    // MARK: - Access Log & 历史统计

    #if os(macOS)
    /// 用最新的「源端口 → 来源 App」映射，回填还没标注来源的**活跃**连接。
    /// content filter 的 map 常晚于连接 ingest 才就绪，只在解析那刻查一次会漏掉大批连接。
    /// 两道防误标：只回填活跃连接（已关闭的源端口可能早被回收给别的 App）；
    /// 带时间戳的条目还要过「flow 观测时刻 ≈ openedAt」的时间窗（SourceAppMap）。
    /// internal 供单测直接驱动。
    func backfillSourceApps() {
        guard !sourceAppMap.isEmpty else { return }
        for i in connectionTracker.connections.indices
        where connectionTracker.connections[i].sourceApp == nil && connectionTracker.connections[i].isActive {
            if let port = connectionTracker.connections[i].sourceAddress.split(separator: ":").last.map(String.init),
               let bundleID = sourceAppMap.bundleID(forPort: port, openedAt: connectionTracker.connections[i].openedAt) {
                connectionTracker.connections[i].sourceApp = bundleID
            }
        }
    }
    #endif

    /// 用最新的「IP → 域名」映射，把已摄入连接里还是裸 IP 的 targetHost 回翻成域名。
    ///
    /// 为什么需要：appex 的 fakedns-map 每秒才落盘一次，连接（access log 行）常在对应
    /// DNS 应答进 map 之前就被 ingest —— 只在解析那刻查一次，这批连接会永远顶着裸 IP：
    /// 按域名搜不到、开「忽略 IP」时整行被藏（zhihu 验收反馈的可修部分）。
    ///
    /// 只改 targetHost（搜索/聚合用）并重算 matchedRule（host 变了命中会变）；
    /// targetAddress 保留 ip:port 原样 —— 那一行本来就该显示真实地址，
    /// 且 ConnectionTracker 的身份索引 key 是 ingest 时算好的字符串，不受字段就地修改影响。
    /// 已经落进 DomainDailyHistory 的按 IP 记录不回改（历史口径以 ingest 时刻为准）。
    /// internal 供单测直接驱动。
    func backfillDomainNames() {
        guard !fakeDNSMap.isEmpty else { return }
        var resolver: MatchedRuleResolver?
        for i in connectionTracker.connections.indices {
            guard let domain = fakeDNSMap[connectionTracker.connections[i].targetHost] else { continue }
            connectionTracker.connections[i].targetHost = domain
            let r = resolver ?? currentMatchedRuleResolver()
            resolver = r
            let res = r.resolveDetailed(
                host: domain,
                route: DomainAnalyzer.routeCategory(connectionTracker.connections[i].route)
            )
            // 命中计数补记：ingest 时这条还是裸 IP（多半没认领任何用户规则），翻译成域名后
            // 才命中域名规则。只在回填**改变了**认领结果时补记，避免同一连接重复计数。
            if res.userRuleID != nil, res.ruleText != connectionTracker.connections[i].matchedRule {
                recordRuleHit(res.userRuleID, at: connectionTracker.connections[i].openedAt)
            }
            connectionTracker.connections[i].matchedRule = res.ruleText
        }
    }

    func ingestAccessLog() {
        defer {
            // 每轮都老化一遍（即使没有新日志行）：xray access log 只记连接建立，
            // 超过 ConnectionTracker.idleTimeout 无活动的连接由这里判定为已关闭。
            connectionTracker.ageOut()
        }
        guard let url = AppGroupStorage.accessLogURL,
              let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < accessLogOffset { accessLogOffset = 0 }   // 文件被新会话清空/重建 → 重头读
        guard size > accessLogOffset else { return }        // 没有新行
        try? handle.seek(toOffset: accessLogOffset)
        let data = (try? handle.readToEnd()) ?? Data()
        accessLogOffset = size
        guard let text = String(data: data, encoding: .utf8) else { return }
        let entries = AccessLogParser.parse(text)
        guard !entries.isEmpty else { return }
        let proxyName = appliedTunnelConfiguration?.nodeName
        let resolver = currentMatchedRuleResolver()
        var newConnections: [Connection] = []
        newConnections.reserveCapacity(entries.count)
        for entry in entries {
            var conn = entry.makeConnection(proxyDisplayName: proxyName)
            // FakeDNS 的假 IP（198.18.x.x）→ 反查回真域名，连接列表/域名分析才有意义
            if let domain = fakeDNSMap[entry.targetHost] {
                conn.targetHost = domain
                conn.targetAddress = "\(domain):\(entry.targetPort)"
            }
            // matchedRule 回填：用户规则一致才认领，否则推断 xray 内置规则 / 「未命中」哨兵。
            // 必须在 FakeDNS 翻译**之后**做，否则拿假 IP 去匹配域名规则全落空。
            let resolution = resolver.resolveDetailed(
                host: conn.targetHost,
                route: DomainAnalyzer.routeCategory(conn.route)
            )
            conn.matchedRule = resolution.ruleText
            // 源端口 → 来源 App（macOS content filter 标注的 bundle id）。
            // openedAt 就是本次 ingest 时刻，时间窗校验挡掉「map 里还留着上一个占用
            // 该端口的 App」的陈旧条目。
            if let port = entry.sourceAddress.split(separator: ":").last.map(String.init),
               let bundleID = sourceAppMap.bundleID(forPort: port, openedAt: conn.openedAt) {
                conn.sourceApp = bundleID
            }
            // 同身份（源地址+目标+端口）重现 → 只刷新活跃时间，不重复插入。
            // 域名每日历史只统计 tracker 判定为**新连接**的（UDP/QUIC 同 socket 的重现
            // 不算新访问），否则「连接次数」会被灌水，和连接页的观感也对不上。
            if connectionTracker.ingest(conn) {
                newConnections.append(conn)
                // 命中计数：与域名历史同口径，只算 tracker 判定的新连接（重现不灌水）
                recordRuleHit(resolution.userRuleID, at: conn.openedAt)
            }
        }
        recordDomainHistory(newConnections)
    }

    /// 隧道停止 → 所有仍活跃的连接立即归入「已关闭」。
    func markAllConnectionsClosed(at now: Date = Date()) {
        connectionTracker.closeAll(at: now)
    }

    /// 把一批新摄入的连接并进按天域名聚合，滚动清理后（节流）落盘。
    /// internal 供单测直接喂连接（ingestAccessLog 依赖 App Group 文件，测试环境没有）。
    func recordDomainHistory(_ newConnections: [Connection]) {
        guard !newConnections.isEmpty else { return }
        domainHistory.record(newConnections)
        domainHistory.prune()
        domainHistoryDirty = true
        flushDomainHistoryIfNeeded()
    }

    /// 有脏数据且距上次落盘 ≥ 节流间隔时写盘。摄入时和每轮 access log 轮询都会调 ——
    /// 后者保证停止浏览后最后一批脏数据也会在 ≤10 秒内补写，不会一直悬着。
    func flushDomainHistoryIfNeeded() {
        guard domainHistoryDirty else { return }
        let now = Date()
        guard now.timeIntervalSince(domainHistorySavedAt) >= domainHistorySaveInterval else { return }
        domainHistorySavedAt = now
        domainHistoryDirty = false
        persistence.saveAsync(domainHistory, name: Self.domainHistoryFile)
    }

    /// 记一次用户规则命中（id 为 nil = 这条连接没认领任何用户规则，直接忽略）。
    /// 节流落盘同 domainHistory 模式。internal 供单测直接驱动（ingest 依赖 App Group 文件）。
    func recordRuleHit(_ id: UUID?, at date: Date) {
        guard let id else { return }
        ruleHitStats.recordHit(id, at: date)
        ruleHitStats.prune()
        ruleHitStatsDirty = true
        flushRuleHitStatsIfNeeded()
    }

    /// 有脏数据且距上次落盘 ≥ 节流间隔时写盘；轮询循环每轮兜底调用（同 domainHistory）。
    func flushRuleHitStatsIfNeeded() {
        guard ruleHitStatsDirty else { return }
        let now = Date()
        guard now.timeIntervalSince(ruleHitStatsSavedAt) >= ruleHitStatsSaveInterval else { return }
        ruleHitStatsSavedAt = now
        ruleHitStatsDirty = false
        persistence.saveAsync(ruleHitStats, name: Self.ruleHitStatsFile)
    }

    /// 记一条直连测量样本进节点历史（成功失败都记 —— 稳定性维度靠失败样本算丢包率；
    /// `lossFraction` 是本轮 burst 的失败占比）。节流落盘同 domainHistory 模式。
    func recordNodeDirectMeasurement(
        _ node: Node, latencyMs: Int?, lossFraction: Double? = nil, at date: Date
    ) {
        nodeMetricsHistory.recordDirect(
            fingerprint: node.identityFingerprint, latencyMs: latencyMs,
            lossFraction: lossFraction, at: date, networkID: measurementNetworkID)
        nodeMetricsDirty = true
        flushNodeMetricsIfNeeded()
    }

    /// 记一次经代理实测（同轮窗口内并入直连样本，见 `NodeMetricsHistory.recordProxied`）。
    func recordNodeProxiedMeasurement(_ node: Node, proxiedMs: Int) {
        nodeMetricsHistory.recordProxied(fingerprint: node.identityFingerprint, proxiedMs: proxiedMs, at: measurementNow(), networkID: measurementNetworkID)
        nodeMetricsDirty = true
        flushNodeMetricsIfNeeded()
    }

    /// 有脏数据且距上次落盘 ≥ 节流间隔时写盘；轮询循环每轮兜底调用（同 domainHistory ——
    /// 测量轮之间隔着几十分钟，不兜底的话最后一批脏数据会一直悬着）。
    func flushNodeMetricsIfNeeded() {
        guard nodeMetricsDirty else { return }
        let now = Date()
        guard now.timeIntervalSince(nodeMetricsSavedAt) >= nodeMetricsSaveInterval else { return }
        nodeMetricsSavedAt = now
        nodeMetricsDirty = false
        persistence.saveAsync(nodeMetricsHistory, name: Self.nodeMetricsFile)
    }

    /// 取当前规则集 + 代理模式对应的 matchedRule 回填器；输入没变时复用同一实例
    /// （保住内部 host→规则 缓存），变了才重建。key 用 Hasher 而不是逐条对比 ——
    /// 每 2 秒一次、几千条规则的 hash 是亚毫秒级，逐条 Equatable 对比反而更贵。
    private func currentMatchedRuleResolver() -> MatchedRuleResolver {
        var hasher = Hasher()
        hasher.combine(customRules)
        hasher.combine(remoteRules)
        hasher.combine(settings.proxyMode)
        let key = hasher.finalize()
        if let cached = matchedRuleResolver, key == matchedRuleResolverKey { return cached }
        let fresh = MatchedRuleResolver(rules: customRules + remoteRules, mode: settings.proxyMode)
        matchedRuleResolver = fresh
        matchedRuleResolverKey = key
        return fresh
    }

    /// 「仅 IPv6」探测调度：交给 IPv6OnlyProber 后台经 DoH 查真实 A/AAAA，仅 IPv6 的
    /// 进 `ipv6OnlyHosts`（UI 提示 + 日志）。
    ///
    /// ⚠️ 数据源必须是 **fakedns-map**（浏览器解析过的所有域名），不能只用连接列表：
    /// 仅 IPv6 站点在全 IPv4 链路下**连不上、进不了连接列表**（access log 无它的连接），
    /// 但 fakedns 仍给它分过假 IP、落进 map —— 从连接列表取会永远漏掉最该标注的它们
    /// （真机 thiswebsiteisipv6only.com 案）。连接列表并进来只为兜底 map 尚未落盘的新域名。
    /// 每轮上限 8：新访问域名要够快被探到（access log 2 秒一轮），首次浏览的爆发量由
    /// `ipv6ProbeScheduled` 去重 + 会话上限跨轮摊平。
    func probeIPv6OnlyCandidates() {
        let candidates = Set(fakeDNSMap.values).union(connectionTracker.connections.map(\.targetHost))
        var picked = 0
        for host in candidates {
            guard !HostClassifier.isBareIP(host),
                  ipv6ProbeScheduled.count < IPv6OnlyProber.sessionLimit,
                  !ipv6ProbeScheduled.contains(host) else { continue }
            ipv6ProbeScheduled.insert(host)
            picked += 1
            Task(priority: .utility) { [weak self] in
                guard let self, let verdict = await self.ipv6Prober.classifyIfNew(host: host) else { return }
                if verdict == .ipv6Only {
                    self.ipv6OnlyHosts.insert(host)
                    self.logger.warn(
                        "检测到仅 IPv6 站点 \(host)：该域名没有 IPv4 地址（只有 AAAA）。"
                        + "直连需要当前网络具有可用 IPv6；代理访问取决于节点出口。"
                        + "设计取舍见 docs/IPV6.md",
                        category: "app")
                }
            }
            if picked >= 8 { break }
        }
    }
}
