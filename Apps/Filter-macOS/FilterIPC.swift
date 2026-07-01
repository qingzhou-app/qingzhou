import Foundation

// 与主 App 侧 Sources/VPNCore/FilterIPC.swift 保持同名同签名。
// XPC 按 @objc selector 匹配接口，两份一致即可，扩展不必依赖 VPNCore（保持精简）。

@objc protocol FilterControlProtocol {
    func fetchPortMap(reply: @escaping ([String: String]) -> Void)
}

enum FilterIPC {
    /// 必须与扩展 Info.plist 的 NetworkExtension.NEMachServiceName 一致，且以 App Group 为前缀。
    static let machServiceName = "group.com.sbraveyoung.qingzhou.filter"
}
