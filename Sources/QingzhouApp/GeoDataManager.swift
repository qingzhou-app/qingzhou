// GeoDataManager —— 完整版 geoip.dat 的下载 / 校验 / 版本管理（主 App 侧）。
//
// 背景：内置 geoip.dat 是精简版（only-cn-private，~1.5MB），外国 GEOIP 码的用户规则
// 会被 RoutingRuleConverter 跳过。本管理器把完整版（~20MB，全部国家码）下载到
// App Group `xray-data/` 目录，隧道扩展启动时优先使用它，并给 composer 传
// hasFullGeoIP=true 解锁全部 GEOIP 规则。
//
// 主备源（用户点名要的）：
//   主源 = 自建 qingzhou-app/geo-data releases（每周日从 v2fly 上游同步 + 官方 sha256 校验）
//   备源 = v2fly/geoip 官方 releases 直链
// 主源失败（超时 / 404 / 校验不过）自动切备源；UI 显示实际用了哪个源（info.sourceName）。
//
// 安全底线：sha256 校验不过**绝不落盘** —— 双源全挂时现有数据（完整版或内置精简版）原样保留。
// 校验和来自同源的 `.sha256sum` 资产（格式 "<hex>  <文件名>"，上游生成、我们的源转发布时
// 也逐个核对过官方校验和 —— 见 geo-data 仓库的 sync workflow）。

import Foundation
import Observation
import CryptoKit
import QingzhouCore

/// 下载抽象 —— 单测注入假实现避免真实出网。progress 回调 0...1（总大小未知时 nil）。
public protocol GeoDataDownloading: Sendable {
    func fetch(_ url: URL, progress: @escaping @Sendable (Double?) -> Void) async throws -> Data
}

/// 一个 geo 数据下载源（dat + 同源校验和）。
public struct GeoDataSource: Sendable, Equatable {
    public var id: String
    public var displayName: String
    public var datURL: URL
    public var checksumURL: URL

    public init(id: String, displayName: String, datURL: URL, checksumURL: URL) {
        self.id = id
        self.displayName = displayName
        self.datURL = datURL
        self.checksumURL = checksumURL
    }

    /// 默认主备源顺序：自建源在前，v2fly 官方兜底。
    /// `releases/latest/download/...` 是 GitHub 的稳定直链，始终指向最新一期。
    public static let defaultSources: [GeoDataSource] = [
        GeoDataSource(
            id: "qingzhou", displayName: "轻舟源",
            datURL: URL(string: "https://github.com/qingzhou-app/geo-data/releases/latest/download/geoip.dat")!,
            checksumURL: URL(string: "https://github.com/qingzhou-app/geo-data/releases/latest/download/geoip.dat.sha256sum")!
        ),
        GeoDataSource(
            id: "v2fly", displayName: "v2fly 官方",
            datURL: URL(string: "https://github.com/v2fly/geoip/releases/latest/download/geoip.dat")!,
            checksumURL: URL(string: "https://github.com/v2fly/geoip/releases/latest/download/geoip.dat.sha256sum")!
        )
    ]
}

/// 默认 URLSession 下载器。20MB 级文件 + 受限网络，超时给足（订阅那套 30s 的
/// resource 超时会把慢速下载掐死）；用 AsyncBytes 逐块累积来报真实进度。
public struct URLSessionGeoDownloader: GeoDataDownloading {
    private let session: URLSession

    public init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30    // 30s 无数据到达才算断
        cfg.timeoutIntervalForResource = 900  // 整个 20MB 最长 15 分钟
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        session = URLSession(configuration: cfg)
    }

    public func fetch(_ url: URL, progress: @escaping @Sendable (Double?) -> Void) async throws -> Data {
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let expected = http.expectedContentLength // 未知时 -1
        var data = Data()
        if expected > 0 { data.reserveCapacity(Int(expected)) }
        var sinceLastReport = 0
        for try await byte in bytes {
            data.append(byte)
            sinceLastReport += 1
            // 每 256KB 报一次进度，别把主线程刷爆
            if sinceLastReport >= 256 * 1024 {
                sinceLastReport = 0
                progress(expected > 0 ? Double(data.count) / Double(expected) : nil)
            }
        }
        progress(1.0)
        return data
    }
}

/// 完整版 geo 数据的下载与状态管理。@MainActor：状态直接驱动 SwiftUI。
@MainActor
@Observable
public final class GeoDataManager {

    /// 下载状态机 —— UI 按它画进度 / 错误。
    public enum Phase: Equatable {
        case idle
        /// 正在从某个源下载（progress 0...1，nil = 大小未知转菊花）
        case downloading(sourceName: String, progress: Double?)
        case verifying
        case failed(String)
    }

    /// 已下载完整版的元信息；nil = 从未成功下载（用内置精简版）。
    public private(set) var info: GeoDataInfo?
    public private(set) var phase: Phase = .idle
    /// checkForUpdate 的结果缓存：nil = 没查过/查失败，true = 远端有新数据。
    public private(set) var updateAvailable: Bool?
    /// 最近一次"检查更新"的人话结论（UI 直接显示）。
    public private(set) var lastCheckMessage: String?

    private let downloader: GeoDataDownloading
    private let directory: URL?
    private let sources: [GeoDataSource]

    /// - Parameters:
    ///   - downloader: 网络实现，测试注入假的。
    ///   - directory: dat 与 info 的落盘目录。默认 App Group `xray-data/`（与扩展侧
    ///     TunnelAppGroup.ensureWorkingDirectory 同一目录）；测试给临时目录。
    ///   - sources: 按优先级排列的下载源，默认 [轻舟源, v2fly 官方]。
    public init(
        downloader: GeoDataDownloading? = nil,
        directory: URL? = AppGroupStorage.xrayDataDirectoryURL,
        sources: [GeoDataSource] = GeoDataSource.defaultSources
    ) {
        self.downloader = downloader ?? URLSessionGeoDownloader()
        self.directory = directory
        self.sources = sources
        self.info = Self.loadInfo(from: directory)
    }

    // MARK: - 状态判定

    public var datFileURL: URL? { directory?.appendingPathComponent("geoip.dat") }
    private var infoFileURL: URL? { directory?.appendingPathComponent("geo-data-info.json") }

    /// 完整版是否真实就位：info 记录在 + 磁盘文件在 + 大小吻合。
    /// （扩展侧 PacketTunnelProvider.resolveGeoData 用同一判定标准 —— 两边必须一致，
    /// 否则 UI 说"已解锁"而扩展实际跳过规则。）
    public var hasFullGeoIP: Bool {
        guard let info, let url = datFileURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value else { return false }
        return size == info.sizeBytes
    }

    public var isDownloading: Bool {
        if case .downloading = phase { return true }
        if case .verifying = phase { return true }
        return false
    }

    // MARK: - 下载（主备切换在这）

    /// 依序尝试各源：拉校验和 → 拉 dat → sha256 比对 → 原子落盘 + 写 info。
    /// 任一环节失败换下一个源；全失败返回 false 并保留现有数据。
    @discardableResult
    public func downloadFullGeoIP() async -> Bool {
        guard !isDownloading else { return false }
        guard let directory, let datFileURL, let infoFileURL else {
            phase = .failed(L("App Group 容器不可用，无法保存 geo 数据"))
            return false
        }

        var failures: [String] = []
        for source in sources {
            // 源名会进 UI（进度条 / 失败详情），按 App 语言查表；info.sourceName 仍存原文（见下）
            let sourceLabel = L10n.lookup(source.displayName)
            phase = .downloading(sourceName: sourceLabel, progress: nil)
            do {
                // 1) 同源校验和（几十字节）：拿不到/格式不对 → 这个源直接作废
                let checksumData = try await downloader.fetch(source.checksumURL, progress: { _ in })
                guard let expectedSha = Self.parseChecksum(checksumData) else {
                    failures.append(L("\(sourceLabel)：校验和文件格式异常"))
                    continue
                }

                // 2) dat 本体，报进度
                let sourceName = sourceLabel
                let data = try await downloader.fetch(source.datURL, progress: { [weak self] p in
                    Task { @MainActor [weak self] in
                        guard let self, case .downloading = self.phase else { return }
                        self.phase = .downloading(sourceName: sourceName, progress: p)
                    }
                })

                // 3) sha256 校验 —— 不过绝不落盘
                phase = .verifying
                let actualSha = Self.sha256Hex(data)
                guard actualSha == expectedSha else {
                    failures.append(L("\(sourceLabel)：sha256 校验不匹配"))
                    continue
                }

                // 4) 原子落盘 + 记录元信息
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: datFileURL, options: [.atomic])
                let newInfo = GeoDataInfo(
                    sha256: actualSha,
                    sizeBytes: Int64(data.count),
                    sourceID: source.id,
                    sourceName: source.displayName
                )
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(newInfo).write(to: infoFileURL, options: [.atomic])

                info = newInfo
                updateAvailable = false
                phase = .idle
                return true
            } catch {
                failures.append(L("\(sourceLabel)：\(error.localizedDescription)"))
                continue
            }
        }

        // 双源全挂：现有数据原样保留，文案引导先开 VPN（geo 数据在 GitHub，受限网络直连不通）
        let detail = failures.joined(separator: L("；"))
        phase = .failed(L("下载失败（\(detail)）。若当前网络无法直连 GitHub，请先开启 VPN 后重试。"))
        return false
    }

    // MARK: - 检查更新

    /// 拉远端（主源优先，失败切备源）最新 sha256 与本地记录比较。
    /// - Returns: true = 有更新（或本地还没有完整版）；false = 已是最新；nil = 所有源都联不通。
    @discardableResult
    public func checkForUpdate() async -> Bool? {
        for source in sources {
            guard let data = try? await downloader.fetch(source.checksumURL, progress: { _ in }),
                  let remoteSha = Self.parseChecksum(data) else { continue }
            let has = hasFullGeoIP && info?.sha256 == remoteSha
            updateAvailable = !has
            let sourceLabel = L10n.lookup(source.displayName)
            lastCheckMessage = has ? L("已是最新（\(sourceLabel)）") : L("有新版本可下载（\(sourceLabel)）")
            return !has
        }
        lastCheckMessage = L("检查失败：无法连接任一数据源。若当前网络无法直连 GitHub，请先开启 VPN 后重试。")
        return nil
    }

    // MARK: - 工具

    /// 解析上游 `.sha256sum` 格式："<64位hex>  <文件名>"。防御 GitHub 404 返回 HTML 的情况。
    static func parseChecksum(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8),
              let token = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).first
        else { return nil }
        let sha = token.lowercased()
        guard sha.count == 64, sha.allSatisfy({ $0.isHexDigit }) else { return nil }
        return sha
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func loadInfo(from directory: URL?) -> GeoDataInfo? {
        guard let url = directory?.appendingPathComponent("geo-data-info.json"),
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(GeoDataInfo.self, from: data)
    }
}
