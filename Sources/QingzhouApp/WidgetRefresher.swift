import Foundation
import WidgetKit

/// 让系统刷新轻舟的所有小组件（主屏 / 锁屏 / 通知中心 / iOS 18 控制中心）。
///
/// Widget 的时间线是拉模型：VPN 状态变了 widget 自己不知道，必须由「知道状态变了的一方」
/// 主动踢一脚。集成点：**主 App 在 isVPNRunning 变化处（连接成功 / 断开 / 热切换完成）调
/// `WidgetRefresher.reload()`** —— 调用本身很便宜（只是给 WidgetKit 发个通知），
/// 多调无害，WidgetKit 自己有刷新预算节流。
///
/// 独立成文件（而不是塞进 AppState）：widget 扩展进程也 link QingzhouApp，
/// 这个 helper 两边都能用；且不与 AppState 的并行改动冲突。
public enum WidgetRefresher {
    public static func reload() {
        WidgetCenter.shared.reloadAllTimelines()
        #if os(iOS)
        // iOS 18 控制中心的 Control 不走 timeline，要单独刷新其取值（ControlValueProvider）
        if #available(iOS 18.0, *) {
            ControlCenter.shared.reloadAllControls()
        }
        #endif
    }
}
