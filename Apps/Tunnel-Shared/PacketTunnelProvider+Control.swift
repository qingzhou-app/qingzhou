import Foundation
import os.log
import QingzhouCore
import XrayConfig
import XrayCore

extension PacketTunnelProvider {
    // MARK: - 定时自动关闭（防忘关）

    /// 武装 / 重设 / 取消定时（seconds <= 0 = 取消）。startTunnel 成功后与
    /// handleAppMessage("setAutoStop") 都走这里：从**现在**起计时，写会话标记给主 App。
    func armAutoStop(seconds: TimeInterval) {
        autoStopTimer?.cancel()
        autoStopTimer = nil
        // 始终写会话标记（含 0）—— 覆盖上一次会话的残留，主 App 才不会拿旧 deadline 画倒计时
        sessionInfo.withLock { current in
            let info = TunnelSessionInfo(startedAt: Date(), autoStopSeconds: max(0, seconds),
                appliedConfiguration: current?.appliedConfiguration, trafficSessionID: current?.trafficSessionID)
            current = info
            Self.writeSessionInfo(info)
        }
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
        sessionInfo.withLock { current in
            if var info = current {
                info.stoppedAt = Date()
                current = info
                Self.writeSessionInfo(info)
            }
        }
        _ = XrayCore.stop()
        tearDownBridge()
        cancelTunnelWithError(nil)
    }

    /// 会话标记 → App Group（ISO8601，与主 App AppGroupStorage 的解码策略一致）。
    static func writeSessionInfo(_ info: TunnelSessionInfo) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(info),
              let json = String(data: data, encoding: .utf8) else { return }
        TunnelAppGroup.writeTunnelSession(json)
    }

    // MARK: - 原地重配 / 热换节点 / App Message

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

        // 分流方案不走原地重配：它的出口/跳板不在 reconfigure 的消息体里，用旧的两个节点
        // 套新 mode 会得到一份「半新半旧」的配置。直接回错，让主 App 回退到全量重启
        //（全量重启会重新走 configure() 带上完整的分流参数）。
        if splitExitNodes.withLock({ $0 != nil }) {
            reply(NSError(domain: "com.sbraveyoung.qingzhou.tunnel", code: 1013,
                          userInfo: [NSLocalizedDescriptionKey: "分流方案下不支持原地重配，请重新连接"]))
            return
        }
        // 健康判死器：进入切换窗口，硬 guard 暂停喂样本（stop→start 计数跳变会虚假触发，F24）。
        let health = healthControl
        sessionInfo.withLock { _ in health.withLock { $0.isSwitching = true } }
        // 重配也重新解析 geo：可能刚下载完完整版（下载成功触发的热切换就是走这条链路的全量重启，
        // 但保留原地重配路径的正确性 —— 一旦重新启用不至于用错数据）。
        let geo = resolveGeoData()
        self.activeGeoDir = geo.dir
        let previousPublicIPPort = publicIPPort.withLock { $0 }
        // 重配 = 新 xray 实例，metrics 端口重新要一个（旧实例可能还没放掉旧端口）。
        let diagnosticPorts = (try? XrayCore.getFreePorts(2)) ?? []
        self.metricsPort = diagnosticPorts.first
        publicIPPort.withLock { $0 = diagnosticPorts.count > 1 ? diagnosticPorts[1] : nil }
        let xrayJSON: String
        do {
            let outboundsJSON = mode == .direct ? "{}" : try resolveOutboundsJSON(nodeJSON: nodeJSON, shareLink: shareLink)
            xrayJSON = try XrayConfigComposer.compose(
                outboundsJSON: outboundsJSON,
                mode: mode,
                accessLogPath: TunnelAppGroup.accessLogPath(),
                userRules: userRules,
                hasFullGeoIP: geo.isFull,
                metricsPort: self.metricsPort,
                publicIPPort: publicIPPort.withLock { $0 },
                // 从存的 blockQUIC 重组：别只在 startTunnel 阻断，切换后 QUIC 又放开就白搞了。
                blockQUIC: self.blockQUIC
            )
        } catch {
            os_log("reconfigure: build config failed, keep old xray: %{public}@",
                   log: log, type: .error, error.localizedDescription)
            publicIPPort.withLock { $0 = previousPublicIPPort }
            // 构建失败：旧 xray 照跑，退出切换窗口（baseline 不动，继续按旧节点判死）。
            healthControl.withLock { $0.isSwitching = false }
            reply(error)   // 旧 xray 照跑，网络不受影响
            return
        }
        _ = XrayCore.stop()
        tearDownBridge()
        bringUpXray(configJSON: xrayJSON) { [weak self] error in
            let applied = error == nil ? Self.appliedConfiguration(
                nodeJSON: nodeJSON, mode: mode, blockQUIC: self?.blockQUIC ?? true,
                rulesDigest: AppliedTunnelConfiguration.digestRules(userRules)) : nil
            self?.sessionInfo.withLock { current in
                guard var info = current else { return }
                info.appliedConfiguration = applied
                current = info
                Self.writeSessionInfo(info)
            }
            // 切换完成：退出窗口 + 请求重建 baseline（新节点从头判，含 grace），更新节点名。
            self?.healthControl.withLock { c in
                c.isSwitching = false
                c.needsBaselineReset = true
                c.nodeName = nodeName
            }
            reply(error)
        }
    }

    /// 原地换节点：不动 TUN / 桥 / xray 实例本身，只把 "proxy" outbound handler
    /// 热替换成新节点（libXray 本地扩展 SwitchOutbound，见 scripts/patches/libxray/）。
    /// 路由规则指向的 tag 不变，新连接立刻走新出口 —— 换节点零断流、图标不闪。
    /// 失败回错，主 App 回退到全量重启（安全网）。
    private func switchNode(nodeJSON: String, shareLink: String, nodeName: String, requestID: UUID?,
                            reply: @escaping (Error?) -> Void) {
        os_log("switchNode → node=%{public}@ (in-place, tunnel kept alive)",
               log: log, type: .default, nodeName)

        // 分流方案的出口是手选的、且经跳板固定链路：原地把 proxy outbound 换成别的节点
        // 等于绕开跳板，语义直接错掉。回错让主 App 回退全量重启。
        if splitExitNodes.withLock({ $0 != nil }) {
            reply(NSError(domain: "com.sbraveyoung.qingzhou.tunnel", code: 1014,
                          userInfo: [NSLocalizedDescriptionKey: "分流方案下不支持原地换节点，请重新连接"]))
            return
        }
        // 健康判死器：进入切换窗口，硬 guard 暂停喂样本（F24）。
        let health = healthControl
        sessionInfo.withLock { _ in health.withLock { $0.isSwitching = true } }
        do {
            let outboundsJSON = try resolveOutboundsJSON(nodeJSON: nodeJSON, shareLink: shareLink)
            guard let data = outboundsJSON.data(using: .utf8),
                  var arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  !arr.isEmpty else {
                throw NSError(domain: "com.sbraveyoung.qingzhou.tunnel", code: 1008,
                              userInfo: [NSLocalizedDescriptionKey: "节点转换结果为空"])
            }
            // 与 XrayConfigComposer 同一约定：第一个 outbound 是节点本体，tag = "proxy"
            var outbound = arr[0]
            outbound["tag"] = "proxy"
            let outboundJSON = String(
                data: try JSONSerialization.data(withJSONObject: outbound),
                encoding: .utf8) ?? "{}"
            try XrayCore.switchOutbound(outboundJSON: outboundJSON)
            // 只有Go确认换出口成功才提交。失败保持旧配置；模式和routing继承当前实例。
            sessionInfo.withLock { current in
                guard var info = current, let old = info.appliedConfiguration else { return }
                info.appliedConfiguration = Self.appliedConfiguration(
                    nodeJSON: nodeJSON, mode: old.mode, blockQUIC: old.blockQUIC, requestID: requestID,
                    rulesDigest: old.rulesDigest)
                current = info
                Self.writeSessionInfo(info)
            }
            os_log("switchNode done: proxy outbound now %{public}@", log: log, type: .default, nodeName)
            // 切换完成：退出窗口 + 请求重建 baseline（新节点从头判，含 grace），更新节点名。
            healthControl.withLock { c in
                c.isSwitching = false
                c.needsBaselineReset = true
                c.nodeName = nodeName
            }
            reply(nil)
        } catch {
            os_log("switchNode failed (%{public}@) — app will fall back to full restart",
                   log: log, type: .error, error.localizedDescription)
            // 切换失败：退出窗口（主 App 会回退到全量重启，那条路径会带 needsBaselineReset）。
            healthControl.withLock { $0.isSwitching = false }
            reply(error)
        }
    }

    func handleControlMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
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
        case "switchNode":
            // 原地换节点（Go 调用毫秒级返回，直接在当前线程做，不排 probeQueue ——
            // 那里可能被 15 秒的 pingNode 占着，切换不该排在测速后面）。
            switchNode(
                nodeJSON: obj["nodeJSON"] ?? "",
                shareLink: obj["shareLink"] ?? "",
                nodeName: obj["nodeName"] ?? "node",
                requestID: obj["requestID"].flatMap(UUID.init(uuidString:))
            ) { error in
                var payload: [String: Any] = error == nil
                    ? ["ok": true]
                    : ["ok": false, "error": error!.localizedDescription]
                if error == nil, let id = self.sessionInfo.withLock({ $0?.appliedConfiguration?.id }) {
                    payload["configurationID"] = id.uuidString
                }
                completionHandler?(try? JSONSerialization.data(withJSONObject: payload))
            }
        case "publicIPEndpoint":
            let health = healthControl
            let configuration = sessionInfo.withLock { info in
                let snapshot = info
                return health.withLock { state in
                    state.isSwitching || snapshot?.stoppedAt != nil ? nil : snapshot?.appliedConfiguration?.id
                }
            }
            guard let configuration, obj["configurationID"] == configuration.uuidString,
                  let port = publicIPPort.withLock({ $0 }) else {
                completionHandler?(try? JSONSerialization.data(withJSONObject: ["ok": false, "error": "Exit path unavailable"]))
                return
            }
            completionHandler?(try? JSONSerialization.data(withJSONObject: ["ok": true, "configurationID": configuration.uuidString, "port": port]))
        case "setAutoStop":
            // VPN 运行中改「定时关闭」档位：从现在起按新时长重新计时（0 = 取消），不断流。
            let seconds = TimeInterval(obj["seconds"] ?? "") ?? 0
            armAutoStop(seconds: seconds)
            completionHandler?(try? JSONSerialization.data(withJSONObject: ["ok": true]))
        case "pingNode":
            // 「经代理延迟」：probeQueue 串行跑（阻塞最长 timeout 秒），回 {ok, delayMs}。
            let nodeJSON = obj["nodeJSON"] ?? ""
            let url = obj["url"] ?? ConnectivityProbe.defaultProxiedTarget
            let timeout = min(max(Int(obj["timeout"] ?? "") ?? 5, 1), 15)
            probeQueue.async { [weak self] in
                guard let self else { completionHandler?(nil); return }
                let payload: [String: Any]
                switch self.performPing(nodeJSON: nodeJSON, url: url, timeoutSeconds: timeout) {
                case .success(let ms):
                    payload = ["ok": true, "delayMs": ms]
                case .failure(let error):
                    payload = ["ok": false, "error": error.localizedDescription,
                               "failureKind": ((error as? ProxyProbeError)?.kind ?? .unavailable).rawValue]
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
            let blockQUICOverride = Self.parseOptionalBool(obj["blockQUIC"])
            let splitExitOverride = Self.parseOptionalBool(obj["splitExit"])
            let exitNodeJSON = obj["exitNodeJSON"] ?? ""
            let hopNodeJSON = obj["hopNodeJSON"] ?? ""
            let guardRelayJSON = obj["guardRelayJSON"] ?? ""
            let splitExitPolicyGroupsJSON = obj["splitExitPolicyGroupsJSON"] ?? ""
            probeQueue.async { [weak self] in
                guard let self else { completionHandler?(nil); return }
                let payload: [String: Any]
                if let error = self.performTest(
                    nodeJSON: nodeJSON,
                    shareLink: shareLink,
                    mode: mode,
                    userRules: userRules,
                    blockQUICOverride: blockQUICOverride,
                    splitExitOverride: splitExitOverride,
                    exitNodeJSON: exitNodeJSON,
                    hopNodeJSON: hopNodeJSON,
                    guardRelayJSON: guardRelayJSON,
                    splitExitPolicyGroupsJSON: splitExitPolicyGroupsJSON
                ) {
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

    private static func parseOptionalBool(_ raw: String?) -> Bool? {
        guard let raw else { return nil }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "1": return true
        case "false", "0": return false
        default: return nil
        }
    }
}
