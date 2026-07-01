#if os(macOS)
import Foundation

/// 主 App ↔ 内容过滤系统扩展 的 XPC 接口：查询「源端口 → bundle id」映射。
///
/// 为什么是 XPC 而不是 App Group 共享文件：内容过滤是 **system extension，以 root 运行**，
/// 它的 App Group 容器是 `/var/root/Library/Group Containers/...`，与主 App（用户身份）的
/// `~/Library/Group Containers/...` 不是同一个目录，共享文件互不可见。XPC 是 Apple 认可的
/// 跨权限 IPC，且 App Store 兼容。
///
/// 注意：扩展侧（`Apps/Filter-macOS/FilterIPC.swift`）有一份**同名同签名**的声明。XPC 靠
/// @objc selector 匹配接口，两份保持一致即可，不必共享同一模块（免得给精简的扩展塞进 VPNCore）。
@objc public protocol FilterControlProtocol {
    /// 回调返回当前活跃流的「源端口(String) → 发起进程 bundle id(String)」快照。
    func fetchPortMap(reply: @escaping ([String: String]) -> Void)
}

public enum FilterIPC {
    /// mach service 名 —— 必须以 App Group 为前缀，沙箱 App 才被允许查找它。
    /// 扩展 Info.plist 的 `NetworkExtension.NEMachServiceName` 要声明同一个值。
    public static let machServiceName = "group.com.sbraveyoung.qingzhou.filter"
}
#endif
