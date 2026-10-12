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
    ///   2. 端口回收误标（老连接被误标成后来复用同端口的 App）→ 已修（2026-07-07）：
    ///      关联键升级为**端口+时间窗**（扩展上报 flow 观测时刻，主 App 按
    ///      |seenAt − openedAt| ≤ 15s 认领，见 SourceAppMap）；backfill 仍只回填
    ///      **活跃**连接作第二道防线；
    ///   3. 需用户手动批准系统扩展，体验偏重 → 保持可选（opt-in）：设置 → macOS 集成里
    ///      一键启用 + 批准引导 toast；「应用」tab 空数据时给启用指引，不启用不打扰。
    /// 细节见 memory: macos-content-filter-runs-as-root-xpc、
    /// macos-system-extension-activation-gotchas。
    ///
    /// **2026-07-11 下线**（用户「先下线吧」）：上架冲刺期,随包带一个 system extension 会增加
    /// App Store 审核负担,且激活它要用户在系统设置两段批准、体验偏重 —— 先关掉。功能完整保留在
    /// 代码里；恢复时还须在project.yml重新嵌入Filter并恢复安装entitlement。关闭后:设置入口、域名分析「应用」视角、来源回填全部消失;
    /// 已激活过的老用户(目前只有开发机),macOS app 启动会自动 disable 遗留的 NEFilter
    /// (`deactivateRetiredContentFilterIfNeeded`),让扩展停止在后台过滤;system extension 的
    /// 注册残留良性(不再工作),想彻底移除去「系统设置 → 通用 → 登录项与扩展 → 网络扩展」。
    static let sourceAppLabeling = false

    /// 健康触发的无感故障切换 —— 编译期总开关（运行时 kill-switch）。
    ///
    /// 这是「功能在本 build 里是否存在」的闸：为 `true` 时暴露设置里的「节点故障提醒」
    /// 开关、允许连接页显示疑似故障横幅。真正的 **opt-in 默认关** 在
    /// `Settings.autoFailoverAlert`（默认 false，用户开了才请求通知权限）。
    ///
    /// 为什么两层：FAILOVER.md 的保守 MVP 要「Settings（opt-in）+ FeatureFlags（kill-switch）」。
    /// 现场若误报率过高，翻这里为 false 即可整功能下线（横幅、权限申请、设置项全消失），
    /// 无需改隧道扩展。首版设 true 让功能可被真机验收；扩展侧检测是被动零成本，且未授权
    /// 通知时扩展的 add 静默 no-op —— 关着这个开关的用户不会收到任何打扰。
    static let autoFailoverAlert = true
}
