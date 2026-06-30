import Foundation

/// 单个代理节点 —— 由订阅链接或手动添加产生。
///
/// 设计原则：
/// - 协议无关字段（host/port/name）显式建模；
/// - 协议特有字段（uuid/alterId/sni/path/...）放进 `parameters` 字典，避免每加一个协议就改结构体；
/// - 测速结果、排除标记是「运行时状态」，与节点身份正交。
public struct Node: Identifiable, Codable, Sendable, Hashable {
    /// 节点在本地的稳定 id。订阅刷新时如果识别为同一节点，会沿用旧 id。
    public var id: UUID
    public var name: String
    public var protocolType: ProxyProtocol
    public var host: String
    public var port: Int
    public var password: String?          // trojan / ss / hysteria2
    public var uuid: String?              // vmess / vless
    public var cipher: String?            // ss method / vmess scy
    public var alterId: Int?              // vmess
    public var parameters: [String: String]
    public var isExcluded: Bool           // 是否排除在自动择优外
    public var lastLatencyMs: Int?        // 最近一次测速延迟（毫秒），nil 表示未测或失败
    public var lastTestedAt: Date?
    public var subscriptionId: UUID?      // 来自哪条订阅；nil 表示手动添加

    public init(
        id: UUID = UUID(),
        name: String,
        protocolType: ProxyProtocol,
        host: String,
        port: Int,
        password: String? = nil,
        uuid: String? = nil,
        cipher: String? = nil,
        alterId: Int? = nil,
        parameters: [String: String] = [:],
        isExcluded: Bool = false,
        lastLatencyMs: Int? = nil,
        lastTestedAt: Date? = nil,
        subscriptionId: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.protocolType = protocolType
        self.host = host
        self.port = port
        self.password = password
        self.uuid = uuid
        self.cipher = cipher
        self.alterId = alterId
        self.parameters = parameters
        self.isExcluded = isExcluded
        self.lastLatencyMs = lastLatencyMs
        self.lastTestedAt = lastTestedAt
        self.subscriptionId = subscriptionId
    }
}

extension Node {
    /// 节点身份指纹：协议 + host + port + 凭据。用于订阅刷新时去重 / 保留测速结果。
    public var identityFingerprint: String {
        let credential = password ?? uuid ?? ""
        return "\(protocolType.rawValue)://\(credential)@\(host):\(port)"
    }

    /// 从节点名识别出的地区（统一中文名）；识别不出为「其它」。用于地区维度的排除 / 优先。
    public var region: String {
        RegionDetector.regionOrOther(for: name)
    }
}

public enum NodeSortOrder: String, Codable, Sendable {
    case name           // 按名称升序
    case latency        // 按最近测速延迟升序，未测/失败排末尾
}
