import Foundation

/// 探测阶段，而非节点永久故障归因。probeFailed 仍可能来自临时内核、网络或目标站点。
public enum ProxyProbeFailure: String, Codable, Sendable, Error {
    case resourceLimited, invalidConfiguration, invalidTarget, probeFailed, unavailable, cancelled, superseded
}

public struct ProxyProbeError: LocalizedError, Sendable {
    public let kind: ProxyProbeFailure
    public let message: String
    public init(kind: ProxyProbeFailure, message: String) { self.kind = kind; self.message = message }
    public var errorDescription: String? { message }
}

public enum ProxyProbeOutcome: Sendable, Equatable {
    case success(Int)
    case failure(ProxyProbeFailure)
    public var latency: Int? { if case .success(let ms) = self { return ms }; return nil }
}
