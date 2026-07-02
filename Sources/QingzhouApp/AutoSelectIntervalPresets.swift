import Foundation

/// 「择优间隔」的固定档位（秒）。
///
/// 交互与同页「自动测速」一致（Picker 固定档位，label 左、值右），但档位比它偏短：
/// 自动择优是「测速 + 主动切节点」，开它的用户通常希望网络变差后尽快切走，
/// 所以补了 5/15 分钟两个短档；上限 24 小时对齐「订阅自动刷新」。
/// 不设「关闭」档 —— 开/关由旁边的「自动择优时机」控制，别搞两处开关。
public enum AutoSelectIntervalPresets {
    /// 全部档位，升序（秒）。
    public static let values: [TimeInterval] = [
        5 * 60,
        15 * 60,
        30 * 60,
        60 * 60,
        6 * 60 * 60,
        24 * 60 * 60,
    ]

    /// 兜底默认档：30 分钟（与 `Settings.autoSelectIntervalSeconds` 的默认值一致）。
    public static let fallback: TimeInterval = 30 * 60

    /// 旧值就近回退。
    ///
    /// 旧版 UI 是 Stepper（60s 步进，60...86400），用户已存的值可能落在任意分钟上；
    /// 换成固定档位后不能崩、也不能让 Picker 空选。规则：
    /// - 取与旧值绝对差最小的档位；
    /// - 差相同时取较小档（择优更勤一点，宁多测不漏切）；
    /// - 非法值（NaN / 无穷 / <= 0）回退到默认 30 分钟。
    public static func nearest(to value: TimeInterval) -> TimeInterval {
        guard value.isFinite, value > 0 else { return fallback }
        return values.min { a, b in
            let da = abs(a - value)
            let db = abs(b - value)
            return da == db ? a < b : da < db
        } ?? fallback
    }
}
