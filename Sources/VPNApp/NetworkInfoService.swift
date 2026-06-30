import Foundation
import VPNLogging

/// 拉取当前公网 IP 与地理 / ISP 信息。
///
/// 用 ipapi.co —— 免费、无 key、有 CORS。它每天有 1000 次免费上限，对桌面 app 足够。
/// 注意：当 VPN 开启时这里返回的是代理节点出口的 IP；关闭时是用户当前的 IP。
public actor NetworkInfoService {
    private let session: URLSession
    private let logger: VPNLogging.Logger?

    public init(session: URLSession = .shared, logger: VPNLogging.Logger? = nil) {
        self.session = session
        self.logger = logger
    }

    public func fetchPublicIPInfo() async throws -> PublicIPInfo {
        let url = URL(string: "https://ipapi.co/json/")!
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, _) = try await session.data(for: req)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ip = obj["ip"] as? String else {
            throw NSError(domain: "NetworkInfoService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Bad JSON shape"])
        }
        return PublicIPInfo(
            ip: ip,
            country: obj["country_name"] as? String,
            region: obj["region"] as? String,
            city: obj["city"] as? String,
            isp: obj["org"] as? String,
            fetchedAt: Date()
        )
    }
}

extension AppState {
    public func refreshPublicIPInfo() async {
        let svc = NetworkInfoService(logger: logger)
        do {
            let info = try await svc.fetchPublicIPInfo()
            publicIPInfo = info
            // VPN 开着查到的是节点出口 IP，关着是本机直连 IP。分别缓存，首页并排对比。
            if isVPNRunning { proxyIPInfo = info } else { directIPInfo = info }
            logger.info("Public IP (\(isVPNRunning ? "proxy" : "direct")): \(info.ip)", category: "network")
        } catch {
            logger.warn("Fetch public IP failed: \(error)", category: "network")
        }
    }
}
