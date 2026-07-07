import CryptoKit
import Foundation
import QingzhouCore

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
    /// 内容计数冗余在头部 —— 恢复确认弹窗 / 版本列表不用解码整个 snapshot 就能展示
    /// 「N 订阅 / M 节点」，用户看到「0 订阅」就不会误恢复空数据。optional：兼容旧文档。
    public var subscriptionCount: Int?
    public var nodeCount: Int?
    /// 规范化快照的内容哈希，冗余在头部 —— 启动检查不解码整个 snapshot 就能判断
    /// 「云端和本机的用户内容是否真的不同」，一致就静默采认 revision、不弹恢复确认。
    /// optional：兼容旧文档（旧文档由 AppState 回退读全文计算）。
    public var contentHash: String?
    public var snapshot: Persistence.Snapshot

    public init(
        schemaVersion: Int = VaultDocument.currentSchemaVersion,
        revision: Int,
        modifiedAt: Date,
        deviceName: String,
        snapshot: Persistence.Snapshot,
        contentHash: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.modifiedAt = modifiedAt
        self.deviceName = deviceName
        self.subscriptionCount = snapshot.subscriptions.count
        self.nodeCount = snapshot.nodes.count
        self.contentHash = contentHash
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

/// 云文档的头部元数据（不含 snapshot）。启动检查 / 恢复提示 / 版本列表只需要它。
public struct VaultHeader: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var revision: Int
    public var modifiedAt: Date
    public var deviceName: String
    /// 旧文档没有计数字段 → nil，UI 显示「内容数量未知」。
    public var subscriptionCount: Int?
    public var nodeCount: Int?
    /// 规范化快照的内容哈希（见 VaultDocument.contentHash）。旧文档 → nil。
    public var contentHash: String?

    public init(
        schemaVersion: Int,
        revision: Int,
        modifiedAt: Date,
        deviceName: String,
        subscriptionCount: Int? = nil,
        nodeCount: Int? = nil,
        contentHash: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.modifiedAt = modifiedAt
        self.deviceName = deviceName
        self.subscriptionCount = subscriptionCount
        self.nodeCount = nodeCount
        self.contentHash = contentHash
    }

    /// 恢复确认弹窗 / 版本列表展示的内容摘要 —— 让「空数据」一眼可见。
    public var contentSummary: String {
        guard let subs = subscriptionCount, let nodes = nodeCount else {
            return L("内容数量未知（旧版本文档）")
        }
        return L("\(subs) 个订阅 · \(nodes) 个节点")
    }
}

/// 一个可恢复的云端版本：主 vault 文档（`backupFileName == nil`）或 backups/ 里的历史版本。
public struct VaultRestoreCandidate: Equatable, Sendable, Identifiable {
    public var header: VaultHeader
    /// nil = 云端主文档；非 nil = `Documents/backups/` 下的历史版本文件名。
    public var backupFileName: String?
    /// 与本机当前配置的差异摘要（`VaultDiff.summaryText`）。生成候选时算好 —— alert 的
    /// message 在呈现瞬间就定格，事后补算刷不进去。读不到云端全文（下载中 / 解码失败）
    /// 时为 nil，确认弹窗降级为只显示云端计数。
    public var diffSummary: String?

    public var id: String { backupFileName ?? "main" }

    public init(header: VaultHeader, backupFileName: String? = nil, diffSummary: String? = nil) {
        self.header = header
        self.backupFileName = backupFileName
        self.diffSummary = diffSummary
    }
}

/// 「立即恢复」版本选择 sheet 的加载态。sheet 在点击的瞬间就呈现（.loading），
/// iCloud 读取（列备份要 coordinated read、甚至触发下载，秒级）异步完成后再填充 ——
/// 不能让用户对着按钮干等 sheet 出现。失败留在 sheet 内展示并可重试。
public enum CloudVersionLoadState: Equatable, Sendable {
    case loading
    case failed(String)
    case loaded([VaultRestoreCandidate])
}

/// 本机的同步进度（存本地 Persistence 目录，**不**上云 —— 每台设备各有一份）。
public struct VaultSyncState: Codable, Sendable {
    /// 本机最后写入 / 恢复过的云端 revision。
    public var lastSyncedRevision: Int
    public var lastSyncedAt: Date
    /// 上次成功镜像的**规范化**快照内容哈希 —— 内容没变就跳过镜像，
    /// 不产生新 revision、不挤掉滚动备份里有价值的历史。optional：兼容旧文件。
    public var lastMirroredContentHash: String?
    /// 用户最后一次点「暂不恢复」时的云端 revision —— 同一个 revision 不再重复弹
    /// （否则只要云端更新、本机又没编辑过，每次启动都弹）。云端出新 revision 才再提示。
    /// 镜像 / 恢复成功后重建同步状态时自然清空。optional：兼容旧文件。
    public var lastDeclinedRevision: Int?

    public init(
        lastSyncedRevision: Int,
        lastSyncedAt: Date,
        lastMirroredContentHash: String? = nil,
        lastDeclinedRevision: Int? = nil
    ) {
        self.lastSyncedRevision = lastSyncedRevision
        self.lastSyncedAt = lastSyncedAt
        self.lastMirroredContentHash = lastMirroredContentHash
        self.lastDeclinedRevision = lastDeclinedRevision
    }
}

// MARK: - 镜像内容规范化（可单测）

/// 上云前对快照做规范化：剥离**设备本地的瞬态字段**。
///
/// 动机（真机踩过）：自动测速 / 自动择优每 30 分钟改一次 `lastLatencyMs` / `currentNodeId`，
/// 订阅自动刷新每小时改一次 `lastUpdatedAt` / `usedBytes` —— 每次都 persist → 镜像 →
/// 新 revision + 新备份，5 份滚动备份很快全是「只有延迟数字不同」的雷同版本，
/// 把真正有价值的历史（比如删空前的配置）挤出去。
///
/// 剥离的字段（都没有跨设备同步价值，恢复时从本地回填 / 由设备自己重新产生）：
/// - `Node.lastLatencyMs` / `lastTestedAt` —— 延迟是「这台设备到节点」的瞬态测量
/// - `Snapshot.currentNodeId` —— 设备本地的运行时选择，且自动择优会频繁改它
/// - `Subscription.lastUpdatedAt` / `usedBytes` —— 本地拉取时刻 / 随流量消耗每次刷新必变
///   （`totalBytes` / `expiresAt` 保留：服务端事实，低频变化、有同步价值）
public enum VaultSnapshotNormalizer {
    public static func normalized(_ snapshot: Persistence.Snapshot) -> Persistence.Snapshot {
        var s = snapshot
        s.currentNodeId = nil
        s.nodes = s.nodes.map { node in
            var n = node
            n.lastLatencyMs = nil
            n.lastTestedAt = nil
            // 经代理延迟同为「这台设备经这条隧道」的瞬态测量（#11B 后补：漏剥会让每次
            // 经代理测速都产生新 revision，把恢复弹窗降噪的努力全吃掉）
            n.lastProxiedLatencyMs = nil
            n.lastProxiedTestedAt = nil
            // 观测带宽同为设备/网络本地量（跨设备无可比性，且更新频繁）—— 必须剥离
            n.observedPeakDownBps = nil
            n.observedBandwidthAt = nil
            return n
        }
        s.subscriptions = s.subscriptions.map { subscription in
            var sub = subscription
            sub.lastUpdatedAt = nil
            sub.usedBytes = nil
            return sub
        }
        return s
    }

    /// 规范化快照的稳定内容指纹（sortedKeys JSON 的 SHA-256）。
    /// 用于镜像去重：与上次成功镜像的哈希一致 → 跳过本次镜像。
    public static func contentHash(of snapshot: Persistence.Snapshot) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]   // 字节序稳定，哈希才可比
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - 恢复差异摘要（可单测）

/// 云端快照与本机快照的配置差异 —— 恢复确认弹窗用。只有云端计数（「N 订阅 · M 节点」）
/// 用户判断不了「恢复到底会改掉什么」；这里按身份键配对算出增 / 删 / 改，摘要成一行。
///
/// 方向约定：以「恢复云端会对本机做什么」为准 —— added = 云端有本机没有（恢复会加进来），
/// removed = 本机有云端没有（恢复会删掉）。
public struct VaultDiff: Equatable, Sendable {
    public var nodesAdded: Int
    public var nodesRemoved: Int
    public var nodesModified: Int
    public var subscriptionsAdded: Int
    public var subscriptionsRemoved: Int
    public var rulesAdded: Int
    public var rulesRemoved: Int
    public var rulesModified: Int
    /// 设置里值不同的字段数（按 JSON 顶层 key 比较 —— 新增字段自动纳入，不用维护清单）。
    public var settingsChanged: Int

    public init(
        nodesAdded: Int, nodesRemoved: Int, nodesModified: Int,
        subscriptionsAdded: Int, subscriptionsRemoved: Int,
        rulesAdded: Int, rulesRemoved: Int, rulesModified: Int,
        settingsChanged: Int
    ) {
        self.nodesAdded = nodesAdded
        self.nodesRemoved = nodesRemoved
        self.nodesModified = nodesModified
        self.subscriptionsAdded = subscriptionsAdded
        self.subscriptionsRemoved = subscriptionsRemoved
        self.rulesAdded = rulesAdded
        self.rulesRemoved = rulesRemoved
        self.rulesModified = rulesModified
        self.settingsChanged = settingsChanged
    }

    public var isEmpty: Bool {
        nodesAdded == 0 && nodesRemoved == 0 && nodesModified == 0
            && subscriptionsAdded == 0 && subscriptionsRemoved == 0
            && rulesAdded == 0 && rulesRemoved == 0 && rulesModified == 0
            && settingsChanged == 0
    }

    /// 计算两份快照的差异。**内部先各自过 VaultSnapshotNormalizer** —— 延迟 / 当前节点 /
    /// 订阅用量等瞬态字段是设备本地量，调用方忘了规范化就会满屏假「修改」，所以不交给调用方。
    public static func between(
        local: Persistence.Snapshot, cloud: Persistence.Snapshot
    ) -> VaultDiff {
        let l = VaultSnapshotNormalizer.normalized(local)
        let c = VaultSnapshotNormalizer.normalized(cloud)

        // 节点按身份指纹配对（与 restoreFromCloud 的瞬态回填同一配对方式）；
        // 指纹撞车（同协议同地址同凭据的重复节点）取第一个 —— 计数按唯一指纹算，够用。
        let localNodes = Dictionary(
            l.nodes.map { ($0.identityFingerprint, $0) }, uniquingKeysWith: { first, _ in first })
        let cloudNodes = Dictionary(
            c.nodes.map { ($0.identityFingerprint, $0) }, uniquingKeysWith: { first, _ in first })
        var nodesAdded = 0, nodesModified = 0
        for (fingerprint, cloudNode) in cloudNodes {
            guard let localNode = localNodes[fingerprint] else {
                nodesAdded += 1
                continue
            }
            if comparableNode(cloudNode) != comparableNode(localNode) { nodesModified += 1 }
        }
        let nodesRemoved = localNodes.keys.filter { cloudNodes[$0] == nil }.count

        // 订阅按 url 配对（url 即身份；名字 / 计数变化不算 —— 恢复不会丢订阅本身）
        let localSubURLs = Set(l.subscriptions.map(\.url))
        let cloudSubURLs = Set(c.subscriptions.map(\.url))

        // 规则先按 id 配对（同 id 内容变 = 修改）；两侧配不上 id 的再按 lineForm 兜底 ——
        // 删了重建 / 重新导入会换 id 但内容一字不差，那只是重建，不能吓用户「−1 +1」。
        let localRulesById = Dictionary(
            l.customRules.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let cloudRulesById = Dictionary(
            c.customRules.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var rulesModified = 0
        var cloudLeftover: [Rule] = []
        for rule in c.customRules {
            guard let paired = localRulesById[rule.id] else {
                cloudLeftover.append(rule)
                continue
            }
            if paired != rule { rulesModified += 1 }
        }
        // 多重集配对：本机剩余规则按 lineForm 计数，云端剩余逐条抵扣，抵不上的才是真新增
        var localLeftoverLineForms: [String: Int] = [:]
        for rule in l.customRules where cloudRulesById[rule.id] == nil {
            localLeftoverLineForms[rule.lineForm, default: 0] += 1
        }
        var rulesAdded = 0
        for rule in cloudLeftover {
            if let count = localLeftoverLineForms[rule.lineForm], count > 0 {
                localLeftoverLineForms[rule.lineForm] = count - 1   // lineForm 相同：重建，不算
            } else {
                rulesAdded += 1
            }
        }
        let rulesRemoved = localLeftoverLineForms.values.reduce(0, +)

        return VaultDiff(
            nodesAdded: nodesAdded, nodesRemoved: nodesRemoved, nodesModified: nodesModified,
            subscriptionsAdded: cloudSubURLs.subtracting(localSubURLs).count,
            subscriptionsRemoved: localSubURLs.subtracting(cloudSubURLs).count,
            rulesAdded: rulesAdded, rulesRemoved: rulesRemoved, rulesModified: rulesModified,
            settingsChanged: settingsChangedFieldCount(l.settings, c.settings)
        )
    }

    /// 一行摘要（alert message 空间有限，绝不换行）：
    /// 「与本机相比：节点 +3 −1 ~2 · 订阅 +1 · 规则 +2 · 设置 1 项变更」；
    /// 完全一致时「与本机配置一致」—— 明说没差异，用户不会被恢复弹窗吓到。
    public var summaryText: String {
        if isEmpty { return L("与本机配置一致") }
        var segments: [String] = []
        if let delta = Self.deltaToken(added: nodesAdded, removed: nodesRemoved, modified: nodesModified) {
            segments.append(L("节点 \(delta)"))
        }
        if let delta = Self.deltaToken(added: subscriptionsAdded, removed: subscriptionsRemoved, modified: 0) {
            segments.append(L("订阅 \(delta)"))
        }
        if let delta = Self.deltaToken(added: rulesAdded, removed: rulesRemoved, modified: rulesModified) {
            segments.append(L("规则 \(delta)"))
        }
        if settingsChanged > 0 {
            segments.append(L("设置 \(settingsChanged) 项变更"))
        }
        return L("与本机相比：\(segments.joined(separator: " · "))")
    }

    /// 「+3 −1 ~2」token：全为 0 → nil（该类别不出现在摘要里）。符号是数学记号，无需翻译。
    private static func deltaToken(added: Int, removed: Int, modified: Int) -> String? {
        var parts: [String] = []
        if added > 0 { parts.append("+\(added)") }
        if removed > 0 { parts.append("−\(removed)") }
        if modified > 0 { parts.append("~\(modified)") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// 「修改」判定用的可比形态：抹平设备本地生成的 id / subscriptionId（两台设备各自导入
    /// 同一订阅时它们必然不同，但不代表配置差异）；瞬态字段已在规范化时剥离。
    private static func comparableNode(_ node: Node) -> Node {
        var n = node
        n.id = UUID(uuid: UUID_NULL)
        n.subscriptionId = nil
        return n
    }

    /// 设置变更字段数：两份 Settings 各编码成 JSON 对象，比较顶层 key 的值。
    /// 不逐字段手写比较 —— Settings 加新字段时这里自动覆盖，不会漏。
    /// （同进程内相等的 Set 编码出的数组顺序一致，不会产生假差异。）
    private static func settingsChangedFieldCount(_ a: Settings, _ b: Settings) -> Int {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard
            let dataA = try? encoder.encode(a), let dataB = try? encoder.encode(b),
            let objectA = (try? JSONSerialization.jsonObject(with: dataA)) as? [String: Any],
            let objectB = (try? JSONSerialization.jsonObject(with: dataB)) as? [String: Any]
        else { return 0 }
        var changed = 0
        for key in Set(objectA.keys).union(objectB.keys) {
            switch (objectA[key], objectB[key]) {
            case (nil, nil):
                continue
            case let (valueA?, valueB?):
                // JSONSerialization 产物都是 NSNumber/NSString/NSArray/... —— isEqual 可比
                if !(valueA as AnyObject).isEqual(valueB as AnyObject) { changed += 1 }
            default:
                changed += 1
            }
        }
        return changed
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
    /// 云端 revision 更高，但**规范化内容与本机一致**（如另一台设备恢复历史版本后回推）
    /// → 静默采认云端 revision（更新本机同步记录），不打扰用户。
    case adoptCloudRevision(VaultHeader)
    /// 云端这个 revision 用户已明确「暂不恢复」过 → 不再重复弹，等云端出新 revision。
    case skipDeclinedRevision(VaultHeader)
    /// 云文档来自更新版本的 App → 不恢复也不覆盖，提示用户升级。
    case incompatibleCloud(schemaVersion: Int)
}

public enum VaultSyncLogic {
    /// 启动时对比云端头部与本机同步记录，决定动作。
    ///
    /// 弹窗降噪（当且仅当用户持久化内容真有差异才提示）：
    /// - `cloudContentHash` == `localContentHash` → 静默采认，绝不弹；
    /// - 该 revision 拒绝过（`lastDeclinedRevision`）→ 不再弹；
    /// - 任一哈希缺失（旧文档 / 计算失败）→ 无从比较，保守照旧提示。
    public static func startupAction(
        cloudHeader: VaultHeader?,
        lastSyncedRevision: Int?,
        lastDeclinedRevision: Int? = nil,
        cloudContentHash: String? = nil,
        localContentHash: String? = nil,
        currentSchemaVersion: Int = VaultDocument.currentSchemaVersion
    ) -> VaultStartupAction {
        guard let cloud = cloudHeader else { return .mirrorLocal }
        if cloud.schemaVersion > currentSchemaVersion {
            return .incompatibleCloud(schemaVersion: cloud.schemaVersion)
        }
        // lastSyncedRevision == nil：本机从没同步过、云端却有数据 —— 卸载重装 / 新设备，
        // 和「云端更新」一样走内容比对 → 提示恢复的流程。
        if let last = lastSyncedRevision {
            if cloud.revision < last { return .mirrorLocal }
            if cloud.revision == last { return .alreadyInSync }
        }
        let cloudHash = cloudContentHash ?? cloud.contentHash
        if let cloudHash, let localContentHash, cloudHash == localContentHash {
            return .adoptCloudRevision(cloud)
        }
        if let lastDeclinedRevision, cloud.revision == lastDeclinedRevision {
            return .skipDeclinedRevision(cloud)
        }
        return .offerRestore(cloud)
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
    /// 本机和 iCloud 都还没有数据（新装机、还没添加配置）—— 有数据后会自动开始镜像。
    case idle
    case syncing
    case synced(Date)
    /// 云文档来自更新版本的 App。
    case incompatibleCloud(schemaVersion: Int)
    case error(String)

    /// 设置页显示的文案。
    public var displayText: String {
        switch self {
        case .unknown: return L("检查中…")
        case .disabled: return L("未开启")
        case .unavailable: return L("iCloud 不可用（未登录或未开启 iCloud Drive）")
        case .idle: return L("尚无可同步的数据")
        case .syncing: return L("同步中…")
        case .synced(let date):
            return L("最近同步 \(date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale)))")
        case .incompatibleCloud:
            return L("iCloud 数据来自更新版本的轻舟，请升级 App")
        case .error(let message): return L("同步失败：\(message)")
        }
    }
}
