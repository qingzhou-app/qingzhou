import Foundation
import QingzhouCore

/// App Store 截图专用 demo 模式（fastlane snapshot 的思路）。
///
/// 仅当进程带 `-qz-screenshot` launch argument 时激活——只有模拟器上
/// `simctl launch <udid> <bundle-id> -qz-screenshot -qz-tab nodes` 这么传，
/// 生产/正式包不会以该参数启动。激活后：
///   - 注入一套演示配置（节点/订阅/规则，带真实感延迟、双延迟 chip、倍率标注、
///     每节点测量历史 → 「为什么选它」四维评分有数据可显）；
///   - 注入演示连接 / 域名历史 / 规则命中计数 / 代理直连流量拆分（连接页、域名分析、
///     规则页在模拟器上才不是空态 —— 真数据都来自隧道扩展，模拟器跑不了 NE）；
///   - 伪造「已连接」状态并按秒喂波形样本；
///   - `-qz-tab home|nodes|node-detail|subscriptions|rules|connections|analysis|settings`
///     指定落点：`node-detail` 在节点页自动打开当前节点详情 sheet；`connections` 从首页
///     push 连接明细；`analysis` 再自动弹出域名分析 sheet（都是真实可达的导航状态）；
///   - `AppState.startSchedulers` 整体短路：不测速/不择优/不拉订阅/不碰 iCloud，
///     防止真实调度覆盖演示数据（演示节点的 host 都是假的，一测全挂）。
///
/// 与「示例数据已删」的纪律不冲突：那次删的是喂进**正常路径**的假连接流
/// （sampleConnectionsLoop），这里是显式参数才进的隔离模式，正常启动完全不可达。
@MainActor
enum ScreenshotDemoMode {
    static var isActive: Bool {
        ProcessInfo.processInfo.arguments.contains("-qz-screenshot")
    }

    /// `-qz-tab` 的原始值（node-detail / analysis 等复合场景要区分，不止映射 tab）。
    private static var tabValue: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-qz-tab"), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }

    private static var requestedSection: AppSection? {
        switch tabValue {
        case "home": return .home
        case "nodes", "node-detail": return .nodes
        case "subscriptions": return .subscriptions
        case "rules": return .rules
        // iOS 上连接页不占 tab，从首页流量卡入口 push（见 HomeView 的 demo 钩子）
        case "connections", "analysis": return .home
        case "settings": return .settings
        default: return nil
        }
    }

    /// 截图目标是「节点详情（为什么选它）」→ NodesView 出现后自动打开当前节点的详情 sheet。
    static var wantsNodeDetail: Bool { isActive && tabValue == "node-detail" }
    /// 截图目标是连接明细 / 域名分析 → HomeView 出现后自动 push 连接页。
    static var wantsConnectionsPush: Bool {
        isActive && (tabValue == "connections" || tabValue == "analysis")
    }
    /// 截图目标是域名分析 → 连接页出现后自动弹出分析 sheet。
    static var wantsDomainAnalysisSheet: Bool { isActive && tabValue == "analysis" }
    /// 节点列表截图：呈现「自动择优刚跑完」的反馈条（与真实点按「自动择优」后的 UI 一致）。
    static var wantsAutoSelectBanner: Bool { isActive && tabValue == "nodes" }

    /// `-qz-scroll <y>`：页面滚动锚点比例（scrollTo 的 UnitPoint.y，含义随页面而定：
    /// 首页 = 公网 IP 卡的对齐比例，规则页 = 自定义规则区的对齐比例）。
    /// 首页竖排布局下波形卡在首屏之下、规则页表单占半屏 —— 截图要露出核心内容只能滚，
    /// 这些都是真实下滑可达的状态，不改布局。
    static var scrollAnchorY: Double? {
        guard isActive else { return nil }
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-qz-scroll"), args.indices.contains(i + 1) else { return nil }
        return Double(args[i + 1])
    }

    /// 截图语言跟随 `-AppleLanguages` 启动参数：演示**数据**（节点名/订阅名）也要跟语言走，
    /// en 截图里出现中文节点名会露馅。UI 字符串本身走字符串目录，不归这里管。
    private static var isEnglish: Bool {
        Locale.preferredLanguages.first?.lowercased().hasPrefix("en") ?? false
    }
    private static func T(_ zh: String, _ en: String) -> String { isEnglish ? en : zh }

    static func applyIfRequested(to state: AppState) {
        guard isActive else { return }

        // UI 语言是 App 内设置（默认 zh-Hans），不吃 -AppleLanguages —— en 截图必须
        // 把设置一并切过去（根视图的 \.locale 环境值 + L10n 动态字符串都由它驱动）。
        // 直接赋值不会走 applySettingsSideEffects，这里手动同步 L10n。
        state.settings.language = isEnglish ? .en : .zhHans
        L10n.setLanguage(state.settings.language)

        let now = Date()
        let subID = UUID()
        state.subscriptions = [
            Subscription(
                id: subID,
                name: T("云帆机场", "Nimbus Cloud"),
                url: URL(string: "https://airport.example.com/api/v1/subscribe?token=demo")!,
                lastUpdatedAt: now.addingTimeInterval(-3600),
                nodeCount: 10,
                usedBytes: 52_400_000_000,
                totalBytes: 200_000_000_000,
                expiresAt: now.addingTimeInterval(86_400 * 202)
            ),
        ]

        // 名字/地区/倍率/延迟都取真实订阅里常见的形态；经代理延迟只给一部分节点，
        // 和真实使用中「测过一轮直连、部分节点补测过经代理」的状态一致。
        // host 每个节点唯一 —— identityFingerprint 含 host，测量历史按指纹存，
        // 共用 host 会让所有同协议节点混用同一份历史（评分全串味）。
        // host 刻意短（hk1.example.net）：iPhone 列表行「协议 · host:port · ↓带宽」超长
        // 会折成三行，节点名也别带「| 0.5x」后缀（挤压截断），倍率走 parameters["rate"]。
        func node(
            _ name: String, _ proto: ProxyProtocol, _ host: String, _ latency: Int,
            proxied: Int? = nil, peakDown: Int64? = nil, rate: String? = nil
        ) -> Node {
            var n = Node(name: name, protocolType: proto, host: host, port: 443)
            n.password = "demo"
            n.uuid = UUID().uuidString
            n.lastLatencyMs = latency
            n.lastTestedAt = now.addingTimeInterval(-90)
            if let proxied {
                n.lastProxiedLatencyMs = proxied
                n.lastProxiedTestedAt = now.addingTimeInterval(-90)
            }
            if let peakDown {
                n.observedPeakDownBps = peakDown
                n.observedBandwidthAt = now.addingTimeInterval(-600)
            }
            if let rate {
                n.parameters["rate"] = rate
            }
            n.subscriptionId = subID
            return n
        }
        // 带宽（↓ 峰值）只给当前节点：iPhone 列表行宽有限，带上带宽还想单行，
        // 「协议 · host:port」必须 ≤27 字符（TROJAN + hk.example.net:443 刚好卡线）。
        // 其余节点不带 peakDown —— 行短、不折行；带宽维度的展示由详情页评分条承担。
        let current = node(
            T("🇭🇰 香港 IEPL-01", "🇭🇰 HK IEPL-01"), .trojan,
            "hk.example.net", 32, proxied: 58, peakDown: 9_800_000
        )
        state.nodes = [
            current,
            node(T("🇭🇰 香港 BGP-02", "🇭🇰 HK BGP-02"), .shadowsocks,
                 "hk2.example.net", 41, proxied: 74, rate: "0.5"),
            node(T("🇯🇵 东京 IIJ-01", "🇯🇵 Tokyo IIJ-01"), .vless,
                 "jp1.example.net", 48, proxied: 83),
            node(T("🇯🇵 大阪 SoftBank", "🇯🇵 Osaka SoftBank"), .vmess,
                 "jp2.example.net", 55),
            node(T("🇸🇬 新加坡 直连-01", "🇸🇬 Singapore SG-01"), .trojan,
                 "sg1.example.net", 62, proxied: 95),
            node(T("🇰🇷 首尔 KT-01", "🇰🇷 Seoul KT-01"), .vmess,
                 "kr1.example.net", 66),
            node(T("🇬🇧 伦敦 CN2-01", "🇬🇧 London CN2-01"), .vless,
                 "uk1.example.net", 71),
            node(T("🇺🇸 洛杉矶 GIA-01", "🇺🇸 LA GIA-01"), .trojan,
                 "us1.example.net", 128, proxied: 176),
            node(T("🇺🇸 圣何塞 CN2", "🇺🇸 San Jose CN2"), .vless,
                 "us2.example.net", 142, rate: "2"),
            node(T("🇩🇪 法兰克福-01", "🇩🇪 Frankfurt-01"), .shadowsocks,
                 "de1.example.net", 185),
        ]
        state.currentNodeId = current.id

        injectMetricsHistory(into: state, now: now)

        state.customRules = [
            Rule(type: .domainSuffix, value: "openai.com", target: .proxy),
            Rule(type: .domainSuffix, value: "youtube.com", target: .proxy),
            Rule(type: .domainKeyword, value: "github", target: .proxy),
            Rule(type: .domainSuffix, value: "bilibili.com", target: .direct),
            Rule(type: .geoip, value: "CN", target: .direct),
            Rule(type: .domainSuffix, value: "doubleclick.net", target: .reject),
        ]
        injectRemoteRules(into: state, now: now)
        injectRuleHits(into: state, now: now)
        injectConnections(into: state, now: now)

        // 展示值：调度器已在 startSchedulers 整体短路，设置页显示「启动时+定时」只是观感，
        // 不会真跑（真跑会拿假 host 测速把演示延迟洗掉）。
        state.settings.autoSelectTrigger = .onAppLaunchAndInterval

        // 公网 IP 卡片：注入演示值。真实刷新会把本机真实出口 IP 截进 App Store 图（隐私）,
        // refreshPublicIPInfo 已在 demo 下短路。
        state.proxyIPInfo = PublicIPInfo(
            ip: "45.154.23.108", country: "Hong Kong", city: "Kwun Tong", isp: "IEPL Network Ltd."
        )
        state.directIPInfo = PublicIPInfo(
            ip: "101.87.164.52", country: "China", region: "Shanghai",
            city: T("上海", "Shanghai"), isp: "China Telecom"
        )

        // 代理/直连流量拆分（首页流量卡的「代理 / 直连」行）：真实来源是扩展轮询 xray
        // QueryStats 写 App Group，模拟器没有 —— 注入与会话累计量级一致的演示值。
        state.outboundStats = XrayOutboundStats(
            outbounds: [
                "proxy": .init(uplinkBytes: 96_000_000, downlinkBytes: 1_620_000_000),
                "direct": .init(uplinkBytes: 58_000_000, downlinkBytes: 742_000_000),
            ],
            sampledAt: now
        )

        if let section = requestedSection {
            state.activeSection = section
        }

        // 「已连接 2 小时 47 分」+ 满窗波形：先回填 60 秒历史样本让波形一进来就是满的，
        // 再起每秒喂样本的循环维持「实时在跑」的观感（顺带重申 isVPNRunning，
        // 抵抗任何状态观察者把它翻回 false）。
        state.isVPNRunning = true
        state.connectedSince = now.addingTimeInterval(-(2 * 3600 + 47 * 60))
        var upTotal: Int64 = 156_000_000
        var downTotal: Int64 = 2_410_000_000
        func sample(at t: Date, phase: Double) -> TrafficStats {
            let down = Int64(3_200_000 + 4_100_000 * abs(sin(phase / 7)) + Double.random(in: 0...900_000))
            let up = Int64(310_000 + 190_000 * abs(sin(phase / 5)) + Double.random(in: 0...80_000))
            upTotal += up
            downTotal += down
            return TrafficStats(
                uploadBytes: upTotal, downloadBytes: downTotal,
                uploadSpeedBps: up, downloadSpeedBps: down,
                activeConnections: Int.random(in: 18...27), sampledAt: t
            )
        }
        for s in (0..<60).reversed() {
            state.trafficHistory.record(sample(at: now.addingTimeInterval(-Double(s)), phase: Double(60 - s)))
        }
        Task { @MainActor in
            var phase = 60.0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                phase += 1
                state.isVPNRunning = true
                state.tunnelError = nil   // 任何真实隧道操作漏网报错 → 秒关，别脏了截图
                state.trafficHistory.record(sample(at: Date(), phase: phase))
            }
        }
    }

    // MARK: - 测量历史（「为什么选它」四维评分的数据源）

    /// 给每个演示节点灌一段测量历史：稳定性维度才有真实样本可算（<3 条按中性 70 分，
    /// 评分构成条会显得「没依据」）。当前节点给一段干净低抖动的历史（≈98 分），
    /// 其余节点按延迟档位递增抖动/丢包 —— 和「当前节点是择优赢家」的叙事自洽。
    private static func injectMetricsHistory(into state: AppState, now: Date) {
        for (rank, n) in state.nodes.enumerated() {
            let base = n.lastLatencyMs ?? 100
            // 抖动幅度与丢包率随排名放大：赢家几乎不抖，末位节点偶发丢包
            let jitter = 1.0 + Double(rank) * 0.9
            for i in 0..<16 {
                let at = now.addingTimeInterval(-Double(16 - i) * 1800)   // 每 30 分钟一轮
                let wave = sin(Double(i) * 1.1 + Double(rank))            // 确定性伪抖动
                let latency = max(8, base + Int((wave * jitter).rounded()))
                var loss: Double? = 0
                if rank >= 8, i % 5 == 3 { loss = 0.33 }                  // 尾部节点偶发丢包
                var proxied: Int?
                if let p = n.lastProxiedLatencyMs, i >= 13 {              // 最近几轮补过经代理
                    proxied = p + Int((wave * 3).rounded())
                }
                state.nodeMetricsHistory.recordDirect(
                    fingerprint: n.identityFingerprint,
                    latencyMs: latency, lossFraction: loss, at: at
                )
                if let proxied {
                    state.nodeMetricsHistory.recordProxied(
                        fingerprint: n.identityFingerprint, proxiedMs: proxied, at: at.addingTimeInterval(60)
                    )
                }
            }
        }
    }

    // MARK: - 远程规则（规则页的「远程规则」区 + 状态徽标）

    /// 真实远程规则来自网络拉取；demo 里注入一小份有代表性的列表并把状态标成
    /// 「成功 · 半小时前」——否则 RulesView 的 .task 会发真实网络请求，失败红字会脏截图。
    private static func injectRemoteRules(into state: AppState, now: Date) {
        let proxySuffixes = [
            "netflix.com", "nflxvideo.net", "twitter.com", "t.co", "twimg.com",
            "instagram.com", "telegram.org", "wikipedia.org", "reddit.com",
            "medium.com", "nytimes.com", "bbc.co.uk",
        ]
        let directSuffixes = ["taobao.com", "jd.com", "qq.com", "163.com", "douyin.com", "zhihu.com"]
        let rejectSuffixes = ["adcolony.com", "applovin.com", "vungle.com"]
        var rules: [Rule] = []
        rules += proxySuffixes.map { Rule(type: .domainSuffix, value: $0, target: .proxy) }
        rules += directSuffixes.map { Rule(type: .domainSuffix, value: $0, target: .direct) }
        rules += rejectSuffixes.map { Rule(type: .domainSuffix, value: $0, target: .reject) }
        rules.append(Rule(type: .domainKeyword, value: "spotify", target: .proxy))
        rules.append(Rule(type: .ipCIDR, value: "91.108.4.0/22", target: .proxy))
        rules.append(Rule(type: .geoip, value: "cn", target: .direct))
        rules.append(Rule(type: .final, value: "", target: .proxy))
        state.remoteRules = rules
        state.remoteRulesStatus = .success(at: now.addingTimeInterval(-1800), count: rules.count)
    }

    // MARK: - 规则命中计数（规则页「近 30 天命中 N 次」）

    private static func injectRuleHits(into state: AppState, now: Date) {
        // 与 customRules 顺序对应：openai / youtube / github / bilibili / geoip CN / doubleclick
        let counts = [47, 156, 89, 203, 512, 76]
        for (rule, count) in zip(state.customRules, counts) {
            for i in 0..<count {
                // 摊到近 14 天里，天内小时随 i 变化 —— 只求分布自然，无需真随机
                let daysAgo = Double(i % 14)
                let at = now.addingTimeInterval(-(daysAgo * 86_400 + Double(i % 23) * 3600))
                state.recordRuleHit(rule.id, at: at)
            }
        }
    }

    // MARK: - 连接 / 域名历史（连接明细页 + 域名分析页）

    /// 一条演示连接的规格：域名、目标端口、路由（nil = 走当前节点）、命中规则文本、
    /// 今天的活跃条数、每个过往日的基准条数（0 = 今天新出现 → 「今日新增」区）。
    private struct ConnSpec {
        var host: String
        var port: Int
        var route: String?          // nil → 当前节点名；"DIRECT" / "REJECT"
        var rule: String
        var type: ConnectionType
        var today: Int
        var pastDaily: Int
    }

    private static func injectConnections(into state: AppState, now: Date) {
        let nodeName = state.currentNode?.name ?? "PROXY"
        // matchedRule 文本与真实回填口径一致：用户规则给 lineForm，内置规则给
        // MatchedRuleResolver 的注解文案，兜底给 Connection.noMatchedRule（显示层会本地化）。
        let specs: [ConnSpec] = [
            .init(host: "www.youtube.com", port: 443, route: nil,
                  rule: "DOMAIN-SUFFIX,youtube.com,PROXY", type: .https, today: 23, pastDaily: 29),
            .init(host: "i.ytimg.com", port: 443, route: nil,
                  rule: Connection.noMatchedRule, type: .https, today: 14, pastDaily: 18),
            .init(host: "www.google.com", port: 443, route: nil,
                  rule: Connection.noMatchedRule, type: .https, today: 16, pastDaily: 21),
            .init(host: "chat.openai.com", port: 443, route: nil,
                  rule: "DOMAIN-SUFFIX,openai.com,PROXY", type: .https, today: 12, pastDaily: 9),
            .init(host: "api.github.com", port: 443, route: nil,
                  rule: "DOMAIN-KEYWORD,github,PROXY", type: .https, today: 9, pastDaily: 15),
            .init(host: "avatars.githubusercontent.com", port: 443, route: nil,
                  rule: "DOMAIN-KEYWORD,github,PROXY", type: .https, today: 7, pastDaily: 11),
            .init(host: "x.com", port: 443, route: nil,
                  rule: Connection.noMatchedRule, type: .https, today: 8, pastDaily: 7),
            .init(host: "claude.ai", port: 443, route: nil,
                  rule: Connection.noMatchedRule, type: .https, today: 5, pastDaily: 0),
            .init(host: "notion.so", port: 443, route: nil,
                  rule: Connection.noMatchedRule, type: .https, today: 3, pastDaily: 0),
            .init(host: "www.bilibili.com", port: 443, route: "DIRECT",
                  rule: "DOMAIN-SUFFIX,bilibili.com,DIRECT", type: .https, today: 19, pastDaily: 34),
            .init(host: "api.bilibili.com", port: 443, route: "DIRECT",
                  rule: "DOMAIN-SUFFIX,bilibili.com,DIRECT", type: .https, today: 8, pastDaily: 13),
            .init(host: "www.baidu.com", port: 443, route: "DIRECT",
                  rule: "geosite:cn（内置国内域名直连）", type: .https, today: 11, pastDaily: 16),
            .init(host: "api.weixin.qq.com", port: 443, route: "DIRECT",
                  rule: "geosite:cn（内置国内域名直连）", type: .https, today: 9, pastDaily: 12),
            .init(host: "stats.doubleclick.net", port: 443, route: "REJECT",
                  rule: "DOMAIN-SUFFIX,doubleclick.net,REJECT", type: .https, today: 15, pastDaily: 10),
            // 追踪器选独立根域名（不选 hm.baidu.com）：域名分析按根域聚合，
            // 混进 baidu.com 会把主站行搞成「混合 + 广告拦截规则」的怪相。
            .init(host: "www.google-analytics.com", port: 443, route: "REJECT",
                  rule: "geosite:category-ads-all（内置广告拦截）", type: .https, today: 5, pastDaily: 8),
            .init(host: "223.5.5.5", port: 53, route: "DIRECT",
                  rule: "geoip:cn（内置国内 IP 直连）", type: .udp, today: 4, pastDaily: 6),
            .init(host: "8.8.8.8", port: 53, route: nil,
                  rule: Connection.noMatchedRule, type: .udp, today: 3, pastDaily: 5),
        ]

        var sourcePort = 51_200
        func make(_ s: ConnSpec, openedAt: Date) -> Connection {
            sourcePort += 1
            return Connection(
                targetHost: s.host,
                sourceAddress: "192.168.1.23:\(sourcePort)",
                targetAddress: "\(s.host):\(s.port)",
                type: s.type,
                route: s.route ?? nodeName,
                matchedRule: s.rule,
                openedAt: openedAt
            )
        }

        // 过往 4 天的按天聚合历史：喂「每日」视图 + 让「今日新增」只剩真正今天首见的域名
        //（没有过往历史时所有域名都会被判成今日新增，整个列表全是 sparkles，假得明显）。
        for daysAgo in 1...4 {
            let dayNoon = now.addingTimeInterval(-Double(daysAgo) * 86_400)
            let factor = [0.9, 1.2, 0.8, 1.1][daysAgo - 1]
            var batch: [Connection] = []
            for s in specs where s.pastDaily > 0 {
                let count = max(1, Int((Double(s.pastDaily) * factor).rounded()))
                for i in 0..<count {
                    batch.append(make(s, openedAt: dayNoon.addingTimeInterval(Double(i) * 37)))
                }
            }
            state.recordDomainHistory(batch)
        }

        // 今天的「活跃连接」：主体按时间摊开摄入（连接页新的在上），最后补一轮
        // 各主要域名各一条 —— 首屏顶部是多样的 host / 路由组合，而不是同域名刷屏。
        var todayConns: [Connection] = []
        let finaleHosts = [
            "x.com", "www.google.com", "stats.doubleclick.net", "www.bilibili.com",
            "chat.openai.com", "api.github.com", "www.youtube.com", "claude.ai",
        ]
        var bulk: [Connection] = []
        var finale: [Connection] = []
        for s in specs {
            let reserveOne = finaleHosts.contains(s.host)
            let bulkCount = max(0, s.today - (reserveOne ? 1 : 0))
            for _ in 0..<bulkCount {
                bulk.append(make(s, openedAt: now))   // openedAt 稍后统一摊开
            }
        }
        bulk.shuffle()
        for (i, var c) in bulk.enumerated() {
            // 3 分钟前 → 40 分钟前之间摊开（老的在先摄入）
            let span = 37.0 * 60
            c.openedAt = now.addingTimeInterval(-(3 * 60) - span * Double(bulk.count - i) / Double(max(bulk.count, 1)))
            todayConns.append(c)
        }
        for (i, host) in finaleHosts.enumerated() {
            guard let s = specs.first(where: { $0.host == host }) else { continue }
            finale.append(make(s, openedAt: now.addingTimeInterval(-Double(finaleHosts.count - i) * 19)))
        }
        todayConns += finale
        // 按时间正序摄入（tracker 把新连接插到最前 → 列表顶部是最新的）
        for c in todayConns.sorted(by: { $0.openedAt < $1.openedAt }) {
            state.connectionTracker.ingest(c, at: c.openedAt)
        }
        state.recordDomainHistory(todayConns)
    }
}
