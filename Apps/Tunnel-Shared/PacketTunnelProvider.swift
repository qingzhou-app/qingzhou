// PacketTunnelProvider —— iOS + macOS 公用。
//
// 流程（NetworkExtension 子进程内）：
// 1. NEPacketTunnelProvider.startTunnel(options:) 被系统调起
// 2. 从 protocolConfiguration.providerConfiguration 读出主 App 写好的 xrayJSON
//    （不走 App Group —— 避免 macOS 隐私弹窗）
// 3. 调 setTunnelNetworkSettings 让系统配置 TUN 接口（IP / DNS / 路由）
// 4. 建一对 socketpair(AF_UNIX, SOCK_DGRAM)，一端给 libXray 当 TUN fd。
//    iOS ≤ 25 上历史方案是 KVC 读 `packetFlow.socket.fileDescriptor` 拿真 utun fd；
//    iOS 26 上 Apple 改了底层：`_socket` ivar 永远不被 populate（实测调了 readPackets 也是 nil），
//    真实 packet 流走 `_interface: NEVirtualInterface_s` 这个不透明 C 结构。
//    所以放弃 KVC，改成 socketpair shim —— Swift 当 packetFlow 和 libXray 之间的搬运工。
// 5. Swift 端起两个方向的拷贝循环：
//    - packetFlow.readPackets → 4 字节大端 protocol + IP packet → write(swiftFd)
//    - read(swiftFd) → 拆 4 字节头 → packetFlow.writePackets
// 6. XrayCore.run() 启动 xray-core，它在 socketpair 另一端读写，跟操作 utun 一样
//
// xray 用的 geoip.dat / geosite.dat 打包在 Extension bundle 的 Resources 里（geoip 为
// 精简版 only-cn-private）。若主 App 已下载完整版 geoip.dat 到 App Group `xray-data/`
//（GeoDataManager，含 sha256 校验），启动时优先用它 —— 见 resolveGeoData()。

import Darwin
import NetworkExtension
import os
import os.log
import QingzhouCore
import UserNotifications
import XrayConfig
import XrayCore

final class PacketTunnelProvider: NEPacketTunnelProvider {
    let log = OSLog(subsystem: "com.sbraveyoung.qingzhou.tunnel", category: "PacketTunnel")

    /// (Swift 持的一端, libXray 持的一端)。stopTunnel 时只 close swift 端；
    /// xray 端由 XrayCore.stop() 内部 close。
    var tunPair: (swift: Int32, xray: Int32)?
    let bridgeQueue = DispatchQueue(label: "com.sbraveyoung.qingzhou.tunnel.bridge", qos: .userInitiated)

    /// 控制两个方向拷贝循环是否继续。stopTunnel 时设 false。读写竞争一两个 packet 无所谓。
    var bridgeActive = false

    /// 本次会话 xray 用的 geo 数据目录（datDir）。startTunnel / reconfigure 里由
    /// resolveGeoData() 先行解析（App Group 完整版优先，否则内置 Resources），
    /// bringUpXray 直接用 —— compose（要 hasFullGeoIP）和 XrayCore.run（要 datDir）
    /// 必须口径一致，不能各查各的。
    var activeGeoDir: String?

    /// 调试：两个方向各打第一个 packet 的 log，方便确认流量真的在流。
    var loggedFirstApplePacket = false
    var loggedFirstXrayPacket = false

    /// 流量统计：两个拷贝循环在不同线程各自累加字节（上行在 readPackets 回调队列、
    /// 下行在 bridgeQueue），用 unfair lock 保护。定时器每秒算 delta 速率 + 写 App Group，
    /// 主 App 轮询读出来画波形 / 显示实时速率。
    struct ByteCounters {
        var up: Int64 = 0; var down: Int64 = 0; var lastUp: Int64 = 0; var lastDown: Int64 = 0
        var configurationWindow = TrafficConfigurationWindow()
    }
    let byteCounters = OSAllocatedUnfairLock(initialState: ByteCounters())
    var statsTimer: DispatchSourceTimer?
    /// 流量统计定时器**专用**串行队列。绝不能复用 bridgeQueue —— 那上面跑着
    /// runFdToWritePacketsLoop 的阻塞 read 死循环，定时器会被饿死、触发间隔远大于 1 秒，
    /// 于是几秒的字节增量被当成「每秒」速率，严重高估（实测下行飙到 ~9MB/s）。
    let statsQueue = DispatchQueue(label: "com.sbraveyoung.qingzhou.tunnel.stats")
    var lastReportAt: Date?

    /// 扩展内存观测（iOS 对 NE 扩展有 50 MiB phys_footprint 的 jetsam 硬上限，超限即"断流"）。
    /// 随 stats 定时器每秒采一次（一次 mach call，微秒级），写 App Group 给主 App 显示。
    /// 以下状态**只在 statsQueue 上碰**，无需加锁。峰值跨 reconfigure 延续（进程级观测）。
    var memSessionPeak: Int64 = 0
    var memAllTimePeak: Int64 = 0
    var memAllTimePeakLoaded = false   // 历史峰值只从上次落盘读一次
    var memWarningCount = 0
    var memInWarningZone = false       // 迟滞：越线记一次，回落 4MB 后再越才再计
    static let memWarnThreshold: Int64 = 40 * 1024 * 1024

    /// FakeDNS 映射「假 IP → 域名」。从 xray 发回 App 的 DNS 响应里解析出来（见 captureFakeDNS），
    /// 随 reportTrafficStats 一起写进 App Group，主 App 用它把 access log 的假 IP 翻回域名。
    let fakeDNSMap = OSAllocatedUnfairLock(initialState: [String: String]())

    /// xray 内置流量统计（stats/metrics）的 expvar 端口。bringUpXray 前向内核要一个
    /// 空闲端口传给 compose；拿不到（罕见）就 nil = 本会话不开统计，VPN 照常起。
    /// 只在 startTunnel / reconfigure / bringUpXray 的串行流程里写，statsQueue 上只读。
    var metricsPort: Int?
    let publicIPPort = OSAllocatedUnfairLock<Int?>(initialState: nil)
    /// 统计轮询节流：每 2 个 stats tick（≈2 秒）查一次 QueryStats，别每秒都 GET。
    var statsTickCount = 0
    // 月度域名账本只在statsQueue读写；主App不参与累加。
    var domainTrafficRecorder: DomainTrafficRecorder?
    var domainTrafficInitializationErrorLogged = false
    var domainTrafficRecordedAt = Date.distantPast

    /// 阻断 QUIC（reject UDP 443）。startTunnel 从 providerConfig 读一次存下来，
    /// reconfigure / performTest 从存的配置重组时也复用同一值 —— 否则切节点/预检后 QUIC 又放开了。
    /// 默认 true（缺字段/旧配置也阻断，QUIC 经代理普遍不通，见 XrayConfigComposer / docs/QUIC.md）。
    var blockQUIC = true

    /// 分流方案的两个节点：出口（住宅 SOCKS5）+ 跳板。nil = 未启用分流，走原有单节点路径。
    ///
    /// 存在这里是因为 reconfigure / performTest 需要在不重新读 providerConfiguration 的
    /// 情况下重建同一套配置；原地重配（reconfigure）在分流模式下会被**拒绝**（见下），
    /// 所以这份状态主要给配置预检和状态展示用。
    struct SplitExitNodes: Sendable {
        var exit: Node
        var hop: Node
    }
    let splitExitNodes = OSAllocatedUnfairLock(initialState: SplitExitNodes?.none)

    /// 断网开关的 root 中继。非 nil 时所有出站都经它（详见 SplitExitPlan.RelayEndpoint）。
    let guardRelay = OSAllocatedUnfairLock<SplitExitPlan.RelayEndpoint?>(initialState: nil)

    /// 分流方案用户自定义策略组。startTunnel 解码后存入供 composeSplitExit / performTest 复用。
    let splitExitPolicyGroups = OSAllocatedUnfairLock<[SplitExitPolicyGroup]>(initialState: [])

    // MARK: - 健康触发的故障切换（保守 MVP：检测 + 告警，首版**不自动切数据面**）

    /// 判死纯逻辑（QingzhouCore）。**只在 statsQueue 上碰**（随 reportXrayOutboundStats 喂样本），
    /// 无需加锁 —— 与 mem* 峰值同一线程纪律。切换后由 statsQueue 读到 needsBaselineReset 再重置。
    var healthDetector = NodeHealthDetector()
    /// 每节点上次发通知时刻（冷却用）。**只在 statsQueue 上碰**。
    var lastHealthNotifiedAt: [String: Date] = [:]
    /// 同一节点两条「疑似故障」通知的最小间隔（秒）。别刷屏。
    static let healthNotifyCooldown: TimeInterval = 300

    /// 跨队列的健康控制位：switchNode / reconfigure 在别的线程改，statsQueue 读。
    /// - isSwitching：切换窗口内所有信号会虚假触发（stop→start 计数跳变），硬 guard 跳过喂样本（F24）。
    /// - needsBaselineReset：切换成功后置位，statsQueue 下个 tick 消费 → detector.resetBaseline()（F5/F7）。
    /// - nodeName：当前节点名（健康信号 + 通知用），随 start/reconfigure/switch 更新。
    struct HealthControl { var isSwitching = false; var needsBaselineReset = false; var nodeName = "node"; var bandwidthConfigurationID: UUID? }
    let healthControl = OSAllocatedUnfairLock(initialState: HealthControl())

    /// 「经代理延迟」（pingNode）/「配置预检」（testNode）专用串行队列。
    /// - 串行 = 同一时刻至多一个短命 xray 实例在跑（NE 50MB 内存预算的硬要求）；
    /// - 独立队列 = ping 阻塞最长 timeout 秒，绝不能占 bridgeQueue（packet 拷贝）或
    ///   statsQueue（每秒统计定时器）。
    let probeQueue = DispatchQueue(label: "com.sbraveyoung.qingzhou.tunnel.probe", qos: .utility)

    /// 定时自动关闭（防忘关）：倒计时**必须**在扩展进程里跑 —— iOS 主 App 随时会被系统
    /// 回收，主 App 侧 Timer 靠不住。一次性 DispatchSourceTimer，内存开销可忽略（NE 50MB 预算）。
    /// 挂 statsQueue（轻量定时器专用队列，绝不能上 bridgeQueue —— 那里的阻塞 read 会饿死它）。
    /// 到点自停能成立的前提：启用定时的连接主 App 没开 On-Demand（见 VPNTunnelManager.configure），
    /// cancelTunnelWithError(nil) 后系统不会把隧道拉回来。
    var autoStopTimer: DispatchSourceTimer?
    /// 本次会话标记（写 App Group 给主 App 画倒计时用）。到点自停时回填 stoppedAt 再写一次。
    let sessionInfo = OSAllocatedUnfairLock(initialState: TunnelSessionInfo?.none)

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        os_log("startTunnel begin", log: log, type: .default)

        // 1) 从 providerConfiguration 读启动信息
        //    新路径：nodeJSON → 纯 Swift NodeConverter（XrayConfig 模块）→ xray outbounds
        //    fallback：shareLink → libXray.ConvertShareLinksToXrayJson
        //    fallback 留着是为了万一 NodeConverter 有覆盖不到的字段映射，至少能切回原路径，
        //    稳定一段时间后会移除 libXray.convertShareLinks 调用。
        let providerConfig = (self.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        let modeRaw = (providerConfig?["proxyMode"] as? String) ?? ProxyMode.global.rawValue
        let mode = ProxyMode(rawValue: modeRaw) ?? .global
        let nodeJSON = providerConfig?["nodeJSON"] as? String ?? ""
        let shareLink = providerConfig?["shareLink"] as? String ?? ""
        // 分流方案不需要 nodeJSON / shareLink：它的两个节点在 exitNodeJSON / hopNodeJSON 里。
        let splitExitRequested = ((providerConfig?["splitExit"] as? NSNumber)?.boolValue
            ?? (providerConfig?["splitExit"] as? Bool)) ?? false
        guard mode == .direct || splitExitRequested || !nodeJSON.isEmpty || !shareLink.isEmpty else {
            let err = NSError(
                domain: "com.sbraveyoung.qingzhou.tunnel",
                code: 1001,
                userInfo: [NSLocalizedDescriptionKey:
                    "providerConfiguration 里既没有 nodeJSON 也没有 shareLink。主 App 需要先用 VPNTunnelManager.configure(...) 保存配置。"]
            )
            os_log("missing nodeJSON/shareLink in providerConfiguration", log: log, type: .error)
            completionHandler(err)
            return
        }
        let nodeName = (providerConfig?["nodeName"] as? String) ?? "node"
        // 健康判死器：记住当前节点名（信号 + 通知用）；首采样自会建 baseline + 起 grace。
        healthControl.withLock { $0.nodeName = nodeName }
        // 定时自动关闭（秒，0/缺省 = 不启用）。plist 里的数字取回来是 NSNumber。
        let autoStopSeconds = (providerConfig?["autoStopSeconds"] as? NSNumber)?.doubleValue ?? 0
        // 阻断 QUIC（reject UDP 443）：缺字段/旧配置默认 true。存实例属性供 reconfigure/performTest 复用。
        self.blockQUIC = providerConfig?["blockQUIC"] as? Bool ?? true
        // 用户规则（自定义 + 远程）：内联压缩 Data，超大规则集降级为 App Group 文件路径
        let userRules = loadUserRules(
            inlineData: providerConfig?["userRulesGZ"] as? Data,
            base64: nil,
            path: providerConfig?["userRulesPath"] as? String
        )

        os_log("starting tunnel for node: %{public}@ mode=%{public}@ userRules=%d",
               log: log, type: .default, nodeName, mode.rawValue, userRules.count)

        // geo 数据源：App Group 完整版（主 App 下载）优先，否则内置精简版。
        // 必须在 compose **之前**定：hasFullGeoIP 决定外国 GEOIP 码规则是否透传。
        let geo = resolveGeoData()
        self.activeGeoDir = geo.dir

        // xray 内置流量统计的 expvar 端口（loopback）。拿不到就不开统计，绝不挡 VPN 启动。
        let diagnosticPorts = (try? XrayCore.getFreePorts(2)) ?? []
        self.metricsPort = diagnosticPorts.first
        publicIPPort.withLock { $0 = diagnosticPorts.count > 1 ? diagnosticPorts[1] : nil }

        // 转换 Node → outbounds JSON
        let xrayJSON: String
        do {
            // 分流方案优先：它自带完整 routing/dns，不吃 userRules（需求里规则顺序是固定的，
            // 让自定义规则插进去会破坏 first-match 的优先级保证）。
            let splitExit = try resolveSplitExit(providerConfig: providerConfig)
            splitExitNodes.withLock { $0 = splitExit }
            let policyGroups = splitExit != nil ? try resolveSplitExitPolicyGroups(providerConfig: providerConfig) : []
            splitExitPolicyGroups.withLock { $0 = policyGroups }
            // 中继凭据：解不出来就当没有（不至于因此起不了 VPN），但会打日志。
            let relayRaw = providerConfig?["guardRelayJSON"] as? String ?? ""
            let relay = GuardRelayCredentials.decode(relayRaw).map {
                SplitExitPlan.RelayEndpoint(host: $0.host, port: $0.port,
                                            username: $0.username, password: $0.password)
            }
            guardRelay.withLock { $0 = relay }
            if let relay {
                os_log("split-exit: 出站经 root 中继 127.0.0.1:%d", log: log, type: .default, Int(relay.port))
            }
            if let splitExit {
                os_log("startTunnel: split-exit 模式（出口 %{public}@ 经跳板 %{public}@）",
                       log: log, type: .default, splitExit.exit.name, splitExit.hop.name)
                xrayJSON = try composeSplitExit(splitExit,
                                                accessLogPath: TunnelAppGroup.accessLogPath(),
                                                tunInterfaceName: "utun")
            } else {
                let outboundsJSON = mode == .direct ? "{}" : try resolveOutboundsJSON(nodeJSON: nodeJSON, shareLink: shareLink)
                // accessLogPath() 内部会清空旧日志 + 验证容器可写；返回 nil 时 compose 不配 access，
                // VPN 照常起（只是没有连接日志）。让 xray 把连接日志写到 App Group，主 App 解析展示。
                xrayJSON = try XrayConfigComposer.compose(
                    outboundsJSON: outboundsJSON,
                    mode: mode,
                    accessLogPath: TunnelAppGroup.accessLogPath(),
                    userRules: userRules,
                    hasFullGeoIP: geo.isFull,
                    metricsPort: self.metricsPort,
                    publicIPPort: publicIPPort.withLock { $0 },
                    blockQUIC: self.blockQUIC
                )
            }
        } catch {
            os_log("share link → xray config 转换失败: %{public}@",
                   log: log, type: .error, error.localizedDescription)
            completionHandler(error)
            return
        }

        // 把生效的配置写进 App Group：主 App 的 enable.sh 靠「配置里有没有 relay 出站」
        // 来判断能否安全开启 pf 拦截。之前这个文件根本没人写（writeXrayConfig 是死代码），
        // enable.sh 的检查永远是失败的。
        TunnelAppGroup.writeXrayConfig(xrayJSON)

        // 2) 设置 TUN 网络参数
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.0.10.1"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4
        // ⚠️ 必须同时接管 IPv6，否则 iOS 上会「连上但打不开网页」（真机踩过，macOS 不明显）：
        // xray 的 FakeDNS 有 IPv6 假 IP 池（fc00::/18），AAAA 查询会返回 fc00:: 假地址。
        // iOS 蜂窝多为 IPv6 优先，App 于是去连这个假 IPv6 —— 但 TUN 只声明 IPv4 路由时，
        // 这个包不进隧道 → 泄漏到真实网络 / 黑洞 → 请求失败。声明 IPv6 默认路由后全栈接管，
        // 假 IPv6 也进隧道、由 xray 反查回域名代理出去。tun 自身地址取 fc00::/18 之外的 ULA。
        let ipv6 = NEIPv6Settings(addresses: ["fd00:c0de::1"], networkPrefixLengths: [64])
        ipv6.includedRoutes = [NEIPv6Route.default()]
        settings.ipv6Settings = ipv6
        let dns = NEDNSSettings(servers: ["8.8.8.8", "1.1.1.1"])
        dns.matchDomains = [""]
        settings.dnsSettings = dns
        settings.mtu = NSNumber(value: 1500)

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { return }
            if let error {
                os_log("setTunnelNetworkSettings failed: %{public}@", log: self.log, type: .error, error.localizedDescription)
                completionHandler(error)
                return
            }
            self.bringUpXray(configJSON: xrayJSON) { error in
                if error == nil {
                    // xray 真起来了才武装定时（并写会话标记给主 App 画倒计时）。
                    // 只在 startTunnel 路径武装 —— reconfigure（原地重配）不动定时，倒计时跨重配延续。
                    let applied = Self.appliedConfiguration(
                        nodeJSON: nodeJSON, mode: mode, blockQUIC: self.blockQUIC,
                        requestID: (providerConfig?["requestID"] as? String).flatMap(UUID.init(uuidString:)),
                        rulesDigest: AppliedTunnelConfiguration.digestRules(userRules))
                    self.sessionInfo.withLock { current in
                        current = TunnelSessionInfo(startedAt: Date(), autoStopSeconds: autoStopSeconds,
                            appliedConfiguration: applied, trafficSessionID: UUID().uuidString)
                        // 热切换后旧连接可能继续使用同名 proxy counter，不能将它们算给新节点。
                        self.healthControl.withLock { $0.bandwidthConfigurationID = applied?.id }
                    }
                    self.armAutoStop(seconds: autoStopSeconds)
                }
                completionHandler(error)
            }
        }
    }

    /// 决定本次会话用哪份 geo 数据：
    /// - App Group `xray-data/` 里有主 App 下载的完整版 geoip.dat，且与 geo-data-info.json
    ///   记录的字节数吻合（下载时已做过 sha256 全量校验，这里做廉价一致性检查即可）
    ///   → 用完整版目录（顺手把 bundle 的 geosite.dat 补进同目录 —— xray 的 datDir 是单一目录）；
    /// - 否则 → 内置 Resources 精简版。
    /// 任何一步不满足都安静回退，绝不让 geo 数据问题挡 VPN 启动。
    func resolveGeoData() -> (dir: String, isFull: Bool) {
        let bundleDir = Bundle.main.resourceURL?.path ?? NSTemporaryDirectory()
        let fallback = (dir: bundleDir, isFull: false)
        guard let workDir = TunnelAppGroup.ensureWorkingDirectory() else {
            os_log("geo: App Group 容器不可用 → 内置精简版", log: log, type: .default)
            return fallback
        }
        let fm = FileManager.default
        let datPath = workDir.appendingPathComponent("geoip.dat").path
        let infoURL = workDir.appendingPathComponent("geo-data-info.json")
        guard let infoData = try? Data(contentsOf: infoURL) else {
            os_log("geo: 未下载完整版 → 内置精简版 (%{public}@)", log: log, type: .default, bundleDir)
            return fallback
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601   // 与主 App GeoDataManager 的编码策略一致
        guard let info = try? decoder.decode(GeoDataInfo.self, from: infoData),
              let attrs = try? fm.attributesOfItem(atPath: datPath),
              (attrs[.size] as? NSNumber)?.int64Value == info.sizeBytes else {
            os_log("geo: 完整版 info/文件不一致（下载中断或被清理）→ 内置精简版", log: log, type: .error)
            return fallback
        }
        // xray 的 datDir 是单一目录：geosite.dat 也得在这。从 bundle 补拷（缺失或大小变了才拷，
        // ~4MB 不值得每次启动都写一遍）。拷失败就整体回退内置目录 —— 半套数据是 rule 模式启动失败。
        let bundleGeosite = bundleDir + "/geosite.dat"
        let workGeosite = workDir.appendingPathComponent("geosite.dat").path
        let bundleSize = (try? fm.attributesOfItem(atPath: bundleGeosite))?[.size] as? NSNumber
        let workSize = (try? fm.attributesOfItem(atPath: workGeosite))?[.size] as? NSNumber
        if bundleSize != workSize {
            try? fm.removeItem(atPath: workGeosite)
            do {
                try fm.copyItem(atPath: bundleGeosite, toPath: workGeosite)
            } catch {
                os_log("geo: geosite.dat 补拷失败（%{public}@）→ 内置精简版", log: log, type: .error,
                       error.localizedDescription)
                return fallback
            }
        }
        os_log("geo: 使用 App Group 完整版（来源 %{public}@，%lld 字节，%{public}@）",
               log: log, type: .default, info.sourceName, info.sizeBytes, workDir.path)
        return (dir: workDir.path, isFull: true)
    }

    func bringUpXray(configJSON: String, completionHandler: @escaping (Error?) -> Void) {
        os_log("bringUpXray: config bytes=%d", log: log, type: .default, configJSON.utf8.count)

        // 3) 建 socketpair —— xray 端当 TUN fd 给 libXray
        guard let pair = makeSocketPair() else {
            let err = NSError(
                domain: "com.sbraveyoung.qingzhou.tunnel",
                code: 1003,
                userInfo: [NSLocalizedDescriptionKey: "socketpair() 失败：errno=\(errno)"]
            )
            os_log("socketpair failed: errno=%d", log: log, type: .error, errno)
            completionHandler(err)
            return
        }
        self.tunPair = pair
        os_log("socketpair ready: swift_fd=%d xray_fd=%d", log: log, type: .default, pair.swift, pair.xray)

        // 4) 起两个方向的拷贝循环（在 xray-core 启动前就 arm 好，免得初始 packet 丢）
        self.bridgeActive = true
        self.loggedFirstApplePacket = false
        self.loggedFirstXrayPacket = false
        self.startReadPacketsToFd(swiftFd: pair.swift)
        self.bridgeQueue.async { [weak self] in
            self?.runFdToWritePacketsLoop(swiftFd: pair.swift)
        }

        // 5) 准备 xray 工作路径。activeGeoDir 由 startTunnel / reconfigure 先行解析
        //（App Group 完整版优先）；兜底走内置 Resources。
        let geoDir = activeGeoDir ?? Bundle.main.resourceURL?.path ?? NSTemporaryDirectory()
        let cachesURL = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        // mph 缓存：新版 libXray（#132 后）已整体移除该机制 —— 我们本来也没用
        //（老机制 build/load 对不上，run 时报 "matcher not found"）。xray 在内存里
        // 实时构建 geosite/geoip matcher（rule 模式启动多几百毫秒，可接受）。

        let fm = FileManager.default
        let geoipPath = geoDir + "/geoip.dat"
        let geositePath = geoDir + "/geosite.dat"
        let hasGeoip = fm.fileExists(atPath: geoipPath)
        let hasGeosite = fm.fileExists(atPath: geositePath)
        os_log("geoDir=%{public}@ geoip=%{public}@ geosite=%{public}@",
               log: log, type: .default,
               geoDir,
               hasGeoip ? "OK" : "MISSING",
               hasGeosite ? "OK" : "MISSING")
        if !hasGeoip || !hasGeosite {
            os_log("WARNING: geo files missing — rule mode 会失败，global mode 应当还能跑（已不依赖 geoip）", log: log, type: .error)
        }

        // 6) 启动 xray-core，给 socketpair 的另一端当 TUN fd
        os_log("calling XrayCore.setTunFd + run …", log: log, type: .default)
        XrayCore.setTunFd(pair.xray)
        do {
            try XrayCore.run(configJSON: configJSON, geoDir: geoDir)
            os_log("✅ xray-core started OK (version %{public}@)", log: log, type: .default, XrayCore.version)
            startStatsReporting()
            completionHandler(nil)
        } catch {
            os_log("❌ XrayCore.run failed: %{public}@", log: log, type: .error, error.localizedDescription)
            let dumpURL = cachesURL.appendingPathComponent("xray-config-dump.json")
            try? configJSON.write(to: dumpURL, atomically: true, encoding: .utf8)
            os_log("dumped failing config to %{public}@", log: log, type: .default, dumpURL.path)
            self.tearDownBridge()
            completionHandler(error)
        }
    }

    // MARK: - Node → xray outbounds JSON 双路径

    /// 优先走纯 Swift `NodeConverter`，失败时（解码 / 转换出错或本来就没 nodeJSON）退回 libXray。
    /// 当前是 S3 Phase 2 的过渡期 —— 稳定一段时间后会移除 libXray 那条路径。
    func resolveOutboundsJSON(nodeJSON: String, shareLink: String) throws -> String {
        // Path A: Swift NodeConverter
        if !nodeJSON.isEmpty,
           let data = nodeJSON.data(using: .utf8) {
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let node = try decoder.decode(Node.self, from: data)
                let result = try NodeConverter.toOutboundsJSON(node)
                os_log("✅ outbounds via Swift NodeConverter (protocol=%{public}@)",
                       log: log, type: .default, node.protocolType.rawValue)
                return result
            } catch {
                os_log("⚠️ NodeConverter 失败 (%{public}@)，退回 libXray.convertShareLinks",
                       log: log, type: .error, error.localizedDescription)
                // fall through
            }
        }
        // Path B: libXray.convertShareLinks
        if !shareLink.isEmpty {
            let result = try XrayCore.convertShareLinks(shareLink)
            os_log("✅ outbounds via libXray.convertShareLinks (fallback)",
                   log: log, type: .default)
            return result
        }
        throw NSError(
            domain: "com.sbraveyoung.qingzhou.tunnel",
            code: 1004,
            userInfo: [NSLocalizedDescriptionKey:
                "两条路径都失败：nodeJSON 解析失败且 shareLink 为空"]
        )
    }

    /// 解出主 App 传来的用户规则。三个来源按序尝试：内联 Data（providerConfiguration）、
    /// base64 字符串（sendProviderMessage 的 JSON 消息体）、App Group 文件路径（超大规则集）。
    /// 解不出来 → 空规则集 + 打日志 —— 规则只是分流增强，绝不能因为它 VPN 起不来。
    func loadUserRules(inlineData: Data?, base64: String?, path: String?) -> [Rule] {
        var data = inlineData
        if data == nil, let base64, !base64.isEmpty {
            data = Data(base64Encoded: base64)
        }
        if data == nil, let path, !path.isEmpty {
            data = FileManager.default.contents(atPath: path)
        }
        guard let data else { return [] }
        do {
            return try RulesTransport.decode(data)
        } catch {
            os_log("⚠️ decode user rules failed (%{public}@) — falling back to built-in rules only",
                   log: log, type: .error, error.localizedDescription)
            return []
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        os_log("stopTunnel reason=%d", log: log, type: .default, reason.rawValue)
        autoStopTimer?.cancel()
        autoStopTimer = nil
        _ = XrayCore.stop()
        tearDownBridge()
        completionHandler()
    }

    static func appliedConfiguration(nodeJSON: String, mode: ProxyMode,
                                     blockQUIC: Bool, requestID: UUID? = nil,
                                     rulesDigest: String? = nil) -> AppliedTunnelConfiguration? {
        if mode == .direct {
            return AppliedTunnelConfiguration(directRequestID: requestID, rulesDigest: rulesDigest)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = nodeJSON.data(using: .utf8), let node = try? decoder.decode(Node.self, from: data) else {
            return nil  // 旧shareLink-only路径无法确定Node身份，明确保留未知。
        }
        return AppliedTunnelConfiguration(node: node, mode: mode, blockQUIC: blockQUIC, requestID: requestID,
            rulesDigest: rulesDigest)
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        handleControlMessage(messageData, completionHandler: completionHandler)
    }

    override func sleep(completionHandler: @escaping () -> Void) { completionHandler() }
    override func wake() { }
}
