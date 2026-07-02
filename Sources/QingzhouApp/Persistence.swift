import Foundation
import QingzhouCore
import QingzhouLogging

/// 把订阅 / 节点 / 自定义规则 / 设置等持久化到磁盘。
///
/// 选择：
/// - 用 JSON 文件而非 UserDefaults：UserDefaults 对 macOS 沙箱 / iOS 都可用，但调试时不易直接看；
///   JSON 文件清晰，必要时还能手动编辑。
/// - 文件用 `.atomic` 写入：避免写到一半 app 被 kill 导致下次启动读到半截 JSON。
/// - **写入异步化**：使用串行 dispatch queue。AppState 调 `saveSnapshotAsync` 不阻塞主线程；
///   测试用 `saveSnapshot` 同步版。订阅有几百节点时，JSON 编码 + 落盘需要 50–100ms，
///   原来在主线程做导致点「刷新」时整个 UI 卡顿。
public final class Persistence: @unchecked Sendable {
    private let directory: URL
    private let saveQueue = DispatchQueue(label: "vpn.persistence.save", qos: .utility)

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// 默认存储位置：macOS 用 `~/Library/Application Support/VPN`；iOS 用 `Documents/VPN`。
    public static func defaultDirectory() -> URL {
        let fm = FileManager.default
        #if os(macOS)
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        #else
        let base = fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        #endif
        return base.appendingPathComponent("VPN", isDirectory: true)
    }

    // MARK: - 通用

    private func url(for name: String) -> URL {
        directory.appendingPathComponent(name).appendingPathExtension("json")
    }

    public func save<T: Encodable>(_ value: T, name: String) throws {
        let data = try makeEncoder().encode(value)
        try data.write(to: url(for: name), options: [.atomic])
    }

    public func load<T: Decodable>(_ type: T.Type, name: String) -> T? {
        let url = url(for: name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? makeDecoder().decode(T.self, from: data)
    }

    public func delete(name: String) {
        try? FileManager.default.removeItem(at: url(for: name))
    }

    /// 通用异步保存：编码 + 写盘都在后台串行队列，主线程立即返回。
    /// 用于 Snapshot 之外的独立文件（如 domain-history）。失败静默，取舍同 saveSnapshotAsync。
    public func saveAsync<T: Encodable & Sendable>(_ value: T, name: String) {
        saveQueue.async { [self] in
            try? save(value, name: name)
        }
    }

    // MARK: - 业务接口

    public struct Snapshot: Codable, Sendable {
        public var subscriptions: [Subscription]
        public var nodes: [Node]
        public var customRules: [Rule]
        public var settings: Settings
        public var currentNodeId: UUID?

        public init(
            subscriptions: [Subscription] = [],
            nodes: [Node] = [],
            customRules: [Rule] = [],
            settings: Settings = Settings(),
            currentNodeId: UUID? = nil
        ) {
            self.subscriptions = subscriptions
            self.nodes = nodes
            self.customRules = customRules
            self.settings = settings
            self.currentNodeId = currentNodeId
        }
    }

    public func saveSnapshot(_ snapshot: Snapshot) throws {
        try save(snapshot, name: "state")
    }

    /// 异步版本：序列化 + 写盘都在 utility QoS 的串行队列里跑，主线程立即返回。
    /// AppState.persist() 用这个，避免点「订阅刷新」时主线程卡 50–100ms。
    public func saveSnapshotAsync(_ snapshot: Snapshot) {
        let captured = snapshot   // value copy, snapshot is all `var` POD
        saveQueue.async { [self] in
            do {
                try save(captured, name: "state")
            } catch {
                // 落盘失败：日志已经在 AppState 那边处理；这里静默重试不靠谱，跳过
            }
        }
    }

    /// 阻塞等所有 pending 的异步保存都落盘。测试或 app 退出前调。
    /// 名字带 "ForTesting" 是为了让生产代码读到这名字就知道不该用。
    public func waitForPendingWritesForTesting() {
        saveQueue.sync { }
    }

    public func loadSnapshot() -> Snapshot {
        load(Snapshot.self, name: "state") ?? Snapshot()
    }
}
