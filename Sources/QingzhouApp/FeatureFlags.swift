import Foundation

/// 功能开关 —— 把「做了一半 / 暂时搁置」的功能入口和逻辑统一隔离在这里，
/// 想重启用时改成 true 即可，不用满仓库找注释。
enum FeatureFlags {
    /// 来源 App 标注（macOS content filter → 「连接」页显示每条流量由哪个 App 发起，
    /// 域名分析新增「应用」视角）。
    ///
    /// 状态：端到端已打通 —— 系统扩展激活 OK、XPC 传 map OK、真实 App 图标+名字 OK。
    /// 曾因三个问题搁置，现状与缓解：
    ///   1. 启用过滤前的老连接补不上 → 无解也无需解：归入「未知来源」分组，UI 明示语义
    ///      （「启用过滤前的连接 / 无法归属的系统流量」），不再假装能全量标注；
    ///   2. 端口回收误标（老连接被误标成后来复用同端口的 App）→ 缓解：backfill 只回填
    ///      **活跃**连接（已关闭的不再动；误标主要发生在关闭已久的行上）。摄入时的标注
    ///      用的是 access log 刚出现的新鲜端口，误标窗口本就极小。彻底修法仍是换更稳的
    ///      关联键（端口+建立时间），留作 TODO；
    ///   3. 需用户手动批准系统扩展，体验偏重 → 保持可选（opt-in）：设置 → macOS 集成里
    ///      一键启用 + 批准引导 toast；「应用」tab 空数据时给启用指引，不启用不打扰。
    /// TODO(source-app-labeling): 关联键升级为 端口+时间窗，进一步消除复用误标。
    /// 细节见 memory: macos-content-filter-runs-as-root-xpc、
    /// macos-system-extension-activation-gotchas。
    static let sourceAppLabeling = true
}
