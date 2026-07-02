import Foundation

/// iCloud vault —— 像 Obsidian 的 vault 一样，把配置（订阅 / 节点 / 规则 / 设置）镜像到
/// iCloud Drive 的文档容器里：**App 卸载不影响 iCloud 中的数据**，重装 / 换设备时提示恢复。
///
/// 设计（从简，冲突宁可问用户）：
/// - 本地仍是权威源（启动快、离线可用）；每次本地保存后异步镜像到云端。
/// - 云文档带单调递增的 `revision`；本机在 `vault-sync-state.json` 里记「我最后见过 / 写过
///   的云端 revision」。启动时云端 revision 更高（或本机从没同步过 —— 即卸载重装）→
///   提示用户「发现 iCloud 备份，恢复？」，**不做静默双向合并**。
/// - 恢复前先把本地快照备份成 `state-backup-before-restore.json`。
/// - 云文档是人类可读 JSON，带 `schemaVersion` 留升级余地；遇到比自己新的 schema
///   既不恢复（读不懂）也不镜像（别把新版数据盖了）。

// MARK: - 云文档格式

/// 云端 vault 文档：头部元数据 + 完整配置快照。
public struct VaultDocument: Codable, Sendable {
    /// 当前文档格式版本。字段有不兼容变化时 +1。
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var revision: Int
    public var modifiedAt: Date
    public var deviceName: String
    public var snapshot: Persistence.Snapshot

    public init(
        schemaVersion: Int = VaultDocument.currentSchemaVersion,
        revision: Int,
        modifiedAt: Date,
        deviceName: String,
        snapshot: Persistence.Snapshot
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.modifiedAt = modifiedAt
        self.deviceName = deviceName
        self.snapshot = snapshot
    }

    /// 人类可读（prettyPrinted + sortedKeys）—— 用户在「文件」/ Finder 里点开能看懂，
    /// sortedKeys 也让两台设备写出的字节序稳定。
    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return try e.encode(self)
    }

    public static func decode(from data: Data) throws -> VaultDocument {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(VaultDocument.self, from: data)
    }

    /// 只解码头部元数据 —— 即使 snapshot 是未来版本的未知结构也能读出 schemaVersion，
    /// 据此决定要不要拒绝恢复 / 镜像。
    public static func decodeHeader(from data: Data) throws -> VaultHeader {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(VaultHeader.self, from: data)
    }
}

/// 云文档的头部元数据（不含 snapshot）。启动检查 / 恢复提示只需要它。
public struct VaultHeader: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var revision: Int
    public var modifiedAt: Date
    public var deviceName: String

    public init(schemaVersion: Int, revision: Int, modifiedAt: Date, deviceName: String) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.modifiedAt = modifiedAt
        self.deviceName = deviceName
    }
}

/// 本机的同步进度（存本地 Persistence 目录，**不**上云 —— 每台设备各有一份）。
public struct VaultSyncState: Codable, Sendable {
    /// 本机最后写入 / 恢复过的云端 revision。
    public var lastSyncedRevision: Int
    public var lastSyncedAt: Date

    public init(lastSyncedRevision: Int, lastSyncedAt: Date) {
        self.lastSyncedRevision = lastSyncedRevision
        self.lastSyncedAt = lastSyncedAt
    }
}

// MARK: - 纯决策逻辑（可单测）

/// 启动检查的决策结果。
public enum VaultStartupAction: Equatable, Sendable {
    /// 云端没有文档 / 云端比本机记录还旧 → 把本地镜像上去。
    case mirrorLocal
    /// 云端比本机新（或本机从未同步过 —— 卸载重装 / 新设备）→ 提示用户恢复。
    case offerRestore(VaultHeader)
    /// 云端就是本机最后写的那份 → 什么都不用做。
    case alreadyInSync
    /// 云文档来自更新版本的 App → 不恢复也不覆盖，提示用户升级。
    case incompatibleCloud(schemaVersion: Int)
}

public enum VaultSyncLogic {
    /// 启动时对比云端头部与本机同步记录，决定动作。
    public static func startupAction(
        cloudHeader: VaultHeader?,
        lastSyncedRevision: Int?,
        currentSchemaVersion: Int = VaultDocument.currentSchemaVersion
    ) -> VaultStartupAction {
        guard let cloud = cloudHeader else { return .mirrorLocal }
        if cloud.schemaVersion > currentSchemaVersion {
            return .incompatibleCloud(schemaVersion: cloud.schemaVersion)
        }
        guard let last = lastSyncedRevision else {
            // 本机从没同步过、云端却有数据 —— 卸载重装 / 新设备的核心场景
            return .offerRestore(cloud)
        }
        if cloud.revision > last { return .offerRestore(cloud) }
        if cloud.revision < last { return .mirrorLocal }
        return .alreadyInSync
    }

    /// 下一次镜像要写的 revision：盖过云端和本机记录中较大者。
    /// （用户拒绝恢复后继续本地编辑 → 本地权威，必须盖过云端的更高 revision。）
    public static func nextRevision(cloudRevision: Int?, lastSyncedRevision: Int?) -> Int {
        max(cloudRevision ?? 0, lastSyncedRevision ?? 0) + 1
    }
}

// MARK: - UI 状态

/// 设置页「iCloud 同步」小节展示用的状态。
public enum CloudSyncStatus: Equatable, Sendable {
    /// 启动检查还没跑完。
    case unknown
    /// 用户关掉了同步开关。
    case disabled
    /// iCloud 不可用（未登录 / 关了 iCloud Drive）。
    case unavailable
    case syncing
    case synced(Date)
    /// 云文档来自更新版本的 App。
    case incompatibleCloud(schemaVersion: Int)
    case error(String)

    /// 设置页显示的文案。
    public var displayText: String {
        switch self {
        case .unknown: return "检查中…"
        case .disabled: return "已关闭"
        case .unavailable: return "iCloud 不可用（未登录或未开启 iCloud Drive）"
        case .syncing: return "同步中…"
        case .synced(let date):
            return "最近同步 " + date.formatted(date: .abbreviated, time: .shortened)
        case .incompatibleCloud:
            return "iCloud 数据来自更新版本的轻舟，请升级 App"
        case .error(let message): return "同步失败：\(message)"
        }
    }
}
