import Foundation

/// 功能开关 —— 把「做了一半 / 暂时搁置」的功能入口和逻辑统一隔离在这里，
/// 想重启用时改成 true 即可，不用满仓库找注释。
enum FeatureFlags {
    /// 来源 App 标注（macOS content filter → 「连接」页显示每条流量由哪个 App 发起）。
    ///
    /// 状态：端到端已打通 —— 系统扩展激活 OK、XPC 传 map OK、真实 App 图标+名字 OK。
    /// 搁置原因：
    ///   1. 只有「启用过滤器之后」建立的连接能标注；启用前的老连接端口从没被抓到，补不上；
    ///   2. 端口会被系统回收，老连接可能被误标成后来复用该端口的 App（关联键需要更稳）；
    ///   3. 需要用户手动批准系统扩展，体验偏重。
    /// TODO(source-app-labeling): 换更稳的关联键（避免端口回收误标）、只标注活跃连接、
    ///   打磨图标/名字后再放开。细节见 memory:
    ///   macos-content-filter-runs-as-root-xpc、macos-system-extension-activation-gotchas。
    static let sourceAppLabeling = false
}
