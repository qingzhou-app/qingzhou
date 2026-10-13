import Foundation
import CryptoKit

/// 扩展成功应用后发布的配置身份。独立于界面选择和系统保存的下次启动配置。
/// 只含展示元数据与身份摘要，不把节点凭据写进会话标记。
public struct AppliedTunnelConfiguration: Codable, Sendable, Equatable {
    public let id: UUID
    public let requestID: UUID?
    public let nodeID: UUID
    public let nodeName: String
    public let protocolType: ProxyProtocol
    public let identityDigest: String
    public let mode: ProxyMode
    public let blockQUIC: Bool
    /// 实际用于配置生成的有序用户规则摘要；旧扩展缺此字段时保持未知。
    public let rulesDigest: String?

    public init(node: Node, mode: ProxyMode, blockQUIC: Bool, requestID: UUID? = nil,
                rulesDigest: String? = nil) {
        id = UUID()
        self.requestID = requestID
        nodeID = node.id
        nodeName = node.name
        protocolType = node.protocolType
        identityDigest = Self.digest(node)
        self.mode = mode
        self.blockQUIC = blockQUIC
        self.rulesDigest = rulesDigest
    }

    public func matches(_ node: Node) -> Bool {
        node.id == nodeID && Self.digest(node) == identityDigest
    }

    /// 排序影响first-match，UUID/注释不影响规则。长度前缀避免规则边界歧义。
    public static func digestRules(_ rules: [Rule]) -> String {
        var data = Data()
        for rule in rules {
            let bytes = Data(rule.lineForm.utf8)
            data.append(contentsOf: "\(bytes.count):".utf8)
            data.append(bytes)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func digest(_ node: Node) -> String {
        SHA256.hash(data: Data(node.identityFingerprint.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}
