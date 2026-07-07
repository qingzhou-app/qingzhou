// Widget 扩展入口（@main）。iOS / macOS 两个 widget target 共用这一份源码。
//
// iOS 18 的控制中心 Control 用嵌套 WidgetBundle 注入：
// WidgetBundleBuilder 的 `if #available` 分支（buildLimitedAvailability）要求内容是
// `some Widget`，而 ControlWidget 不是 Widget —— 直接写 `if #available { QingzhouVPNControl() }`
// 编不过。惯用解法：把 Control 包进一个 @available(iOS 18) 的子 bundle，
// 在可用性分支里展开它的 `.body`（类型是 some Widget，builder 收得下）。

import SwiftUI
import WidgetKit

@main
struct QingzhouWidgetBundle: WidgetBundle {
    var body: some Widget {
        QingzhouStatusWidget()
        #if os(iOS)
        // Live Activity（灵动岛/锁屏实时活动）—— 部署目标 iOS 17 ≥ 16.1，无需 if #available。
        QingzhouLiveActivity()
        if #available(iOSApplicationExtension 18.0, *) {
            QingzhouControlBundle().body
        }
        #endif
    }
}

#if os(iOS)
@available(iOS 18.0, *)
struct QingzhouControlBundle: WidgetBundle {
    var body: some Widget {
        QingzhouVPNControl()
    }
}
#endif
