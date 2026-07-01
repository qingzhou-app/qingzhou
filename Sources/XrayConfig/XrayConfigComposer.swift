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
import QingzhouCore

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

    /// 拼装完整 xray 配置。只有一个 `tun` inbound —— 整机流量走 TUN。
    /// （不再开本地 HTTP/SOCKS inbound：TUN 已接管所有流量，本地代理纯属冗余，
    /// 还会带来端口冲突。系统代理模式已彻底移除。）
    /// - Parameters:
    ///   - outboundsJSON: libXray.convertShareLinks 的返回（顶层是 {"outbounds":[...]}）
    ///   - mode: 用户选的代理模式（global / rule / direct）
    /// - Returns: 可以直接喂给 `XrayCore.run(configJSON:)` 的完整 xray JSON
    public static func compose(
        outboundsJSON: String,
        mode: ProxyMode,
        accessLogPath: String? = nil
    ) throws -> String {
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
        //
        // 另外：libXray.convertShareLinks 这条 fallback 路径（hysteria2 等 NodeConverter
        // 还没覆盖的协议会走它）仍会从 `...insecure=1` 链接里产出 streamSettings 里的
        // `allowInsecure`。但我们打包的这版 xray-core 已经**硬移除**了该字段
        //（"The feature allowInsecure has been removed and migrated to pinnedPeerCertSha256"），
        // 带着它整个 outbound TLS 解析失败、xray 起不来。NodeConverter 那条路（path A）
        // 已经不再产出它，这里再递归兜底一次，把两条路径都覆盖住。
        for i in 0..<outbounds.count {
            outbounds[i].removeValue(forKey: "sendThrough")
            outbounds[i] = Self.stripAllowInsecure(outbounds[i])
        }

        // libXray 给的第一个 outbound 就是用户那条链接对应的协议。打 "proxy" tag。
        outbounds[0]["tag"] = "proxy"
        // 之后所有规则 / 全局走 "proxy"，直连走 "direct"，拒绝走 "reject"。
        outbounds.append(["tag": "direct", "protocol": "freedom", "settings": [:] as [String: Any]])
        outbounds.append(["tag": "reject", "protocol": "blackhole", "settings": [:] as [String: Any]])
        // dns outbound：DNS 查询被路由到这里，交给 xray 的 dns 段（含 fakedns）处理，
        // 而不是当普通流量转发到真实 DNS。**没有它 fakedns 永远不会触发**。
        outbounds.append(["tag": "dns-out", "protocol": "dns"])

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
                "destOverride": ["fakedns", "http", "tls", "quic"],
                "routeOnly": false
            ]
        ]]

        // 开了 access log，xray 会把每条连接（from src accepted net:host:port [in -> out]）
        // 追加写到这个文件；主 App 读出来解析成真实连接（AccessLogParser）。sniffing 已开，
        // 所以 host 是嗅探出的域名而非 IP。
        var logSection: [String: Any] = ["loglevel": "warning"]
        if let accessLogPath, !accessLogPath.isEmpty {
            logSection["access"] = accessLogPath
        }

        let config: [String: Any] = [
            "log": logSection,
            "inbounds": inbounds,
            "outbounds": outbounds,
            "routing": buildRouting(mode: mode),
            "dns": buildDNS(mode: mode),
            // FakeDNS：给每个域名分配一个 198.18.x.x 假 IP。App 连这个假 IP → TUN → xray 靠
            // sniffing 的 fakedns 反查回真域名，于是 access log / 路由都拿到域名，**不依赖 TLS SNI**
            //（SNI 越来越多被 ECH 加密，纯 sniffing 只能看到 IP，这就是"连接页全是 IP"的根因）。
            "fakedns": [
                ["ipPool": "198.18.0.0/15", "poolSize": 65535] as [String: Any],
                // IPv6 假 IP 池：让 AAAA 查询也拿假 IP，App 走 IPv6 时连接页也能反查回域名
                ["ipPool": "fc00::/18", "poolSize": 65535] as [String: Any]
            ]
        ]

        let out = try JSONSerialization.data(
            withJSONObject: config,
            options: [.sortedKeys]
        )
        return String(data: out, encoding: .utf8) ?? "{}"
    }

    // MARK: - 防御性清理

    /// 递归剔除任意层级里名为 `allowInsecure` 的 key。allowInsecure 只是 TLS 校验开关，
    /// 移除它等价于"按默认校验证书"，对证书合法的节点（绝大多数）没有副作用；对自签节点
    /// 本就需要 pinnedPeerCertSha256（拿不到指纹，暂不支持）。无论它藏在
    /// streamSettings.tlsSettings / realitySettings 还是 hysteria 自己的字段里都能清掉。
    private static func stripAllowInsecure(_ value: Any) -> Any {
        if var dict = value as? [String: Any] {
            dict.removeValue(forKey: "allowInsecure")
            for (k, v) in dict {
                dict[k] = stripAllowInsecure(v)
            }
            return dict
        }
        if let array = value as? [Any] {
            return array.map { stripAllowInsecure($0) }
        }
        return value
    }

    private static func stripAllowInsecure(_ dict: [String: Any]) -> [String: Any] {
        stripAllowInsecure(dict as Any) as? [String: Any] ?? dict
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
                    // DNS 查询（udp 53）→ dns-out，交给 fakedns 处理。必须在最前，否则被下面
                    // "tcp,udp→proxy" 抢走当普通流量转发，fakedns 永远不触发。
                    ["type": "field", "port": 53, "network": "udp", "outboundTag": "dns-out"],
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
                    // DNS 查询 → dns-out（fakedns 处理），必须在最前
                    ["type": "field", "port": 53, "network": "udp", "outboundTag": "dns-out"],
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
                    // DNS 查询 → dns-out（fakedns 处理），必须在最前
                    ["type": "field", "port": 53, "network": "udp", "outboundTag": "dns-out"],
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
                "servers": ["fakedns", "8.8.8.8", "1.1.1.1"],
                "queryStrategy": "UseIP"
            ]
        case .rule:
            // 中国域名用阿里 DNS（IPv4），结果落 geoip:cn 才被接受；其他用 Google + Cloudflare。
            return [
                "servers": [
                    "fakedns",
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
