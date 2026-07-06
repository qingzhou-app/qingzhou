import Foundation
import QingzhouCore

/// 「仅 IPv6 站点」探测器：对连接页出现的域名，经 DoH 查真实 A / AAAA 记录，
/// 只有 AAAA 的报给 AppState 打标（连接页「仅 IPv6」徽标 + 日志）。见 docs/IPV6.md。
///
/// 为什么必须走 DoH（HTTPS 443 的 JSON API）而不是普通 DNS：主 App 自己的 53 端口
/// 查询会被隧道拦进 fakedns、对**任何**域名都返回假 IPv4 —— 普通查询永远"有 A 记录"，
/// 探测就失效了。DoH 是普通 HTTPS 流量，拿到的是真实记录。
///
/// 端点：阿里（223.5.5.5）优先、Google（8.8.8.8）兜底 —— 都在 XrayConfigComposer
/// 的既有 DNS 名单里，不引入新的第三方。每个域名整个会话只查一次（成败都记账，
/// 网络失败不重试防抖动），串行意义上的低频（由调用方每轮限量喂入）+ 会话总量上限。
actor IPv6OnlyProber {

    /// 会话内最多探测的域名数 —— 防止极端浏览行为下无限探测。
    static let sessionLimit = 500

    private var checked: Set<String> = []
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    /// 没查过则查并返回判定；查过 / 超上限 / 网络失败返回 nil（失败也记账，不重试）。
    func classifyIfNew(host: String) async -> IPv6OnlyClassifier.Verdict? {
        guard checked.count < Self.sessionLimit, !checked.contains(host) else { return nil }
        checked.insert(host)
        guard let a = await query(host: host, type: "A"),
              let aaaa = await query(host: host, type: "AAAA") else { return nil }
        return IPv6OnlyClassifier.classify(aResponse: a, aaaaResponse: aaaa)
    }

    private func query(host: String, type: String) async -> Data? {
        for server in ["223.5.5.5", "8.8.8.8"] {
            var comps = URLComponents()
            comps.scheme = "https"
            comps.host = server
            comps.path = "/resolve"
            comps.queryItems = [.init(name: "name", value: host), .init(name: "type", value: type)]
            guard let url = comps.url else { continue }
            var req = URLRequest(url: url)
            req.setValue("application/dns-json", forHTTPHeaderField: "accept")
            if let (data, resp) = try? await session.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200 {
                return data
            }
        }
        return nil
    }
}
