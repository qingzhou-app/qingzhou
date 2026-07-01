import Foundation

/// 某个 tag（outbound / inbound）的累计上下行字节。
public struct DirectedBytes: Equatable, Sendable, Codable {
    public var uplink: Int64
    public var downlink: Int64
    public init(uplink: Int64 = 0, downlink: Int64 = 0) {
        self.uplink = uplink
        self.downlink = downlink
    }
}

/// xray metrics（expvar /debug/vars）解析出的按 tag 分组的累计流量计数。
/// 均为 xray 启动以来的**累计值**；速率由上层对相邻两次采样求差得到。
public struct XrayTrafficCounters: Equatable, Sendable, Codable {
    /// outbound tag（"proxy" = 当前节点、"direct" = 直连…）→ 累计字节
    public var outbound: [String: DirectedBytes]
    /// inbound tag（"tun-in"…）→ 累计字节
    public var inbound: [String: DirectedBytes]

    public init(outbound: [String: DirectedBytes] = [:], inbound: [String: DirectedBytes] = [:]) {
        self.outbound = outbound
        self.inbound = inbound
    }

    /// 代理节点（tag "proxy"）的累计流量 —— 主 App 展示「当前节点用了多少」的数据源。
    public var proxy: DirectedBytes { outbound["proxy"] ?? DirectedBytes() }
}

/// 解析 xray 的 expvar 统计。xray 把每个计数器以形如
/// `outbound>>>proxy>>>traffic>>>uplink` 的名字发布成 expvar 变量。
public enum XrayStatsParser {

    /// 把 `/debug/vars` 的 JSON 解析成按 tag 分组的计数。
    /// 兼容两种形态：计数器作为**顶层 expvar 变量**，或嵌在 `stats` 对象里。
    public static func parse(_ expvarJSON: String) -> XrayTrafficCounters {
        guard let data = expvarJSON.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return XrayTrafficCounters()
        }
        var counters = XrayTrafficCounters()
        // 顶层 + 可能存在的嵌套 "stats" 对象都扫一遍
        ingest(root, into: &counters)
        if let statsObj = root["stats"] as? [String: Any] {
            ingest(statsObj, into: &counters)
        }
        return counters
    }

    private static func ingest(_ dict: [String: Any], into counters: inout XrayTrafficCounters) {
        for (key, value) in dict {
            // 名字形如 outbound>>>{tag}>>>traffic>>>{uplink|downlink}
            let parts = key.components(separatedBy: ">>>")
            guard parts.count == 4, parts[2] == "traffic",
                  let bytes = int64(from: value) else { continue }
            let tag = parts[1]
            let isUp = parts[3] == "uplink"
            let isDown = parts[3] == "downlink"
            guard isUp || isDown else { continue }

            func apply(_ map: inout [String: DirectedBytes]) {
                var cur = map[tag] ?? DirectedBytes()
                if isUp { cur.uplink = bytes } else { cur.downlink = bytes }
                map[tag] = cur
            }
            switch parts[0] {
            case "outbound": apply(&counters.outbound)
            case "inbound":  apply(&counters.inbound)
            default: continue
            }
        }
    }

    /// expvar 里计数值可能是 NSNumber / Int / Int64 / Double（大数）。稳妥取整。
    private static func int64(from value: Any) -> Int64? {
        if let n = value as? Int64 { return n }
        if let n = value as? Int { return Int64(n) }
        if let n = value as? NSNumber { return n.int64Value }
        if let d = value as? Double { return Int64(d) }
        return nil
    }
}
