import QingzhouCore

/// 真实扩展探测边界；AppState 保留测量写回、身份与取消保护。
@MainActor
public protocol ProxiedLatencyProbing {
    func pingNode(node: Node, targetURL: String?, timeoutSeconds: Int) async throws -> Int
}
