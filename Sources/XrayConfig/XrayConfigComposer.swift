// XrayConfigComposer
//
// libXray.ConvertShareLinksToXrayJson 只产出 `outbounds` 段 —— 直接喂给
// xray-core 启动后什么都不做，因为没有 inbound 来源、没有 routing 决策。
//
// 这个 composer 把那段 outbound 包装成完整的 xray 配置：
//   - `tun` inbound：xray-core 通过 platform.TunFdKey 环境变量拿到 NEPacketTunnel
//     传来的文件描述符 (proxy/tun/tun_darwin.go 的 NewTun)，从 TUN 接管 IP 层流量
//   - `outbounds`：上游的 proxy + freedom (direct) + blackhole (reject)
//   - `routing`：按 ProxyMode 走全局 / 规则 / 直连
//   - `dns`：UseIP 策略避免 DNS 污染；规则模式下中国域名走阿里 DNS
//
// 这就是 S2 之前 ConfigurationError 报错 + 流量空跑 的真正原因 —— 谢谢用户跑通真机
// 发现这个坑。

import Foundation
import VPNCore

public enum XrayConfigComposer {

    public enum Error: Swift.Error, LocalizedError {
        case invalidOutboundJSON
        case noProxyOutbound

        public var errorDescription: String? {
            switch self {
            case .invalidOutboundJSON:
                return "libXray 返回的不是合法 JSON"
            case .noProxyOutbound:
                return "libXray 输出的 outbounds 为空 —— 节点链接可能解析失败"
            }
        }
    }

    /// 拼装完整 xray 配置。
    /// - Parameters:
    ///   - outboundsJSON: libXray.convertShareLinks 的返回（顶层是 {"outbounds":[...]}）
    ///   - mode: 用户选的代理模式（global / rule / direct）
    /// - Returns: 可以直接喂给 `XrayCore.run(configJSON:)` 的完整 xray JSON
    public static func compose(outboundsJSON: String, mode: ProxyMode) throws -> String {
        guard let data = outboundsJSON.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Error.invalidOutboundJSON
        }
        var outbounds = (root["outbounds"] as? [[String: Any]]) ?? []
        guard !outbounds.isEmpty else { throw Error.noProxyOutbound }

        // libXray 把 share link 的 fragment（节点显示名）误填进 sendThrough，
        // 而 sendThrough 本意是本地绑定 IP，xray-core 当 net.IP 解析必失败 →
        // "unable to send through: <node 名>"。这里主动剔除，让 xray 用默认。
        // 顺手把 `streamSettings.sockopt.bindToDevice` 之类的也别让 libXray 乱写。
        for i in 0..<outbounds.count {
            outbounds[i].removeValue(forKey: "sendThrough")
        }

        // libXray 给的第一个 outbound 就是用户那条链接对应的协议。打 "proxy" tag。
        outbounds[0]["tag"] = "proxy"
        // 之后所有规则 / 全局走 "proxy"，直连走 "direct"，拒绝走 "reject"。
        outbounds.append(["tag": "direct", "protocol": "freedom", "settings": [:] as [String: Any]])
        outbounds.append(["tag": "reject", "protocol": "blackhole", "settings": [:] as [String: Any]])

        // tun inbound：MTU 跟 PacketTunnelProvider 里 setTunnelNetworkSettings 保持一致。
        // sniffing 开启：让 xray 从 TLS SNI / HTTP Host 提取真实域名，便于按域名路由。
        let inbounds: [[String: Any]] = [[
            "tag": "tun-in",
            "protocol": "tun",
            "settings": [
                "name": "utun",
                "MTU": 1500
            ],
            "sniffing": [
                "enabled": true,
                "destOverride": ["http", "tls", "quic"],
                "routeOnly": false
            ]
        ]]

        let config: [String: Any] = [
            "log": ["loglevel": "warning"],
            "inbounds": inbounds,
            "outbounds": outbounds,
            "routing": buildRouting(mode: mode),
            "dns": buildDNS(mode: mode)
        ]

        let out = try JSONSerialization.data(
            withJSONObject: config,
            options: [.sortedKeys]
        )
        return String(data: out, encoding: .utf8) ?? "{}"
    }

    // MARK: - Routing

    private static func buildRouting(mode: ProxyMode) -> [String: Any] {
        switch mode {
        case .global:
            // 全局模式特意不引用 geoip / geosite，这样即使 geo .dat 文件加载失败
            // xray 也能启动。RFC1918 + 链路本地 + loopback 用显式 CIDR 处理。
            return [
                "domainStrategy": "AsIs",
                "rules": [
                    ["type": "field",
                     "ip": ["127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12",
                            "192.168.0.0/16", "169.254.0.0/16", "::1/128", "fc00::/7", "fe80::/10"],
                     "outboundTag": "direct"],
                    ["type": "field", "network": "tcp,udp", "outboundTag": "proxy"]
                ]
            ]
        case .rule:
            return [
                "domainStrategy": "IPIfNonMatch",
                "rules": [
                    // LAN
                    ["type": "field", "ip": ["geoip:private"], "outboundTag": "direct"],
                    // 中国 IP 段直连
                    ["type": "field", "ip": ["geoip:cn"], "outboundTag": "direct"],
                    // 中国域名直连
                    ["type": "field", "domain": ["geosite:cn"], "outboundTag": "direct"],
                    // 广告 / 隐私 / 恶意域名拒绝（geosite 自带分类）
                    ["type": "field", "domain": ["geosite:category-ads-all"], "outboundTag": "reject"],
                    // 其余走代理
                    ["type": "field", "network": "tcp,udp", "outboundTag": "proxy"]
                ]
            ]
        case .direct:
            return [
                "domainStrategy": "AsIs",
                "rules": [
                    ["type": "field", "network": "tcp,udp", "outboundTag": "direct"]
                ]
            ]
        }
    }

    // MARK: - DNS

    private static func buildDNS(mode: ProxyMode) -> [String: Any] {
        switch mode {
        case .global, .direct:
            return [
                "servers": ["8.8.8.8", "1.1.1.1"],
                "queryStrategy": "UseIP"
            ]
        case .rule:
            // 中国域名用阿里 DNS（IPv4），结果落 geoip:cn 才被接受；其他用 Google + Cloudflare。
            return [
                "servers": [
                    [
                        "address": "223.5.5.5",
                        "port": 53,
                        "domains": ["geosite:cn"],
                        "expectIPs": ["geoip:cn"]
                    ] as [String: Any],
                    "8.8.8.8",
                    "1.1.1.1"
                ],
                "queryStrategy": "UseIP"
            ]
        }
    }
}
