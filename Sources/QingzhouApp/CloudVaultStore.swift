import Foundation

/// iCloud Drive 文档容器的读写层（`VaultDocument` 的 IO）。
///
/// - 文件放在容器的 `Documents/` 子目录 —— 配合 Info.plist 的 `NSUbiquitousContainers`
///   （document scope public），用户能在「文件」App / Finder 的 iCloud Drive 里看到
///   「轻舟」文件夹和里面的 `qingzhou-vault.json`，这就是 vault 感。
/// - 读写都过 `NSFileCoordinator` —— iCloud 守护进程（brd / cloudd）也会动这个文件，
///   不协调可能读到半截内容。
/// - `containerProvider` 可注入：测试里指向临时目录即可全流程验证，不需要真 iCloud。
/// - `FileManager.url(forUbiquityContainerIdentifier:)` 官方要求别在主线程调（首次可能
///   要建容器目录，慢）；本类型是 actor，天然在后台执行。
public actor CloudVaultStore {
    /// iCloud 容器 id —— 必须与 project.yml 里两个主 App target 的
    /// `com.apple.developer.ubiquity-container-identifiers` 一致。
    public static let containerIdentifier = "iCloud.com.sbraveyoung.qingzhou"
    public static let fileName = "qingzhou-vault.json"

    public enum StoreError: LocalizedError {
        case unavailable
        public var errorDescription: String? { "iCloud 不可用（未登录或未开启 iCloud Drive）" }
    }

    private let containerProvider: @Sendable () -> URL?

    public init(containerProvider: (@Sendable () -> URL?)? = nil) {
        self.containerProvider = containerProvider ?? {
            FileManager.default.url(forUbiquityContainerIdentifier: Self.containerIdentifier)
        }
    }

    public func isAvailable() -> Bool {
        containerProvider() != nil
    }

    private func documentURL() -> URL? {
        guard let container = containerProvider() else { return nil }
        return container
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(Self.fileName)
    }

    public func loadHeader() throws -> VaultHeader? {
        guard let data = try readData() else { return nil }
        return try VaultDocument.decodeHeader(from: data)
    }

    public func loadDocument() throws -> VaultDocument? {
        guard let data = try readData() else { return nil }
        return try VaultDocument.decode(from: data)
    }

    public func save(_ document: VaultDocument) throws {
        guard let url = documentURL() else { throw StoreError.unavailable }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try document.encoded()

        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(
            writingItemAt: url, options: .forReplacing, error: &coordinationError
        ) { actualURL in
            do {
                try data.write(to: actualURL, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let error = coordinationError { throw error }
        if let error = writeError { throw error }
    }

    private func readData() throws -> Data? {
        guard let url = documentURL() else { throw StoreError.unavailable }
        let fm = FileManager.default
        // 云上有、本机还没下载（重装 / 新设备首启）：先触发下载。
        // 协调读会等下载完成；万一还没到位，本次读不到 → 当作没有文档，下次启动再试。
        if fm.isUbiquitousItem(at: url) {
            try? fm.startDownloadingUbiquitousItem(at: url)
        }
        var coordinationError: NSError?
        var readError: Error?
        var data: Data?
        NSFileCoordinator().coordinate(
            readingItemAt: url, options: [], error: &coordinationError
        ) { actualURL in
            guard fm.fileExists(atPath: actualURL.path) else { return }
            do {
                data = try Data(contentsOf: actualURL)
            } catch {
                readError = error
            }
        }
        if let error = coordinationError {
            // 文件不存在时部分系统会报 NSFileNoSuchFileError —— 等同「没有文档」
            if error.domain == NSCocoaErrorDomain,
               error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError {
                return nil
            }
            throw error
        }
        if let error = readError { throw error }
        return data
    }
}
