import Foundation
import QingzhouCore
import QingzhouSpeedTest

/// 只保留允许分享的结构化字段；不保存 Node、URL、身份指纹或原始错误。
public struct NodeDiagnosticReport: Sendable, Equatable {
    public enum Conclusion: String, Sendable {
        case proxySucceeded, proxyFailed, proxyNotTested, inconclusive
    }
    public let protocolType: ProxyProtocol
    public let completedAt: Date
    public let directLatencyMs: Int?
    public let directFailure: DirectProbeFailure?
    public let proxyOutcome: ProxyProbeOutcome?
    public var conclusion: Conclusion {
        switch proxyOutcome {
        case .success: return .proxySucceeded
        case .failure(.probeFailed), .failure(.invalidConfiguration): return .proxyFailed
        case .failure: return .inconclusive
        case nil: return .proxyNotTested
        }
    }
    init(node: Node, direct: LatencyResult?, proxy: ProxyProbeOutcome?, at: Date) {
        protocolType = node.protocolType
        completedAt = at
        directLatencyMs = direct?.latencyMs
        directFailure = direct?.failure
        proxyOutcome = proxy
    }
    public var sanitizedText: String {
        let proxy: String
        switch proxyOutcome {
        case .success(let ms): proxy = "success:\(ms)ms"
        case .failure(let failure): proxy = failure.rawValue
        case nil: proxy = "not_tested"
        }
        return """
        Qingzhou node diagnostic v1
        time=\(completedAt.ISO8601Format())
        protocol=\(protocolType.rawValue)
        tcp_ms=\(directLatencyMs.map(String.init) ?? "unknown")
        tcp_status=\(protocolType.supportsTCPProbe ? (directFailure?.rawValue ?? (directLatencyMs == nil ? "unknown" : "connected")) : "not_applicable")
        proxy=\(proxy)
        conclusion=\(conclusion.rawValue)
        TCP connectivity does not prove proxy usability. Results apply only to this test and target.
        """
    }
    var directSummary: String {
        if !protocolType.supportsTCPProbe { return L("UDP 协议不适用 TCP 握手") }
        if let directLatencyMs { return "\(directLatencyMs) ms" }
        switch directFailure {
        case .syntheticAddress: return L("解析得到虚拟地址，未执行直连")
        case .dnsFailed: return L("系统 DNS 未返回可用地址")
        case .noPhysicalInterface, .networkUnavailable: return L("直连网络暂不可用")
        case .timeout: return L("TCP 握手超时")
        case .refused: return L("TCP 连接被拒绝")
        case .invalidEndpoint: return L("节点地址或端口无效")
        case .cancelled: return L("已取消")
        default: return L("TCP 连接未完成")
        }
    }
    var proxySummary: String {
        switch proxyOutcome {
        case .success(let ms): return "\(ms) ms"
        case .failure(.invalidConfiguration): return L("节点配置未通过内核校验")
        case .failure(.probeFailed): return L("代理链路测试失败")
        case .failure: return L("代理测试暂不可用，请稍后重试")
        case nil: return L("未测试，请先连接 VPN")
        }
    }
    var explanation: String {
        switch conclusion {
        case .proxySucceeded: return L("本次节点代理请求成功。结果仅代表当前网络和测试目标。")
        case .proxyFailed: return L("请检查节点凭据、传输配置及测试目标；TCP 连通不能证明代理可用。")
        case .proxyNotTested: return L("当前只有直连结果，连接 VPN 后可继续验证真实代理链路。")
        case .inconclusive: return L("本次未获得有效代理结果，不能据此判断节点故障。")
        }
    }
}
