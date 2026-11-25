import Foundation
import os.log
import QingzhouCore
import UserNotifications
import XrayCore

extension PacketTunnelProvider {
    // MARK: - 流量统计上报

    /// xray 起来后调：在独立队列上每秒算一次速率并写进 App Group。
    func startStatsReporting() {
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
        let counters = byteCounters
        let health = healthControl
        let snap = sessionInfo.withLock { info in
            let configurationID = health.withLock { $0.isSwitching } ? nil : info?.appliedConfiguration?.id
            return counters.withLock { c -> (up: Int64, down: Int64, dUp: Int64, dDown: Int64, configurationID: UUID?) in
                let dUp = c.up - c.lastUp
                let dDown = c.down - c.lastDown
                c.lastUp = c.up
                c.lastDown = c.down
                let attribution = c.configurationWindow.configurationForSample(current: configurationID)
                return (c.up, c.down, dUp, dDown, attribution)
            }
        }
        // 速率 = 字节增量 ÷ **实际**经过秒数（不假设定时器精确 1 秒，抗漂移/饿死）
        let secs = elapsed > 0.01 ? elapsed : 1
        let stats = TrafficStats(
            uploadBytes: snap.up,
            downloadBytes: snap.down,
            uploadSpeedBps: Int64(Double(max(0, snap.dUp)) / secs),
            downloadSpeedBps: Int64(Double(max(0, snap.dDown)) / secs),
            activeConnections: 0,   // access log 接入后填真实连接数（a 的下一支线）
            sampledAt: now,
            configurationID: snap.configurationID
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
        let attributionBefore = bandwidthAttribution()
        guard let expvar = try? XrayCore.queryStats(metricsPort: port) else { return }
        if now.timeIntervalSince(domainTrafficRecordedAt) >= 10 {
            domainTrafficRecordedAt = now
            if domainTrafficRecorder == nil {
                if let url = TunnelAppGroup.containerURL?.appendingPathComponent(DomainTrafficLedger.storageName + ".json") {
                    do {
                        domainTrafficRecorder = try DomainTrafficRecorder(url: url)
                        domainTrafficInitializationErrorLogged = false
                    } catch {
                        if !domainTrafficInitializationErrorLogged {
                            os_log("Monthly domain history unreadable; preserving file and retrying later", log: log, type: .error)
                            domainTrafficInitializationErrorLogged = true
                        }
                    }
                }
            }
            if let data = expvar.data(using: .utf8), let snapshot = DomainTrafficSnapshot.parseMetrics(data) {
                do { try domainTrafficRecorder?.record(snapshot, at: now, vpnSessionID: sessionInfo.withLock { $0?.trafficSessionID }) }
                catch { os_log("Monthly domain history write failed; next sample will retry", log: log, type: .error) }
            }
        }
        let parsed = XrayCore.parseOutboundStats(expvar)
        guard !parsed.isEmpty else { return }
        let attributionAfter = bandwidthAttribution()
        var stats = XrayOutboundStats(sampledAt: Date(),
            configurationID: attributionBefore == attributionAfter ? attributionAfter : nil)
        for (tag, c) in parsed {
            stats.outbounds[tag] = XrayOutboundStats.Counter(uplinkBytes: c.uplink, downlinkBytes: c.downlink)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601   // 与主 App AppGroupStorage.read 的解码策略一致
        if let data = try? encoder.encode(stats), let json = String(data: data, encoding: .utf8) {
            TunnelAppGroup.writeXrayStats(json)
        }
        // 健康触发的故障切换：喂 proxy per-outbound 计数进纯逻辑判死器。长驻循环里套
        // autoreleasepool（NE 50MB 预算，别让 encode 的临时对象堆积到下一个 runloop）。
        autoreleasepool { feedNodeHealth(proxy: stats.proxy, at: now) }
    }

    /// 查询前后均需处在初始配置；换过出口后直到新扩展会话都不再给带宽打归属。
    private func bandwidthAttribution() -> UUID? {
        let health = healthControl
        return sessionInfo.withLock { info in
            let currentID = info?.appliedConfiguration?.id
            return health.withLock { control in
                guard !control.isSwitching, let id = currentID,
                      id == control.bandwidthConfigurationID else { return nil }
                return id
            }
        }
    }

    /// 把 proxy 累计计数喂进 NodeHealthDetector，确认 .suspect 时写 App Group 信号 + 发通知。
    /// **statsQueue 上跑**（healthDetector / lastHealthNotifiedAt 的唯一访问线程）。
    /// 首版**只检测 + 告警，绝不自动切数据面**（切换由主 App 用户一键触发）。
    private func feedNodeHealth(proxy: XrayOutboundStats.Counter, at now: Date) {
        // 读控制位 + 消费一次性的 baseline 重置请求（原子取回）。
        let control = healthControl.withLock { c -> (switching: Bool, reset: Bool, name: String) in
            let snap = (c.isSwitching, c.needsBaselineReset, c.nodeName)
            if c.needsBaselineReset { c.needsBaselineReset = false }
            return snap
        }
        // 硬 guard：切换窗口内不喂（mid-switch stop→start 会让所有信号虚假触发，F24）。
        if control.switching { return }
        if control.reset { healthDetector.resetBaseline() }

        let state = healthDetector.ingest(
            proxyUplinkTotal: proxy.uplinkBytes,
            proxyDownlinkTotal: proxy.downlinkBytes,
            at: now
        )

        // 每 tick 都写当前状态（既是 suspect 触发源，也是 healthy 心跳 —— 让主 App 横幅
        // 在切换 / 恢复后能自动收起，靠信号新鲜度而非猜测）。
        let signal = NodeHealthSignal(state, nodeName: control.name, at: now)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(signal), let json = String(data: data, encoding: .utf8) {
            TunnelAppGroup.writeNodeHealth(json)
        }

        if state == .suspect {
            os_log("node health → SUSPECT (node=%{public}@): proxy uplink 在涨、downlink 持平",
                   log: log, type: .error, control.name)
            sendHealthNotification(nodeName: control.name, at: now)
        }
    }

    /// 「疑似故障」本地通知（带 5 分钟/节点冷却）。固定 identifier → 同一时刻只留一条。
    /// 权限由主 App 在用户 opt-in 故障提醒时才申请；未授权时 add 静默 no-op（= 天然的开关）。
    /// 文案四语：String(localized:) 查 appex 自己的 Localizable.xcstrings（Tunnel-Shared/）。
    /// 已知边界：扩展是独立进程，按**系统语言**解析 —— 用户在 App 内改语言而系统语言不同时，
    /// 通知语言 = 系统语言（感知不到主 App 的语言设置，可接受）。见 docs/FAILOVER.md。
    private func sendHealthNotification(nodeName: String, at now: Date) {
        if let last = lastHealthNotifiedAt[nodeName], now.timeIntervalSince(last) < Self.healthNotifyCooldown {
            return
        }
        lastHealthNotifiedAt[nodeName] = now
        let content = UNMutableNotificationContent()
        content.title = String(localized: "轻舟")
        content.body = String(localized: "当前节点疑似故障，点此切换")
        content.sound = .default
        content.userInfo = ["type": "nodeHealthSuspect", "nodeName": nodeName]
        let req = UNNotificationRequest(
            identifier: "com.sbraveyoung.qingzhou.nodeHealth",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
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
                    // 读侧钳制：崩溃循环时代可能留下过物理上不可能的天文峰值（实测 8.4GB），
                    // 照单全收会永久粘住 —— 超界视为损坏，丢弃后用本会话数据重建。
                    memAllTimePeak = TunnelMemoryPeakGuard.sanitizedPersistedPeak(prev.allTimePeakBytes)
                }
            }
        }
        if let fp = footprint {
            // 写侧防护：单次采样超过可信上限（病理读数）不并入峰值，防坏样本再次落盘粘住。
            memSessionPeak = TunnelMemoryPeakGuard.mergingPeak(memSessionPeak, sample: fp)
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
    func captureFakeDNS(_ packet: Data) {
        let maps = FakeDNSResolver.mappingsFromIPPacket([UInt8](packet))
        guard !maps.isEmpty else { return }
        fakeDNSMap.withLock { dict in
            for m in maps { dict[m.ip] = m.domain }
        }
    }
}
