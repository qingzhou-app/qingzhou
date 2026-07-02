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
import XrayConfig
import XrayCore

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let log = OSLog(subsystem: "com.sbraveyoung.qingzhou.tunnel", category: "PacketTunnel")

    /// (Swift 持的一端, libXray 持的一端)。stopTunnel 时只 close swift 端；
    /// xray 端由 XrayCore.stop() 内部 close。
    private var tunPair: (swift: Int32, xray: Int32)?
    private let bridgeQueue = DispatchQueue(label: "com.sbraveyoung.qingzhou.tunnel.bridge", qos: .userInitiated)

    /// 控制两个方向拷贝循环是否继续。stopTunnel 时设 false。读写竞争一两个 packet 无所谓。
    private var bridgeActive = false

    /// 本次会话 xray 用的 geo 数据目录（datDir）。startTunnel / reconfigure 里由
    /// resolveGeoData() 先行解析（App Group 完整版优先，否则内置 Resources），
    /// bringUpXray 直接用 —— compose（要 hasFullGeoIP）和 XrayCore.run（要 datDir）
    /// 必须口径一致，不能各查各的。
    private var activeGeoDir: String?

    /// 调试：两个方向各打第一个 packet 的 log，方便确认流量真的在流。
    private var loggedFirstApplePacket = false
    private var loggedFirstXrayPacket = false

    /// 流量统计：两个拷贝循环在不同线程各自累加字节（上行在 readPackets 回调队列、
    /// 下行在 bridgeQueue），用 unfair lock 保护。定时器每秒算 delta 速率 + 写 App Group，
    /// 主 App 轮询读出来画波形 / 显示实时速率。
    private struct ByteCounters { var up: Int64 = 0; var down: Int64 = 0; var lastUp: Int64 = 0; var lastDown: Int64 = 0 }
    private let byteCounters = OSAllocatedUnfairLock(initialState: ByteCounters())
    private var statsTimer: DispatchSourceTimer?
    /// 流量统计定时器**专用**串行队列。绝不能复用 bridgeQueue —— 那上面跑着
    /// runFdToWritePacketsLoop 的阻塞 read 死循环，定时器会被饿死、触发间隔远大于 1 秒，
    /// 于是几秒的字节增量被当成「每秒」速率，严重高估（实测下行飙到 ~9MB/s）。
    private let statsQueue = DispatchQueue(label: "com.sbraveyoung.qingzhou.tunnel.stats")
    private var lastReportAt: Date?

    /// 扩展内存观测（iOS 对 NE 扩展有 50 MiB phys_footprint 的 jetsam 硬上限，超限即"断流"）。
    /// 随 stats 定时器每秒采一次（一次 mach call，微秒级），写 App Group 给主 App 显示。
    /// 以下状态**只在 statsQueue 上碰**，无需加锁。峰值跨 reconfigure 延续（进程级观测）。
    private var memSessionPeak: Int64 = 0
    private var memAllTimePeak: Int64 = 0
    private var memAllTimePeakLoaded = false   // 历史峰值只从上次落盘读一次
    private var memWarningCount = 0
    private var memInWarningZone = false       // 迟滞：越线记一次，回落 4MB 后再越才再计
    private static let memWarnThreshold: Int64 = 40 * 1024 * 1024

    /// FakeDNS 映射「假 IP → 域名」。从 xray 发回 App 的 DNS 响应里解析出来（见 captureFakeDNS），
    /// 随 reportTrafficStats 一起写进 App Group，主 App 用它把 access log 的假 IP 翻回域名。
    private let fakeDNSMap = OSAllocatedUnfairLock(initialState: [String: String]())

    /// xray 内置流量统计（stats/metrics）的 expvar 端口。bringUpXray 前向内核要一个
    /// 空闲端口传给 compose；拿不到（罕见）就 nil = 本会话不开统计，VPN 照常起。
    /// 只在 startTunnel / reconfigure / bringUpXray 的串行流程里写，statsQueue 上只读。
    private var metricsPort: Int?
    /// 统计轮询节流：每 2 个 stats tick（≈2 秒）查一次 QueryStats，别每秒都 GET。
    private var statsTickCount = 0

    /// 「经代理延迟」（pingNode）/「配置预检」（testNode）专用串行队列。
    /// - 串行 = 同一时刻至多一个短命 xray 实例在跑（NE 50MB 内存预算的硬要求）；
    /// - 独立队列 = ping 阻塞最长 timeout 秒，绝不能占 bridgeQueue（packet 拷贝）或
    ///   statsQueue（每秒统计定时器）。
    private let probeQueue = DispatchQueue(label: "com.sbraveyoung.qingzhou.tunnel.probe", qos: .utility)

    /// 定时自动关闭（防忘关）：倒计时**必须**在扩展进程里跑 —— iOS 主 App 随时会被系统
    /// 回收，主 App 侧 Timer 靠不住。一次性 DispatchSourceTimer，内存开销可忽略（NE 50MB 预算）。
    /// 挂 statsQueue（轻量定时器专用队列，绝不能上 bridgeQueue —— 那里的阻塞 read 会饿死它）。
    /// 到点自停能成立的前提：启用定时的连接主 App 没开 On-Demand（见 VPNTunnelManager.configure），
    /// cancelTunnelWithError(nil) 后系统不会把隧道拉回来。
    private var autoStopTimer: DispatchSourceTimer?
    /// 本次会话标记（写 App Group 给主 App 画倒计时用）。到点自停时回填 stoppedAt 再写一次。
    private var sessionInfo: TunnelSessionInfo?

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
        let nodeJSON = providerConfig?["nodeJSON"] as? String ?? ""
        let shareLink = providerConfig?["shareLink"] as? String ?? ""
        guard !nodeJSON.isEmpty || !shareLink.isEmpty else {
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
        let modeRaw = (providerConfig?["proxyMode"] as? String) ?? ProxyMode.global.rawValue
        let mode = ProxyMode(rawValue: modeRaw) ?? .global
        // 定时自动关闭（秒，0/缺省 = 不启用）。plist 里的数字取回来是 NSNumber。
        let autoStopSeconds = (providerConfig?["autoStopSeconds"] as? NSNumber)?.doubleValue ?? 0
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
        self.metricsPort = (try? XrayCore.getFreePorts(1))?.first

        // 转换 Node → outbounds JSON
        let xrayJSON: String
        do {
            let outboundsJSON = try resolveOutboundsJSON(nodeJSON: nodeJSON, shareLink: shareLink)
            // accessLogPath() 内部会清空旧日志 + 验证容器可写；返回 nil 时 compose 不配 access，
            // VPN 照常起（只是没有连接日志）。让 xray 把连接日志写到 App Group，主 App 解析展示。
            xrayJSON = try XrayConfigComposer.compose(
                outboundsJSON: outboundsJSON,
                mode: mode,
                accessLogPath: TunnelAppGroup.accessLogPath(),
                userRules: userRules,
                hasFullGeoIP: geo.isFull,
                metricsPort: self.metricsPort
            )
        } catch {
            os_log("share link → xray config 转换失败: %{public}@",
                   log: log, type: .error, error.localizedDescription)
            completionHandler(error)
            return
        }

        // 2) 设置 TUN 网络参数
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.0.10.1"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4
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
    private func resolveGeoData() -> (dir: String, isFull: Bool) {
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

    private func bringUpXray(configJSON: String, completionHandler: @escaping (Error?) -> Void) {
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
        // mph 缓存路径**故意留空** —— libXray 的 mph 缓存 build/load 机制对不上
        //（建好后 run 时报 "matcher not found"）。空路径时 xray 在内存里实时构建
        // geosite/geoip matcher（rule 模式启动多几百毫秒，可接受），不依赖缓存文件，稳。
        let mphCache = ""

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
            try XrayCore.run(configJSON: configJSON, geoDir: geoDir, mphCachePath: mphCache)
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
    private func resolveOutboundsJSON(nodeJSON: String, shareLink: String) throws -> String {
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
    private func loadUserRules(inlineData: Data?, base64: String?, path: String?) -> [Rule] {
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

    // MARK: - socketpair TUN bridge (iOS 26 必备)

    /// 建一对 AF_UNIX SOCK_DGRAM socket fd。SOCK_DGRAM 保消息边界 —— 每次 write 一个 packet，
    /// 对端每次 read 拿到完整一个 packet，不用自己做 length-prefix 之类的 framing。
    private func makeSocketPair() -> (swift: Int32, xray: Int32)? {
        var fds: [Int32] = [-1, -1]
        let r = fds.withUnsafeMutableBufferPointer { bp -> Int32 in
            socketpair(AF_UNIX, SOCK_DGRAM, 0, bp.baseAddress)
        }
        guard r == 0 else { return nil }

        // 默认 socketpair buffer 比较小（几 KB），跑流量时容易 drop。设到 256 KB 给点余量，
        // 又不至于在 NE 50 MB 内存限制下吃太多。
        var size: Int32 = 256 * 1024
        let sz = socklen_t(MemoryLayout<Int32>.size)
        for fd in fds {
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, sz)
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, sz)
        }
        return (swift: fds[0], xray: fds[1])
    }

    /// packetFlow → swiftFd 方向。Apple 的 readPackets handler 每次给一批 packet：
    /// 加 4 字节大端 protocol family 头（utun 格式），write 到 swift 端，handler 末尾重新 arm。
    private func startReadPacketsToFd(swiftFd: Int32) {
        self.packetFlow.readPackets { [weak self] packets, protocols in
            guard let self else { return }
            var batchUp = 0
            for i in 0..<packets.count {
                let proto = UInt32(truncating: protocols[i])
                var frame = Data(capacity: 4 + packets[i].count)
                var protoBE = proto.bigEndian
                withUnsafeBytes(of: &protoBE) { frame.append(contentsOf: $0) }
                frame.append(packets[i])
                _ = frame.withUnsafeBytes { ptr -> Int in
                    write(swiftFd, ptr.baseAddress, ptr.count)
                }
                batchUp += packets[i].count
            }
            let total = Int64(batchUp)   // 固化成 let，withLock 闭包不能捕获可变的 batchUp
            self.byteCounters.withLock { $0.up += total }
            if !self.loggedFirstApplePacket && !packets.isEmpty {
                self.loggedFirstApplePacket = true
                os_log("✅ first Apple→Xray batch: %d packets, first %d bytes, proto=%d",
                       log: self.log, type: .default,
                       packets.count, packets[0].count, Int(truncating: protocols[0]))
            }
            // 仅当仍是**当前**那对 socketpair 时才重挂 —— 原地重配换了新 fd 后，
            // 上一代 readPackets 的残留回调不会误挂到旧 fd（否则会出现两条 readPackets 链）。
            if self.bridgeActive, self.tunPair?.swift == swiftFd {
                self.startReadPacketsToFd(swiftFd: swiftFd)
            }
        }
    }

    /// swiftFd → packetFlow 方向。在 bridgeQueue 上跑阻塞 read 循环，
    /// 把 xray 写来的 utun 帧（4 字节大端 protocol + IP packet）拆开后调 writePackets。
    private func runFdToWritePacketsLoop(swiftFd: Int32) {
        var buf = [UInt8](repeating: 0, count: 65536)
        while self.bridgeActive {
            let n = buf.withUnsafeMutableBufferPointer { bp -> Int in
                read(swiftFd, bp.baseAddress, bp.count)
            }
            if n <= 0 {
                os_log("Xray→Apple loop exit: read=%d errno=%d",
                       log: log, type: .default, Int32(n), errno)
                break
            }
            if n < 5 {
                continue
            }
            let proto: UInt32 =
                (UInt32(buf[0]) << 24) |
                (UInt32(buf[1]) << 16) |
                (UInt32(buf[2]) << 8) |
                 UInt32(buf[3])
            let packet = Data(buf[4..<Int(n)])
            self.byteCounters.withLock { $0.down += Int64(n - 4) }
            self.captureFakeDNS(packet)

            if !loggedFirstXrayPacket {
                loggedFirstXrayPacket = true
                os_log("✅ first Xray→Apple packet: total=%d proto=%d ip_first_byte=0x%02x",
                       log: log, type: .default,
                       Int32(n), proto, buf[4])
            }

            self.packetFlow.writePackets([packet], withProtocols: [NSNumber(value: proto)])
        }
    }

    private func tearDownBridge() {
        bridgeActive = false
        statsTimer?.cancel()
        statsTimer = nil
        if let pair = tunPair {
            close(pair.swift)
            // xray 端由 XrayCore.stop() 关，避免双 close
            tunPair = nil
        }
    }

    // MARK: - 定时自动关闭（防忘关）

    /// 武装 / 重设 / 取消定时（seconds <= 0 = 取消）。startTunnel 成功后与
    /// handleAppMessage("setAutoStop") 都走这里：从**现在**起计时，写会话标记给主 App。
    private func armAutoStop(seconds: TimeInterval) {
        autoStopTimer?.cancel()
        autoStopTimer = nil
        // 始终写会话标记（含 0）—— 覆盖上一次会话的残留，主 App 才不会拿旧 deadline 画倒计时
        let info = TunnelSessionInfo(startedAt: Date(), autoStopSeconds: max(0, seconds))
        sessionInfo = info
        writeSessionInfo(info)
        guard seconds > 0 else {
            os_log("auto-stop disarmed", log: log, type: .default)
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: statsQueue)
        // leeway 给 30s：到点精度不重要（分钟级功能），让系统合并唤醒省电
        timer.schedule(deadline: .now() + seconds, leeway: .seconds(30))
        timer.setEventHandler { [weak self] in self?.performAutoStop() }
        timer.resume()
        autoStopTimer = timer
        os_log("auto-stop armed: %.0f s", log: log, type: .default, seconds)
    }

    /// 到点自停。顺序讲究：
    /// 1. 先把 stoppedAt 落盘 —— 哪怕随后进程立刻被回收，主 App 也能识别「按定时断开」；
    /// 2. 停 xray + 拆桥（cancelTunnelWithError 之后系统**不会**再调 stopTunnel，得自己收尾；
    ///    就算个别系统版本会调，XrayCore.stop / tearDownBridge 都幂等，双跑无害）；
    /// 3. cancelTunnelWithError(nil) —— NE 惯例的扩展自停路径：系统随即断开隧道、
    ///    系统 UI 的 VPN 图标同步消失。On-Demand 没开（主 App configure 时约定），不会被拉回。
    private func performAutoStop() {
        os_log("auto-stop fired — stopping tunnel", log: log, type: .default)
        if var info = sessionInfo {
            info.stoppedAt = Date()
            sessionInfo = info
            writeSessionInfo(info)
        }
        _ = XrayCore.stop()
        tearDownBridge()
        cancelTunnelWithError(nil)
    }

    /// 会话标记 → App Group（ISO8601，与主 App AppGroupStorage 的解码策略一致）。
    private func writeSessionInfo(_ info: TunnelSessionInfo) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(info),
              let json = String(data: data, encoding: .utf8) else { return }
        TunnelAppGroup.writeTunnelSession(json)
    }

    // MARK: - 流量统计上报

    /// xray 起来后调：在独立队列上每秒算一次速率并写进 App Group。
    private func startStatsReporting() {
        lastReportAt = Date()
        let timer = DispatchSource.makeTimerSource(queue: statsQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.reportTrafficStats() }
        timer.resume()
        statsTimer = timer
    }

    private func reportTrafficStats() {
        let now = Date()
        let elapsed = lastReportAt.map { now.timeIntervalSince($0) } ?? 1
        lastReportAt = now
        let snap = byteCounters.withLock { c -> (up: Int64, down: Int64, dUp: Int64, dDown: Int64) in
            let dUp = c.up - c.lastUp
            let dDown = c.down - c.lastDown
            c.lastUp = c.up
            c.lastDown = c.down
            return (c.up, c.down, dUp, dDown)
        }
        // 速率 = 字节增量 ÷ **实际**经过秒数（不假设定时器精确 1 秒，抗漂移/饿死）
        let secs = elapsed > 0.01 ? elapsed : 1
        let stats = TrafficStats(
            uploadBytes: snap.up,
            downloadBytes: snap.down,
            uploadSpeedBps: Int64(Double(max(0, snap.dUp)) / secs),
            downloadSpeedBps: Int64(Double(max(0, snap.dDown)) / secs),
            activeConnections: 0,   // access log 接入后填真实连接数（a 的下一支线）
            sampledAt: now
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601   // 跟主 App AppGroupStorage.read 的解码策略一致
        if let data = try? encoder.encode(stats), let json = String(data: data, encoding: .utf8) {
            TunnelAppGroup.writeTrafficStats(json)
        }
        // 顺便把 FakeDNS 映射（假 IP → 域名）写出去，主 App 用它把连接列表的假 IP 翻回域名
        let map = fakeDNSMap.withLock { $0 }
        if !map.isEmpty, let mData = try? JSONEncoder().encode(map),
           let mJSON = String(data: mData, encoding: .utf8) {
            TunnelAppGroup.writeFakeDNSMap(mJSON)
        }
        // 内存观测顺带跑（同在 statsQueue，一次 mach call）—— 50MB jetsam 线的哨兵
        reportMemoryStats(at: now)
        // xray 内置 per-outbound 统计：每 2 tick（≈2 秒）查一次（进程内 loopback HTTP GET，
        // 微秒级；节流只是不想每秒都序列化一遍 expvar 的 memstats 大 JSON）
        statsTickCount += 1
        if statsTickCount % 2 == 0 {
            reportXrayOutboundStats(at: now)
        }
    }

    /// QueryStats（metrics expvar）→ per-outbound 计数 → App Group。statsQueue 上跑。
    /// 任何一步失败都静默跳过 —— 统计是增量观测，绝不影响 VPN 本体。
    private func reportXrayOutboundStats(at now: Date) {
        guard let port = metricsPort else { return }
        guard let expvar = try? XrayCore.queryStats(metricsPort: port) else { return }
        let parsed = XrayCore.parseOutboundStats(expvar)
        guard !parsed.isEmpty else { return }
        var stats = XrayOutboundStats(sampledAt: now)
        for (tag, c) in parsed {
            stats.outbounds[tag] = XrayOutboundStats.Counter(uplinkBytes: c.uplink, downlinkBytes: c.downlink)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601   // 与主 App AppGroupStorage.read 的解码策略一致
        if let data = try? encoder.encode(stats), let json = String(data: data, encoding: .utf8) {
            TunnelAppGroup.writeXrayStats(json)
        }
    }

    /// 内存采样 + 上报（statsQueue 上跑）。
    /// 先量化再优化：footprint（jetsam 判定依据）、会话峰值、跨会话历史峰值、40MB 预警。
    ///
    /// **采样失败也每秒写记录（带 error 字段）** —— 验收 #17-iOS 教训：静默跳过写入后，
    /// Mac 上读不到 iPhone 容器，失败原因只能靠猜。现在诊断区直接显示 error，一张截图定位。
    /// iOS 兜底：task_vm_info 拿不到时用 os_proc_available_memory 反推
    /// （50MB 上限 − 剩余 = 已用 —— 这本来就是 Apple 给扩展的 jetsam 余量 API）。
    private func reportMemoryStats(at now: Date) {
        let sample = MemoryFootprint.sampleFootprint()
        let available = MemoryFootprint.availableMemory()
        var footprint = sample.bytes
        var note = sample.error
        if footprint == nil, let avail = available, MemoryFootprint.platformLimitBytes > 0 {
            footprint = max(0, MemoryFootprint.platformLimitBytes - avail)
            note = "\(sample.error ?? "task_vm_info 失败")；footprint 已由 os_proc_available_memory 反推"
        }

        // 历史最高峰值跨会话延续：第一次上报时从上次落盘的 memory-stats 读回来接着比。
        // 用途：用户报「断流」时，看历史峰值是否顶到过 50MB —— 有据可查。
        if !memAllTimePeakLoaded {
            memAllTimePeakLoaded = true
            if let json = TunnelAppGroup.readMemoryStatsJSON(),
               let data = json.data(using: .utf8) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                if let prev = try? decoder.decode(TunnelMemoryStats.self, from: data) {
                    memAllTimePeak = prev.allTimePeakBytes
                }
            }
        }
        if let fp = footprint {
            memSessionPeak = max(memSessionPeak, fp)
            memAllTimePeak = max(memAllTimePeak, memSessionPeak)

            // 接近上限预警（40MB，距 jetsam 线还剩 10MB）。带 4MB 迟滞：越线只记一次，
            // 回落到 36MB 以下才重新武装 —— 避免在阈值附近抖动时每秒刷一条日志。
            // **只在有硬上限的平台（iOS）武装**：macOS 无 jetsam 线、扩展常态就 60MB+，
            // 在那儿告警是纯噪声（本机实测装上第一秒就误报了一次）。
            if MemoryFootprint.platformLimitBytes > 0 {
                if fp >= Self.memWarnThreshold {
                    if !memInWarningZone {
                        memInWarningZone = true
                        memWarningCount += 1
                        os_log("⚠️ memory footprint %lld MB ≥ 40 MB warn threshold (iOS jetsam limit 50 MB), warning #%d this session",
                               log: log, type: .error, fp / (1024 * 1024), memWarningCount)
                    }
                } else if fp < Self.memWarnThreshold - 4 * 1024 * 1024 {
                    memInWarningZone = false
                }
            }
        }

        let stats = TunnelMemoryStats(
            footprintBytes: footprint ?? 0,   // 0 + error 字段 = 「采样失败」，UI 不会当真实值显示
            availableBytes: available,
            sessionPeakBytes: memSessionPeak,
            allTimePeakBytes: memAllTimePeak,
            limitBytes: MemoryFootprint.platformLimitBytes,
            warningCount: memWarningCount,
            error: note,
            sampledAt: now
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601   // 与主 App AppGroupStorage.read 的解码策略一致
        if let data = try? encoder.encode(stats), let json = String(data: data, encoding: .utf8) {
            TunnelAppGroup.writeMemoryStats(json)
        }
    }

    /// 从 xray 发回 App 的下行包里，把 DNS 响应解析成「假 IP → 域名」映射并累积。
    private func captureFakeDNS(_ packet: Data) {
        let maps = FakeDNSResolver.mappingsFromIPPacket([UInt8](packet))
        guard !maps.isEmpty else { return }
        fakeDNSMap.withLock { dict in
            for m in maps { dict[m.ip] = m.domain }
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

    /// 原地重配：不动 TUN / VPN 会话，只用新配置重启 xray + socketpair 桥。
    /// 由主 App 的 sendProviderMessage 触发，实现切模式 / 切节点的无感切换。
    /// 安全设计：
    ///  - 新配置**构建失败**时直接回错、**不拆旧 xray** —— 旧连接照跑，网络不受影响；
    ///  - xray 起不来时 bringUpXray 会自己 tearDown 并回错误，主 App 收到后回退到全量重启。
    private func reconfigure(nodeJSON: String, shareLink: String, mode: ProxyMode,
                             nodeName: String, userRules: [Rule],
                             reply: @escaping (Error?) -> Void) {
        os_log("reconfigure → node=%{public}@ mode=%{public}@ userRules=%d",
               log: log, type: .default, nodeName, mode.rawValue, userRules.count)
        // 重配也重新解析 geo：可能刚下载完完整版（下载成功触发的热切换就是走这条链路的全量重启，
        // 但保留原地重配路径的正确性 —— 一旦重新启用不至于用错数据）。
        let geo = resolveGeoData()
        self.activeGeoDir = geo.dir
        // 重配 = 新 xray 实例，metrics 端口重新要一个（旧实例可能还没放掉旧端口）。
        self.metricsPort = (try? XrayCore.getFreePorts(1))?.first
        let xrayJSON: String
        do {
            let outboundsJSON = try resolveOutboundsJSON(nodeJSON: nodeJSON, shareLink: shareLink)
            xrayJSON = try XrayConfigComposer.compose(
                outboundsJSON: outboundsJSON,
                mode: mode,
                accessLogPath: TunnelAppGroup.accessLogPath(),
                userRules: userRules,
                hasFullGeoIP: geo.isFull,
                metricsPort: self.metricsPort
            )
        } catch {
            os_log("reconfigure: build config failed, keep old xray: %{public}@",
                   log: log, type: .error, error.localizedDescription)
            reply(error)   // 旧 xray 照跑，网络不受影响
            return
        }
        _ = XrayCore.stop()
        tearDownBridge()
        bringUpXray(configJSON: xrayJSON, completionHandler: reply)
    }

    // MARK: - 经代理延迟（pingNode）/ 配置预检（testNode）—— probeQueue 上串行跑

    /// 「经代理延迟」：给节点起一个临时 xray 实例（socks inbound + 该节点 outbound），
    /// 真实走节点发一次 HTTP HEAD，返回全链路毫秒数。
    /// 与主 App 的直连 TCP 探测是两个维度 —— 这里量的是「本机→节点→目标」代理链路。
    /// probeQueue 串行保证同一时刻至多一个临时实例（NE 50MB 内存预算）。
    private func performPing(nodeJSON: String, url: String, timeoutSeconds: Int) -> Result<Int, Swift.Error> {
        // 内存余量护栏：iOS 上 footprint 已逼近 jetsam 线时拒绝再起临时实例 ——
        // 测个延迟把隧道整个搞断划不来。macOS 无硬上限（platformLimitBytes = 0），不拦。
        if MemoryFootprint.platformLimitBytes > 0,
           let fp = MemoryFootprint.currentFootprint(),
           fp > 38 * 1024 * 1024 {
            return .failure(NSError(
                domain: "com.sbraveyoung.qingzhou.tunnel", code: 1005,
                userInfo: [NSLocalizedDescriptionKey: "扩展内存余量不足（\(fp / 1024 / 1024)MB/50MB），暂缓经代理测速"]))
        }
        do {
            guard let data = nodeJSON.data(using: .utf8) else {
                throw NSError(domain: "com.sbraveyoung.qingzhou.tunnel", code: 1006,
                              userInfo: [NSLocalizedDescriptionKey: "nodeJSON 为空"])
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let node = try decoder.decode(Node.self, from: data)
            let outbound = try NodeConverter.toOutboundDict(node)
            guard let port = try XrayCore.getFreePorts(1).first else {
                throw NSError(domain: "com.sbraveyoung.qingzhou.tunnel", code: 1007,
                              userInfo: [NSLocalizedDescriptionKey: "拿不到空闲端口"])
            }
            // 极简 ping 配置：socks in + 节点 out，无 routing / dns / geo —— 临时实例
            // 不加载 geo 数据，起得快（<100ms）、内存占用最小。Go http client 经 socks5
            // 把域名透传给 xray，由节点侧解析，无需本地 DNS。
            let config: [String: Any] = [
                "log": ["loglevel": "warning"],
                "inbounds": [[
                    "tag": "ping-in",
                    "protocol": "socks",
                    "listen": "127.0.0.1",
                    "port": port,
                    "settings": ["udp": false] as [String: Any]
                ] as [String: Any]],
                "outbounds": [outbound]
            ]
            let configJSON = String(
                data: try JSONSerialization.data(withJSONObject: config),
                encoding: .utf8) ?? "{}"
            let ms = try XrayCore.ping(
                configJSON: configJSON,
                socksPort: port,
                url: url,
                timeoutSeconds: timeoutSeconds,
                datDir: activeGeoDir ?? ""
            )
            return .success(ms)
        } catch {
            return .failure(error)
        }
    }

    /// 配置预检：用与真实连接**完全相同**的 compose 产物（同 mode / 用户规则 / geo 数据）
    /// 走一遍 xray 的配置解析 + 组件构建，把 xray-core 原生错误文本带回主 App。
    /// 不写 access log（会清空在跑会话的日志）、不配 metrics（预检无需统计）。
    private func performTest(nodeJSON: String, shareLink: String, mode: ProxyMode, userRules: [Rule]) -> Swift.Error? {
        let geo = resolveGeoData()
        do {
            let outboundsJSON = try resolveOutboundsJSON(nodeJSON: nodeJSON, shareLink: shareLink)
            let xrayJSON = try XrayConfigComposer.compose(
                outboundsJSON: outboundsJSON,
                mode: mode,
                accessLogPath: nil,
                userRules: userRules,
                hasFullGeoIP: geo.isFull
            )
            try XrayCore.testConfig(configJSON: xrayJSON, datDir: geo.dir)
            return nil
        } catch {
            return error
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let obj = try? JSONSerialization.jsonObject(with: messageData) as? [String: String],
              let command = obj["command"] else {
            completionHandler?(nil)
            return
        }
        switch command {
        case "reconfigure":
            reconfigure(
                nodeJSON: obj["nodeJSON"] ?? "",
                shareLink: obj["shareLink"] ?? "",
                mode: ProxyMode(rawValue: obj["proxyMode"] ?? "") ?? .global,
                nodeName: obj["nodeName"] ?? "node",
                userRules: loadUserRules(inlineData: nil,
                                         base64: obj["userRulesGZ"],
                                         path: obj["userRulesPath"])
            ) { error in
                let payload: [String: Any] = error == nil
                    ? ["ok": true]
                    : ["ok": false, "error": error!.localizedDescription]
                completionHandler?(try? JSONSerialization.data(withJSONObject: payload))
            }
        case "setAutoStop":
            // VPN 运行中改「定时关闭」档位：从现在起按新时长重新计时（0 = 取消），不断流。
            let seconds = TimeInterval(obj["seconds"] ?? "") ?? 0
            armAutoStop(seconds: seconds)
            completionHandler?(try? JSONSerialization.data(withJSONObject: ["ok": true]))
        case "pingNode":
            // 「经代理延迟」：probeQueue 串行跑（阻塞最长 timeout 秒），回 {ok, delayMs}。
            let nodeJSON = obj["nodeJSON"] ?? ""
            let url = obj["url"] ?? "https://www.google.com/generate_204"
            let timeout = min(max(Int(obj["timeout"] ?? "") ?? 5, 1), 15)
            probeQueue.async { [weak self] in
                guard let self else { completionHandler?(nil); return }
                let payload: [String: Any]
                switch self.performPing(nodeJSON: nodeJSON, url: url, timeoutSeconds: timeout) {
                case .success(let ms):
                    payload = ["ok": true, "delayMs": ms]
                case .failure(let error):
                    payload = ["ok": false, "error": error.localizedDescription]
                }
                completionHandler?(try? JSONSerialization.data(withJSONObject: payload))
            }
        case "testNode":
            // 配置预检：热切换前主 App 先问一声「新配置合法吗」，不合法就不拆在跑的隧道。
            let nodeJSON = obj["nodeJSON"] ?? ""
            let shareLink = obj["shareLink"] ?? ""
            let mode = ProxyMode(rawValue: obj["proxyMode"] ?? "") ?? .global
            let userRules = loadUserRules(inlineData: nil,
                                          base64: obj["userRulesGZ"],
                                          path: obj["userRulesPath"])
            probeQueue.async { [weak self] in
                guard let self else { completionHandler?(nil); return }
                let payload: [String: Any]
                if let error = self.performTest(nodeJSON: nodeJSON, shareLink: shareLink,
                                                mode: mode, userRules: userRules) {
                    payload = ["ok": false, "error": error.localizedDescription]
                } else {
                    payload = ["ok": true]
                }
                completionHandler?(try? JSONSerialization.data(withJSONObject: payload))
            }
        default:
            completionHandler?(nil)
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) { completionHandler() }
    override func wake() { }
}
