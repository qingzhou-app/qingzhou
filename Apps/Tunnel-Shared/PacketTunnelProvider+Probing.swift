import Foundation
import QingzhouCore
import XrayConfig
import XrayCore

extension PacketTunnelProvider {
    // MARK: - 经代理延迟（pingNode）/ 配置预检（testNode）—— probeQueue 上串行跑

    /// 「经代理延迟」：给节点起一个临时 xray 实例（socks inbound + 该节点 outbound），
    /// 真实走节点发一次 HTTP HEAD，返回全链路毫秒数。
    /// 与主 App 的直连 TCP 探测是两个维度 —— 这里量的是「本机→节点→目标」代理链路。
    /// probeQueue 串行保证同一时刻至多一个临时实例（NE 50MB 内存预算）。
    func performPing(nodeJSON: String, url: String, timeoutSeconds: Int) -> Result<Int, Swift.Error> {
        // 内存余量护栏：iOS 上 footprint 已逼近 jetsam 线时拒绝再起临时实例 ——
        // 测个延迟把隧道整个搞断划不来。macOS 无硬上限（platformLimitBytes = 0），不拦。
        if MemoryFootprint.platformLimitBytes > 0,
           let fp = MemoryFootprint.currentFootprint(),
           fp > 38 * 1024 * 1024 {
            return .failure(ProxyProbeError(kind: .resourceLimited,
                message: "扩展内存余量不足，暂缓经代理测速"))
        }
        guard let target = URL(string: url), ["http", "https"].contains(target.scheme?.lowercased() ?? ""),
              target.host != nil else {
            return .failure(ProxyProbeError(kind: .invalidTarget, message: "探测目标无效"))
        }
        var stage = ProxyProbeFailure.invalidConfiguration
        do {
            guard let data = nodeJSON.data(using: .utf8) else {
                throw NSError(domain: "com.sbraveyoung.qingzhou.tunnel", code: 1006,
                              userInfo: [NSLocalizedDescriptionKey: "nodeJSON 为空"])
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let node = try decoder.decode(Node.self, from: data)
            let outbound = try NodeConverter.toOutboundDict(node)
            stage = .resourceLimited
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
            // LibXray 目前未分拆启动/请求错误，不能进一步归因为凭据、出口或目标故障。
            stage = .probeFailed
            let ms = try XrayCore.ping(
                configJSON: configJSON,
                socksPort: port,
                url: url,
                timeoutSeconds: timeoutSeconds,
                datDir: activeGeoDir ?? ""
            )
            return .success(ms)
        } catch {
            return .failure(ProxyProbeError(kind: stage, message: error.localizedDescription))
        }
    }

    /// 配置预检：用与真实连接**完全相同**的 compose 产物（同 mode / 用户规则 / geo 数据）
    /// 走一遍 xray 的配置解析 + 组件构建，把 xray-core 原生错误文本带回主 App。
    /// 不写 access log（会清空在跑会话的日志）、不配 metrics（预检无需统计）。
    func performTest(nodeJSON: String, shareLink: String, mode: ProxyMode, userRules: [Rule]) -> Swift.Error? {
        let geo = resolveGeoData()
        do {
            // 分流方案：预检必须与实跑同一份配置，否则「预检通过、真连失败」。
            if let splitExit = splitExitNodes.withLock({ $0 }) {
                let xrayJSON = try composeSplitExit(splitExit, accessLogPath: nil, tunInterfaceName: "utun9")
                try XrayCore.testConfig(configJSON: xrayJSON, datDir: geo.dir)
                return nil
            }
            let outboundsJSON = mode == .direct ? "{}" : try resolveOutboundsJSON(nodeJSON: nodeJSON, shareLink: shareLink)
            let xrayJSON = try XrayConfigComposer.compose(
                outboundsJSON: outboundsJSON,
                mode: mode,
                accessLogPath: nil,
                userRules: userRules,
                hasFullGeoIP: geo.isFull,
                // 预检没有 TUN fd，TestXray 会严格校验接口名 —— 必须传合法的 utunN，
                // 否则 xray 报「interface name must be utunN」把好配置误判成无效、中止热切换。
                tunInterfaceName: "utun9",
                // 预检要与真实连接**完全相同**的产物：blockQUIC 也带上，否则预检配置和实跑不一致。
                blockQUIC: self.blockQUIC
            )
            try XrayCore.testConfig(configJSON: xrayJSON, datDir: geo.dir)
            return nil
        } catch {
            return error
        }
    }
}
