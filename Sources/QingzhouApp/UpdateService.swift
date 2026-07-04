import Foundation
import QingzhouCore
import QingzhouSubscription
import QingzhouLogging

/// 查询 App Store 最新版本的抽象 —— 便于单测注入假实现，跳过真实出网。
public protocol AppStoreVersionLookup: Sendable {
    /// 未上架（resultCount 0）/ 网络失败 → 返回 nil（静默，调用方据此「不提示」）。
    func fetchLatest(bundleId: String, country: String) async -> AppStoreVersionInfo?
}

/// 用 iTunes Lookup API 查 App Store 最新版本，无需自建服务端：
/// `https://itunes.apple.com/lookup?bundleId=<id>&country=us`
///
/// 复用 `QingzhouSubscription` 的 `HTTPClient` 抽象（自带合理超时）。
/// 失败一律吞掉返回 nil —— 更新提醒是锦上添花，绝不能因为查询失败打扰用户或报错。
public struct AppStoreUpdateFetcher: AppStoreVersionLookup {
    private let client: HTTPClient
    private let logger: Logger?

    public init(client: HTTPClient = URLSessionHTTPClient(), logger: Logger? = nil) {
        self.client = client
        self.logger = logger
    }

    public func fetchLatest(bundleId: String, country: String = "us") async -> AppStoreVersionInfo? {
        guard var comps = URLComponents(string: "https://itunes.apple.com/lookup") else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "bundleId", value: bundleId),
            URLQueryItem(name: "country", value: country),
        ]
        guard let url = comps.url else { return nil }
        do {
            let (data, _) = try await client.get(url)
            return Self.parse(data)
        } catch {
            logger?.info("App update check failed (silent): \(error)", category: "app")
            return nil
        }
    }

    /// 解析 lookup 响应。`resultCount` 为 0 或 `results` 为空（未上架）→ nil。
    /// internal 供单测直接喂 JSON 断言。
    static func parse(_ data: Data) -> AppStoreVersionInfo? {
        struct Response: Decodable {
            let resultCount: Int
            let results: [Entry]
            struct Entry: Decodable {
                let version: String?
                let releaseNotes: String?
                let trackViewUrl: String?
            }
        }
        guard let resp = try? JSONDecoder().decode(Response.self, from: data),
              resp.resultCount > 0,
              let first = resp.results.first,
              let version = first.version, !version.isEmpty
        else {
            return nil
        }
        return AppStoreVersionInfo(
            version: version,
            releaseNotes: first.releaseNotes,
            trackViewURL: first.trackViewUrl.flatMap { URL(string: $0) }
        )
    }
}

extension AppState {
    /// 启动时静默检查 App Store 是否有新版本。
    /// 未上架（lookup resultCount 0）/ 网络失败 → 什么都不做、不报错、不打扰。
    /// bundleId / currentVersion 默认读 `Bundle.main`（各平台自动用各自 bundle id）；测试可显式传入。
    public func checkForAppUpdate(bundleId: String? = nil, currentVersion: String? = nil) async {
        let bid = bundleId ?? Bundle.main.bundleIdentifier ?? ""
        let current = currentVersion
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? ""
        guard !bid.isEmpty, !current.isEmpty else { return }

        guard let info = await updateFetcher.fetchLatest(bundleId: bid, country: "us") else {
            return   // 未上架 / 失败 → 不提示
        }
        guard UpdateChecker.shouldPrompt(
            latest: info.version, current: current, ignored: settings.ignoredUpdateVersion
        ) else { return }

        availableUpdate = AvailableUpdate(
            version: info.version,
            releaseNotes: info.releaseNotes,
            trackViewURL: info.trackViewURL
        )
        logger.info("App update available: \(info.version) (current \(current))", category: "app")
    }

    /// 用户点「忽略此版本」：记下该版本号并收起提示。
    /// 同一版本不再提示；出了更新的版本（语义化比较更大）才会再弹。
    public func ignoreUpdate(_ version: String) {
        settings.ignoredUpdateVersion = version
        persist()
        availableUpdate = nil
        logger.info("User ignored update \(version)", category: "app")
    }

    /// 用户点「稍后」/ 打开了 App Store：仅收起本次提示，不记忽略 —— 下次启动仍会再查再提示。
    public func dismissUpdate() {
        availableUpdate = nil
    }
}
