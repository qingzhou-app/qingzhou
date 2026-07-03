import Foundation

/// 「定时关闭」的固定档位（秒）与展示文案。
///
/// 交互与同页「择优间隔」一致（Picker 固定档位，label 左、值右）。
/// 0 = 关闭是合法档位（区别于择优间隔 —— 这里开/关就在同一个 Picker 里）。
/// DEBUG 构建多一个「1 分钟」调试档，方便验收到点自停，不进 Release。
public enum AutoStopPresets {
    /// 全部档位，升序（秒）。0 = 关闭。
    public static let values: [TimeInterval] = {
        var v: [TimeInterval] = [
            0,
            30 * 60,
            60 * 60,
            2 * 60 * 60,
            4 * 60 * 60,
        ]
        #if DEBUG
        v.insert(60, at: 1)   // 调试档：1 分钟，快速验收到点自停
        #endif
        return v
    }()

    /// 任意存量值（iCloud 同步 / 手改 JSON）就近吸附到档位；
    /// 非法值（NaN / 无穷 / <= 0）一律回退「关闭」—— 定时关 VPN 宁可不启用也别猜。
    /// 差相同时取较小档（早点关，防忘关的初衷）。
    public static func nearest(to value: TimeInterval) -> TimeInterval {
        guard value.isFinite, value > 0 else { return 0 }
        return values.min { a, b in
            let da = abs(a - value)
            let db = abs(b - value)
            return da == db ? a < b : da < db
        } ?? 0
    }

    /// 档位文案（Picker 选项 / toast 共用）。
    public static func label(for seconds: TimeInterval) -> String {
        guard seconds > 0 else { return L("关闭") }
        if seconds < 60 * 60 {
            return L("\(Int(seconds / 60)) 分钟")
        }
        return L("\(Int(seconds / 3600)) 小时")
    }

    /// 剩余时间文案：< 1 小时用 mm:ss（如 29:59），≥ 1 小时用 h:mm（如 3:59）。
    /// 已过点 / 负值一律 "0:00"；不足整秒进位（剩 0.4 秒显示 0:01，不提前显示 0:00）。
    public static func remainingText(until deadline: Date, now: Date = Date()) -> String {
        let remaining = deadline.timeIntervalSince(now)
        let total = Int(max(0, remaining).rounded(.up))
        if total >= 3600 {
            return "\(total / 3600):" + String(format: "%02d", (total % 3600) / 60)
        }
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }
}
