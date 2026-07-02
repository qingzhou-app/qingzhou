import Foundation

/// xray 内置流量统计（QueryStats / metrics expvar）的 per-outbound 计数快照。
///
/// 数据链路：xray 配置开启 stats + policy(statsOutbound*) + metrics inbound →
/// 隧道扩展定期 GET 本进程 127.0.0.1 的 /debug/vars（XrayCore.queryStats）→
/// 解析出 stats.outbound 各 tag 的 uplink/downlink → 写 App Group `xray-stats.json` →
/// 主 App 轮询读出，展示「代理 / 直连流量占比」。
///
/// 与 TUN 层字节计数（TrafficStats，traffic-stats.json）的关系：
/// - TUN 层是**总量**权威源（含 DNS、握手、重传等所有隧道字节），驱动波形和速率；
/// - 这里是 xray 应用层的 per-outbound 拆分（proxy / direct / reject），是增量维度，
///   两者口径不同（应用层 payload vs IP 包），数值不必对得上。
public struct XrayOutboundStats: Codable, Sendable, Equatable {
    /// 单个 outbound tag 的累计字节（本次 xray 会话内，重启归零）。
    public struct Counter: Codable, Sendable, Equatable {
        public var uplinkBytes: Int64
        public var downlinkBytes: Int64

        public init(uplinkBytes: Int64 = 0, downlinkBytes: Int64 = 0) {
            self.uplinkBytes = uplinkBytes
            self.downlinkBytes = downlinkBytes
        }

        public var totalBytes: Int64 { uplinkBytes + downlinkBytes }
    }

    /// tag（"proxy" / "direct" / "reject" / "dns-out"…）→ 累计计数。
    public var outbounds: [String: Counter]
    public var sampledAt: Date

    public init(outbounds: [String: Counter] = [:], sampledAt: Date = Date()) {
        self.outbounds = outbounds
        self.sampledAt = sampledAt
    }

    public var proxy: Counter { outbounds["proxy"] ?? Counter() }
    public var direct: Counter { outbounds["direct"] ?? Counter() }

    /// 代理流量占（代理+直连）的比例，0…1；两者皆 0 时返回 nil（无意义）。
    public var proxyShare: Double? {
        let p = Double(proxy.totalBytes)
        let d = Double(direct.totalBytes)
        guard p + d > 0 else { return nil }
        return p / (p + d)
    }
}
