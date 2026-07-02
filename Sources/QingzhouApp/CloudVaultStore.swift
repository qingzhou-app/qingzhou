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
    /// 历史版本目录（容器 Documents/ 下），文件名 `qingzhou-vault-r<revision>-<device>.json`。
    /// 每次镜像同时落一份历史版本 —— 即使某台设备把「删空后的配置」推上主文档（LWW 陷阱），
    /// 旧版本仍能从这里找回。
    public static let backupsDirectoryName = "backups"
    /// 历史版本保留份数（按 revision 保最新的 N 份）。
    public static let maxBackups = 5
    private static let backupPrefix = "qingzhou-vault-r"

    public enum StoreError: LocalizedError, Equatable {
        case unavailable
        /// 云端有文档但本机还没下载完（新装机 / 重装首启常见）。调用方应稍后重试，
        /// **绝不能**把这种状态当「云端没有文档」而用本地（可能是空的）数据覆盖上去。
        case notYetDownloaded

        public var errorDescription: String? {
            switch self {
            case .unavailable: return "iCloud 不可用（未登录或未开启 iCloud Drive）"
            case .notYetDownloaded: return "iCloud 数据还在下载中，稍后再试"
            }
        }
    }

    /// backups/ 里的一个历史版本。
    public struct BackupEntry: Sendable, Equatable {
        public var fileName: String
        public var header: VaultHeader
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

        // 滚动历史版本：主文档写成功后同步落一份到 backups/，再裁剪到最近 N 份。
        // 尽力而为 —— 历史版本失败不影响主文档已写成功的事实。
        writeBackupCopy(data: data, document: document)
        pruneBackups()
    }

    // MARK: - 历史版本（滚动备份）

    private func backupsDirectoryURL() -> URL? {
        guard let container = containerProvider() else { return nil }
        return container
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(Self.backupsDirectoryName, isDirectory: true)
    }

    /// 设备名进文件名前清洗：路径分隔符 / 冒号 / 空白一律换成 "-"。
    private static func sanitizedDeviceName(_ name: String) -> String {
        let cleaned = String(name.map { ch -> Character in
            (ch.isLetter || ch.isNumber) ? ch : "-"
        })
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "device" : trimmed
    }

    private func writeBackupCopy(data: Data, document: VaultDocument) {
        guard let dir = backupsDirectoryURL() else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "\(Self.backupPrefix)\(document.revision)-\(Self.sanitizedDeviceName(document.deviceName)).json"
        let url = dir.appendingPathComponent(name)
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(
            writingItemAt: url, options: .forReplacing, error: &coordinationError
        ) { actualURL in
            try? data.write(to: actualURL, options: .atomic)
        }
    }

    /// 从备份文件名解析 revision（`qingzhou-vault-r<revision>-...`）。
    private static func revision(fromFileName name: String) -> Int? {
        guard name.hasPrefix(backupPrefix) else { return nil }
        let rest = name.dropFirst(backupPrefix.count)
        let digits = rest.prefix(while: \.isNumber)
        return digits.isEmpty ? nil : Int(digits)
    }

    /// 只保留 revision 最新的 `maxBackups` 份。
    private func pruneBackups() {
        guard let dir = backupsDirectoryURL(),
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return }
        let backups = names
            .compactMap { name -> (name: String, revision: Int)? in
                guard let rev = Self.revision(fromFileName: name) else { return nil }
                return (name, rev)
            }
            .sorted { $0.revision > $1.revision }
        guard backups.count > Self.maxBackups else { return }
        for stale in backups.dropFirst(Self.maxBackups) {
            let url = dir.appendingPathComponent(stale.name)
            var coordinationError: NSError?
            NSFileCoordinator().coordinate(
                writingItemAt: url, options: .forDeleting, error: &coordinationError
            ) { actualURL in
                try? FileManager.default.removeItem(at: actualURL)
            }
        }
    }

    /// 列出 backups/ 里的历史版本，按 revision 降序。读不出头部的文件跳过。
    public func listBackups() -> [BackupEntry] {
        guard let dir = backupsDirectoryURL(),
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return [] }
        // 新设备 / 重装：备份文件可能还是未下载的占位符，先触发下载（本轮读不到就先缺席）
        let fm = FileManager.default
        return names
            .filter { Self.revision(fromFileName: $0) != nil }
            .compactMap { name -> BackupEntry? in
                let url = dir.appendingPathComponent(name)
                if fm.isUbiquitousItem(at: url) {
                    try? fm.startDownloadingUbiquitousItem(at: url)
                }
                guard let data = try? Data(contentsOf: url),
                      let header = try? VaultDocument.decodeHeader(from: data)
                else { return nil }
                return BackupEntry(fileName: name, header: header)
            }
            .sorted { $0.header.revision > $1.header.revision }
    }

    /// 读取指定历史版本的完整文档。
    /// 未下载完（只有 .icloud 占位符）→ 抛 `notYetDownloaded`，**不**静默当「没找到」——
    /// 否则恢复流程会误报「iCloud 上没有备份」。
    public func loadBackupDocument(fileName: String) throws -> VaultDocument? {
        // 防路径穿越：只接受纯文件名
        guard !fileName.contains("/"), !fileName.contains(".."),
              let dir = backupsDirectoryURL()
        else { return nil }
        let url = dir.appendingPathComponent(fileName)
        let fm = FileManager.default
        if fm.isUbiquitousItem(at: url) {
            try? fm.startDownloadingUbiquitousItem(at: url)
        }
        var coordinationError: NSError?
        var data: Data?
        NSFileCoordinator().coordinate(
            readingItemAt: url, options: [], error: &coordinationError
        ) { actualURL in
            data = try? Data(contentsOf: actualURL)
        }
        guard let data else {
            let placeholder = dir.appendingPathComponent(".\(fileName).icloud")
            if fm.fileExists(atPath: placeholder.path) {
                throw StoreError.notYetDownloaded
            }
            return nil
        }
        return try VaultDocument.decode(from: data)
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
        if data == nil {
            // 读不到内容 ≠ 云端没有文档：可能只是还没从 iCloud 下载下来（占位符 .icloud 文件）。
            // 误判成「没有」会让启动检查走 mirrorLocal，用空的本地数据把云端盖掉。
            let placeholder = url.deletingLastPathComponent()
                .appendingPathComponent(".\(url.lastPathComponent).icloud")
            if fm.fileExists(atPath: placeholder.path) {
                throw StoreError.notYetDownloaded
            }
        }
        return data
    }
}
