// SplitExitPlan —— 「国内直连、其余全走海外出口、断了也不漏」的完整 xray 配置。
//
// 这个文件实现的是**一个特定分流策略**，不是通用配置器：
//   出口 = 一台静态住宅 SOCKS5；它自己经「跳板」节点连出去（dialerProxy）。
//   海外出口组里只有住宅代理一个成员，没有 DIRECT、没有自动择优、没有故障切换 ——
//   住宅挂了就是海外断网，绝不会偷偷退回直连。
//
// 为什么不用 ProxyMode / 通用 compose：
//   通用 compose 的 rule/global 模式里，兜底是 "proxy"，而 "proxy" 是用户当前手选的
//   普通节点，且 App 层有自动择优与 failover（AppState）会换节点。本需求要的是
//   「手选、挂了就断」。语义不同就得是独立的配置构造路径，不能靠关开关去近似。
//
// 规则顺序（first-match，从上到下即优先级，与需求逐条对应）：
//   1. Claude 自家域名 / 含 claude、anthropic 关键字的域名 → 海外出口
//   2. 局域网与保留地址（含 100.64.0.0/10）→ 直连
//   3. B 站、微信 → 直连
//   4. GEOSITE geolocation-!cn（海外域名分类）→ 海外出口
//      ⚠️ 必须排在国内名单之前：国内名单里混着 googletagmanager / doubleclick 这类
//      海外公司域名，先被国内名单吃掉就会「用国内 IP 访问海外服务」。
//   5. 国内域名名单 / 国内 IP 名单 → 直连
//   6. 其余全部 → 海外出口（UDP 无出口可用 → 拒绝，不回退直连）
//
// DNS：
//   - 所有查询进代理（fake-ip），不返回 IPv6 地址（queryStrategy UseIPv4 + 只有 IPv4 假 IP 池）
//   - 国内域名、跳板/住宅自己的域名 → 国内 DNS（223.5.5.5 / 119.29.29.29），且这些查询
//     本身走直连（否则「用出口查节点域名」会绕成环）
//   - 其余（海外域名）→ 海外 DoH，查询流量走海外出口；出口挂了海外解析就失败，
//     不会退回国内 DNS 拿到国内 IP
//
// 不做的事（此处刻意留白，避免被误读成已实现）：
//   - 不生成 TUN 路由 / 不开关 TUN（由 PacketTunnelProvider 负责）
//   - 不下载规则名单（由 RuleListFetcher 负责，本文件只接收已解析的名单）
//   - 不做断网开关（pf 侧独立组件）

import Foundation
import QingzhouCore

public struct SplitExitPlan {

    public enum PlanError: Swift.Error, LocalizedError, Equatable {
        case missingExitNode
        case hopEqualsExit
        case hopNotProxy(NodeIdentityErrorReason)

        public enum NodeIdentityErrorReason: String, Sendable {
            case sameHostPort
        }

        public var errorDescription: String? {
            switch self {
            case .missingExitNode:
                return "没有配置海外出口（住宅 SOCKS5）节点"
            case .hopEqualsExit:
                return "跳板和海外出口是同一个节点，会绕成死循环"
            case .hopNotProxy:
                return "跳板节点与海外出口重复"
            }
        }
    }

    /// 外部注入的名单（Loyalsoldier/clash-rules 的 direct.txt / cncidr.txt 解析结果）。
    /// 空数组是合法的：此时只用内置 geosite:cn / geoip:cn，行为仍然正确，只是粒度粗一些。
    public struct Lists: Sendable, Equatable {
        /// 国内域名（DOMAIN-SUFFIX 的值，如 `qq.com`）。空 = 不追加。
        public var cnDomains: [String]
        /// 国内域名关键字（`DOMAIN-KEYWORD,wechat` 这种不含点的条目）。xray 里裸串即子串匹配。
        public var cnDomainKeywords: [String]
        /// 国内 IP 段（如 `1.0.1.0/24`）。
        public var cnCIDRs: [String]

        public init(cnDomains: [String] = [], cnDomainKeywords: [String] = [], cnCIDRs: [String] = []) {
            self.cnDomains = cnDomains
            self.cnDomainKeywords = cnDomainKeywords
            self.cnCIDRs = cnCIDRs
        }

        public var isEmpty: Bool { cnDomains.isEmpty && cnDomainKeywords.isEmpty && cnCIDRs.isEmpty }
    }

    /// 断网开关的 root 中继（`Tools/qingzhou-guard`）。
    ///
    /// 为什么代理要经它出网：轻舟的 xray 以 uid 501 运行，pf 只能按 uid 匹配 ——
    /// 「拦掉除 root 外的一切」如果不给代理留一条 root 的出网路径，就会连代理一起拦死。
    /// 串上中继之后，uid 501 的出站只到 127.0.0.1，真正拨号由 root 中继完成。
    public struct RelayEndpoint: Sendable, Equatable {
        public var host: String
        public var port: UInt16
        public var username: String
        public var password: String

        public init(host: String = "127.0.0.1", port: UInt16 = 10808,
                    username: String, password: String) {
            self.host = host
            self.port = port
            self.username = username
            self.password = password
        }
    }

    /// outbound tag。固定字符串，日志与验收脚本按这些 tag 归因，改名会破坏验收。
    public enum Tag {
        public static let exit   = "exit"
        public static let hop    = "hop"
        public static let relay  = "relay"
        public static let direct = "direct"
        public static let reject = "reject"
        public static let dnsOut = "dns-out"
    }

    public var exitNode: Node
    public var hopNode: Node
    public var lists: Lists
    /// 关掉 QUIC（UDP 443）强制浏览器回退 TCP —— 经 SOCKS5 出口的 QUIC 基本不通。
    public var blockQUIC: Bool
    /// 指向海外出口的 UDP 一律拒绝，而不是回退直连。
    public var rejectOverseasUDP: Bool
    /// 断网开关的 root 中继。nil = 代理直接出网（没有断网开关时的行为）。
    public var relay: RelayEndpoint?
    /// 海外 DoH 解析器。必须能通过 TCP 443 走到（出口不支持 UDP）。
    public var overseasResolvers: [String]
    /// 国内解析器（明文 UDP，走直连）。
    public var domesticResolvers: [String]

    public init(
        exitNode: Node,
        hopNode: Node,
        lists: Lists = Lists(),
        blockQUIC: Bool = true,
        rejectOverseasUDP: Bool = true,
        relay: RelayEndpoint? = nil,
        overseasResolvers: [String] = ["https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query"],
        domesticResolvers: [String] = ["223.5.5.5", "119.29.29.29"]
    ) {
        self.exitNode = exitNode
        self.hopNode = hopNode
        self.lists = lists
        self.blockQUIC = blockQUIC
        self.rejectOverseasUDP = rejectOverseasUDP
        self.relay = relay
        self.overseasResolvers = overseasResolvers
        self.domesticResolvers = domesticResolvers
    }

    /// Claude 自家域名。用户要求「及其他域名中含有 claude、anthropic 等关键字的」，
    /// 因此同时给精确域名与关键字（xray 里裸串就是子串匹配）。
    static let claudeDomains: [String] = [
        "claude.ai", "claude.com", "anthropic.com",
        "claudeusercontent.com", "claudemcpclient.com"
    ]
    static let claudeKeywords: [String] = ["claude", "anthropic"]

    /// B 站。`mirrorakam` 是视频分片域名（如 `upos-sz-mirrorakam.akamaized.net`），
    /// 它与主域不同后缀，DOMAIN-SUFFIX 匹配不到，只能按关键字。
    static let bilibiliDomains: [String] = [
        "bilibili.com", "biliapi.net", "biliapi.com", "bilivideo.com",
        "bilivideo.cn", "hdslb.com", "b23.tv", "acgvideo.com"
    ]
    static let bilibiliKeywords: [String] = ["mirrorakam"]

    /// 微信。内置 geosite.dat **没有** `wechat` 分类（已实测 1469 个分类里不存在），
    /// 只能用 `tencent` 分类 + 显式域名兜住。
    static let wechatDomains: [String] = [
        "weixin.qq.com", "wechat.com", "weixin.com", "wx.qq.com",
        "servicewechat.com", "weixinbridge.com", "wechatpay.com",
        "qpic.cn", "gtimg.cn", "qlogo.cn"
    ]

    /// 局域网 / 保留地址。100.64.0.0/10 是运营商级 NAT 段（Tailscale 等也用它），
    /// 需求点名要直连；geoip:private 不一定覆盖它，所以显式写死。
    static let reservedCIDRs: [String] = [
        "127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
        "169.254.0.0/16", "100.64.0.0/10",
        "::1/128", "fc00::/7", "fe80::/10"
    ]

    // MARK: - Outbounds

    /// 出口组只有住宅代理一个成员；`hop` 只作为 dialerProxy 的跳板存在，
    /// 不作为任何路由规则的 outboundTag —— 所以「海外出口里没有 DIRECT」是结构性的，
    /// 不依赖某条规则写对。
    ///
    /// 带 root 中继时链路是：
    ///   exit(住宅 SOCKS5) ──dialerProxy──▶ hop(跳板) ──dialerProxy──▶ relay(root) ──▶ 外网
    ///   direct(freedom)    ──────────────dialerProxy──────────────▶ relay(root) ──▶ 外网
    /// 也就是 uid 501 的出站只到 127.0.0.1，真正拨号全在 root 进程里完成。
    public func outbounds() throws -> [[String: Any]] {
        var exit = try NodeConverter.toOutboundDict(exitNode)
        exit["tag"] = Tag.exit
        // 住宅代理的连接本身经跳板出去。写在 streamSettings.sockopt.dialerProxy：
        // xray 会用指定 tag 的出站去拨号，而不是从本机直接连住宅 IP（国内连不上，
        // 而且直连会把真实 IP 暴露给住宅服务商）。
        exit = Self.attachDialerProxy(Tag.hop, to: exit)

        var hop = try NodeConverter.toOutboundDict(hopNode)
        hop["tag"] = Tag.hop

        var outbounds: [[String: Any]] = [exit, hop]

        // 中继放在 hop 之后：hop 的拨号也要走它，否则 uid 501 的出站仍会直连外网，
        // 断网开关一旦启用就会把这条链路拦掉。
        if let relay {
            var hopWithRelay = hop
            hopWithRelay = Self.attachDialerProxy(Tag.relay, to: hopWithRelay)
            outbounds[1] = hopWithRelay

            let relayOutbound: [String: Any] = [
                "tag": Tag.relay,
                "protocol": "socks",
                "settings": ["servers": [[
                    "address": relay.host,
                    "port": Int(relay.port),
                    "users": [["user": relay.username, "pass": relay.password]]
                ] as [String: Any]]] as [String: Any]
            ]
            outbounds.append(relayOutbound)
        }

        var direct: [String: Any] = [
            "tag": Tag.direct,
            "protocol": "freedom",
            "settings": ["domainStrategy": "AsIs"] as [String: Any],
            "streamSettings": ["sockopt": ["domainStrategy": "ForceIP"]] as [String: Any]
        ]
        // 国内直连也是「从本机发出去的包」。不串中继的话，断网开关会把国内直连一起拦掉。
        if relay != nil {
            direct = Self.attachDialerProxy(Tag.relay, to: direct)
        }
        outbounds.append(direct)

        outbounds.append(["tag": Tag.reject, "protocol": "blackhole", "settings": [:] as [String: Any]])
        outbounds.append(["tag": Tag.dnsOut, "protocol": "dns"])
        return outbounds
    }

    /// 把 `dialerProxy` 合并进 streamSettings.sockopt，保留节点原有的 sockopt 字段。
    static func attachDialerProxy(_ tag: String, to outbound: [String: Any]) -> [String: Any] {
        var out = outbound
        var stream = (out["streamSettings"] as? [String: Any]) ?? [:]
        var sockopt = (stream["sockopt"] as? [String: Any]) ?? [:]
        sockopt["dialerProxy"] = tag
        stream["sockopt"] = sockopt
        out["streamSettings"] = stream
        return out
    }

    // MARK: - Routing

    public func routing() -> [String: Any] {
        var rules: [[String: Any]] = []

        // 0) DNS 模块自己发出的上游查询。
        //    国内解析器必须直连（走出口查国内 DNS 会拿到境外边缘 IP，也要绕一圈）；
        //    其余（海外 DoH）走海外出口 —— 这就是「海外域名由海外 DNS 经海外出口解析」。
        //    必须排在最前：这些查询本身也是 udp/tcp 53，抢在 `port:53 → dns-out` 之前
        //    拦下，否则会重入 dns 模块形成环。
        let domesticIPs = domesticResolvers.compactMap { Self.ipLiteral(from: $0) }
        if !domesticIPs.isEmpty {
            rules.append(["type": "field", "inboundTag": ["dns-module"],
                          "ip": domesticIPs, "outboundTag": Tag.direct])
        }
        rules.append(["type": "field", "inboundTag": ["dns-module"], "outboundTag": Tag.exit])

        // 1) App 发来的 DNS 查询 → dns-out（fake-ip 在这里分配假地址）
        rules.append(["type": "field", "inboundTag": ["tun-in"], "port": 53,
                      "network": "tcp,udp", "outboundTag": Tag.dnsOut])

        // 2) QUIC：经 SOCKS5 出口基本不通，先拒掉让浏览器回退 TCP
        if blockQUIC {
            rules.append(["type": "field", "network": "udp", "port": 443, "outboundTag": Tag.reject])
        }

        // 3) Claude 自家域名与关键字 → 海外出口
        rules.append(["type": "field",
                      "domain": Self.claudeDomains.map { "full:\($0)" }
                        + Self.claudeDomains.map { "domain:\($0)" }
                        + Self.claudeKeywords,
                      "outboundTag": Tag.exit])

        // 4) 局域网 / 保留地址直连（含 100.64.0.0/10）
        rules.append(["type": "field", "ip": Self.reservedCIDRs, "outboundTag": Tag.direct])

        // 5) B 站 / 微信 → 直连
        rules.append(["type": "field",
                      "domain": ["geosite:bilibili"]
                        + Self.bilibiliDomains.map { "domain:\($0)" }
                        + Self.bilibiliKeywords,
                      "outboundTag": Tag.direct])
        rules.append(["type": "field",
                      "domain": ["geosite:tencent"]
                        + Self.wechatDomains.map { "full:\($0)" }
                        + Self.wechatDomains.map { "domain:\($0)" },
                      "outboundTag": Tag.direct])

        // 6) 海外域名分类 → 海外出口。必须在国内名单之前。
        //    UDP 单独拒：出口没有可用 UDP，明确拒绝而不是让它漏到直连。
        rules.append(["type": "field", "domain": ["geosite:geolocation-!cn"],
                      "network": "tcp", "outboundTag": Tag.exit])
        if rejectOverseasUDP {
            rules.append(["type": "field", "domain": ["geosite:geolocation-!cn"],
                          "network": "udp", "outboundTag": Tag.reject])
        }

        // 7) 国内域名 / 国内 IP → 直连。
        //    domainStrategy = AsIs：IP 规则只匹配字面 IP，**不会**为了匹配去做本地 DNS 解析
        //    （需求：IP 类规则不要为了匹配去本地解析域名）。
        var cnDomainEntries = ["geosite:cn"]
        cnDomainEntries += lists.cnDomains.map { "domain:\($0)" }
        // 关键字条目原样放进 domain 数组：xray 对不带前缀的串做子串匹配。
        cnDomainEntries += lists.cnDomainKeywords
        rules.append(["type": "field", "domain": cnDomainEntries, "outboundTag": Tag.direct])

        var cnIPEntries = ["geoip:cn"]
        cnIPEntries += lists.cnCIDRs
        rules.append(["type": "field", "ip": cnIPEntries, "outboundTag": Tag.direct])

        // 8) 兜底：TCP → 海外出口；UDP → 拒绝（出口关掉了 UDP，不回退直连）
        rules.append(["type": "field", "network": "tcp", "outboundTag": Tag.exit])
        rules.append(["type": "field", "network": "udp",
                      "outboundTag": rejectOverseasUDP ? Tag.reject : Tag.exit])

        return ["domainStrategy": "AsIs", "rules": rules]
    }

    // MARK: - DNS

    public func dns() -> [String: Any] {
        // 节点自己的域名（跳板 / 住宅的 host 若是域名）必须用国内 DNS 解析：
        // 用出口去解析「出口自己的地址」是自指的死循环。
        var nodeHosts: [String] = []
        for host in [exitNode.host, hopNode.host] where !Self.isIPLiteral(host) {
            nodeHosts.append("full:\(host.lowercased())")
        }
        // 国内域名也走国内 DNS，拿国内边缘 IP。
        var domesticMatch = ["geosite:cn"] + nodeHosts
        domesticMatch += lists.cnDomains.map { "domain:\($0)" }
        domesticMatch += lists.cnDomainKeywords

        var servers: [Any] = ["fakedns"]
        for resolver in domesticResolvers {
            guard let ip = Self.ipLiteral(from: resolver) else { continue }
            // 带 root 中继时必须用 TCP 查：中继只做 SOCKS5 CONNECT（TCP），UDP 过不去。
            // xray 的 DNS 上游写法 `tcp://` 正好是"用 TCP 查这个地址"。
            let address = relay != nil ? "tcp://\(ip)" : ip
            servers.append([
                "address": address,
                "port": 53,
                "domains": domesticMatch
            ] as [String: Any])
        }
        servers.append(contentsOf: overseasResolvers as [Any])

        return [
            // dns 模块发出的上游查询打标，routing 首两条按 inboundTag 分流
            "tag": "dns-module",
            "servers": servers,
            // 只查 A：不返回 IPv6 地址。配合下面只有 IPv4 的假 IP 池，
            // App 侧拿不到 AAAA，不会去试 IPv6 直连。
            "queryStrategy": "UseIPv4"
        ]
    }

    /// 只有 IPv4 假 IP 池 —— 恒定的「不返回 IPv6 地址」。
    public func fakeDNS() -> [[String: Any]] {
        [["ipPool": "198.18.0.0/15", "poolSize": 65535] as [String: Any]]
    }

    // MARK: - Compose

    /// 拼出可直接喂给 XrayCore.run 的完整配置。TUN inbound 与通用 compose 保持一致：
    /// MTU 1500、开 sniffing（fake-ip 反查域名靠它）。
    public func compose(
        accessLogPath: String? = nil,
        tunInterfaceName: String = "utun",
        metricsPort: Int? = nil,
        publicIPPort: Int? = nil
    ) throws -> [String: Any] {
        guard !exitNode.host.isEmpty else { throw PlanError.missingExitNode }
        if exitNode.host == hopNode.host, exitNode.port == hopNode.port,
           exitNode.protocolType == hopNode.protocolType {
            throw PlanError.hopEqualsExit
        }

        var routing = routing()
        var inbounds: [[String: Any]] = [[
            "tag": "tun-in",
            "protocol": "tun",
            "settings": ["name": tunInterfaceName, "mtu": 1500] as [String: Any],
            "sniffing": [
                "enabled": true,
                "destOverride": ["fakedns", "http", "tls", "quic"],
                "routeOnly": false
            ] as [String: Any]
        ]]

        if let metricsPort {
            inbounds.append([
                "tag": "metrics-in", "protocol": "dokodemo-door",
                "listen": "127.0.0.1", "port": metricsPort,
                "settings": ["address": "127.0.0.1"] as [String: Any]
            ])
            var rules = (routing["rules"] as? [[String: Any]]) ?? []
            rules.insert(["type": "field", "inboundTag": ["metrics-in"], "outboundTag": "metrics"], at: 0)
            routing["rules"] = rules
        }

        // 固定目标的「出口 IP」探针入口：只能连 PublicIPProbe.host，不能当通用代理用。
        // 必须排在所有路由规则之前 —— 验收要看的是「出口是谁」，不能被分流规则改道。
        if let publicIPPort, (1...65535).contains(publicIPPort) {
            inbounds.append([
                "tag": "public-ip-in", "protocol": "dokodemo-door",
                "listen": "127.0.0.1", "port": publicIPPort,
                "settings": ["address": PublicIPProbe.host, "port": 443, "network": "tcp"] as [String: Any]
            ])
            var rules = (routing["rules"] as? [[String: Any]]) ?? []
            rules.insert(["type": "field", "inboundTag": ["public-ip-in"], "outboundTag": Tag.exit], at: 0)
            routing["rules"] = rules
        }

        var logSection: [String: Any] = ["loglevel": "warning"]
        if let accessLogPath, !accessLogPath.isEmpty { logSection["access"] = accessLogPath }

        var config: [String: Any] = [
            "log": logSection,
            "inbounds": inbounds,
            "outbounds": try outbounds(),
            "routing": routing,
            "dns": dns(),
            "fakedns": fakeDNS()
        ]

        if metricsPort != nil {
            config["stats"] = [:] as [String: Any]
            config["policy"] = ["system": [
                "statsOutboundUplink": true, "statsOutboundDownlink": true
            ] as [String: Any]]
            config["metrics"] = ["tag": "metrics"]
        }
        return config
    }

    public func composeJSON(accessLogPath: String? = nil,
                            tunInterfaceName: String = "utun",
                            metricsPort: Int? = nil,
                            publicIPPort: Int? = nil) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: try compose(accessLogPath: accessLogPath,
                                        tunInterfaceName: tunInterfaceName,
                                        metricsPort: metricsPort,
                                        publicIPPort: publicIPPort),
            options: [.sortedKeys]
        )
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - 小工具

    /// 是否是字面 IP（不需要走 DNS 解析）。
    static func isIPLiteral(_ s: String) -> Bool {
        ipLiteral(from: s) != nil
    }

    /// 从 `8.8.8.8` / `tcp://8.8.8.8` / `https://...` 里取出字面 IP；不是 IP 返回 nil。
    static func ipLiteral(from s: String) -> String? {
        var v = s
        if let range = v.range(of: "://") { v = String(v[range.upperBound...]) }
        // 去掉可能的路径（DoH 地址形如 1.1.1.1/dns-query）
        if let slash = v.firstIndex(of: "/") { v = String(v[..<slash]) }
        if let colon = v.firstIndex(of: ":"), v.contains("]") == false, !v.contains("::") {
            // host:port 形式（IPv4 才会走到这里）
            v = String(v[..<colon])
        }
        var v4 = in_addr()
        if inet_pton(AF_INET, v, &v4) == 1 { return v }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, v, &v6) == 1 { return v }
        return nil
    }
}
