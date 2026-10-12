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

    public init(node: Node, mode: ProxyMode, blockQUIC: Bool, requestID: UUID? = nil) {
        id = UUID()
        self.requestID = requestID
        nodeID = node.id
        nodeName = node.name
        protocolType = node.protocolType
        identityDigest = Self.digest(node)
        self.mode = mode
        self.blockQUIC = blockQUIC
    }

    public func matches(_ node: Node) -> Bool {
        node.id == nodeID && Self.digest(node) == identityDigest
    }

    private static func digest(_ node: Node) -> String {
        SHA256.hash(data: Data(node.identityFingerprint.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}
