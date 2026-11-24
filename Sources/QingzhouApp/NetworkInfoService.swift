import Foundation
import Network
import QingzhouCore
import QingzhouSpeedTest
import QingzhouLogging

/// Explicit-route IP lookup. Default traffic always uses the physical interface;
/// node traffic must supply the fixed-target endpoint acknowledged by the tunnel.
public actor NetworkInfoService {
    private let session: URLSession?
    public init(session: URLSession? = nil, logger: QingzhouLogging.Logger? = nil) {
        self.session = session
    }

    public func fetchPublicIPInfo() async throws -> PublicIPInfo {
        if let session {
            var request = URLRequest(url: URL(string: "https://\(PublicIPProbe.host)\(PublicIPProbe.path)")!)
            request.timeoutInterval = 8
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            return try Self.decode(data)
        }
        return try Self.decode(await PublicIPTransport.direct())
    }

    public func fetchProxyIPInfo(port: UInt16) async throws -> PublicIPInfo {
        try Self.decode(await PublicIPTransport.proxy(port: port))
    }

    static func decode(_ data: Data) throws -> PublicIPInfo {
        guard data.count <= PublicIPProbe.maximumResponseBytes,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["error"] as? Bool != true,
              obj["success"] as? Bool == true,
              let ip = obj["ip"] as? String,
              IPv4Address(ip) != nil || IPv6Address(ip) != nil else { throw URLError(.cannotParseResponse) }
        // ipwho.is 在同一次响应里还给了 country_code / timezone.id / 经纬度 ——
        // 白拿的信息，用来对齐界面语言与时间显示，不额外发请求。
        let tz = (obj["timezone"] as? [String: Any])?["id"] as? String
        return PublicIPInfo(ip: ip, country: obj["country"] as? String,
            region: obj["region"] as? String, city: obj["city"] as? String,
            isp: (obj["connection"] as? [String: Any])?["isp"] as? String, fetchedAt: Date(),
            countryCode: obj["country_code"] as? String,
            timezoneID: tz,
            latitude: obj["latitude"] as? Double,
            longitude: obj["longitude"] as? Double)
    }
}

extension AppState {
    public func refreshPublicIPInfo() async {
        if ScreenshotDemoMode.isActive { return }
        let service = NetworkInfoService()
        await refreshPublicIPInfo(direct: { try await service.fetchPublicIPInfo() }, proxy: { configurationID in
            let port = try await self.tunnelManager.publicIPEndpoint(configurationID: configurationID)
            let info = try await service.fetchProxyIPInfo(port: port)
            // A second acknowledgement rejects a switch/restart during the TLS request.
            guard try await self.tunnelManager.publicIPEndpoint(configurationID: configurationID) == port else {
                throw URLError(.networkConnectionLost)
            }
            return info
        })
    }

    func refreshPublicIPInfo(
        direct: @escaping @MainActor () async throws -> PublicIPInfo,
        proxy: @escaping @MainActor (UUID) async throws -> PublicIPInfo
    ) async {
        let token = UUID()
        ipRefreshGeneration = token
        let network = measurementNetworkID
        let configuration = isVPNRunning && appliedTunnelConfiguration?.mode != .direct ? appliedTunnelConfiguration?.id : nil
        directIPInfo = nil; proxyIPInfo = nil; publicIPInfo = nil
        directIPFailed = false; proxyIPFailed = false
        // Both requests run independently; failure of one never substitutes the other's result.
        let directTask = Task { @MainActor in
            do {
                let info = try await direct()
                guard !Task.isCancelled, self.ipRefreshGeneration == token, self.measurementNetworkID == network else { return }
                self.directIPInfo = info
                if !self.isVPNRunning || self.appliedTunnelConfiguration?.mode == .direct { self.publicIPInfo = info }
            } catch {
                guard self.ipRefreshGeneration == token, self.measurementNetworkID == network else { return }
                self.directIPFailed = true
                self.logger.warn("Direct public IP lookup failed", category: "network")
            }
        }
        let proxyTask = Task { @MainActor in
            guard let configuration else { return }
            do {
                let info = try await proxy(configuration)
                guard !Task.isCancelled, self.ipRefreshGeneration == token, self.measurementNetworkID == network,
                      self.isVPNRunning, self.appliedTunnelConfiguration?.id == configuration else { return }
                self.proxyIPInfo = info; self.publicIPInfo = info
            } catch {
                guard self.ipRefreshGeneration == token, self.measurementNetworkID == network,
                      self.appliedTunnelConfiguration?.id == configuration else { return }
                self.proxyIPFailed = true
                self.logger.warn("Node public IP lookup failed", category: "network")
            }
        }
        await withTaskCancellationHandler {
            await directTask.value
            await proxyTask.value
        } onCancel: { directTask.cancel(); proxyTask.cancel() }
    }

    func invalidatePublicIPInfo() {
        ipRefreshGeneration = UUID()
        directIPInfo = nil; proxyIPInfo = nil; publicIPInfo = nil
        directIPFailed = false; proxyIPFailed = false
    }
}
