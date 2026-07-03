// iOS 18 控制中心开关（ControlWidget）。iOS 专属：macOS 没有控制中心 Control。
//
// 部署目标是 iOS 17，所以整个类型标 @available(iOS 18.0, *)，由 WidgetBundle 里的
// `if #available` 决定是否注入（见 QingzhouWidgetBundle.swift）。
//
// ControlWidgetToggle 的 action 必须是 SetValueIntent（系统把目标开关值塞进 `value`
// 再调 perform），不能直接挂 ToggleVPNIntent（普通 AppIntent）—— 所以这里包一层
// SetQingzhouVPNIntent，内部转发给既有的 StartVPNIntent / StopVPNIntent。
// 开关显示值由 ControlValueProvider 拉取（读 NE preferences 的真实状态）；
// 主 App 侧 WidgetRefresher.reload() 里的 reloadAllControls() 会触发它重取。

#if os(iOS)
import AppIntents
import QingzhouApp
import SwiftUI
import WidgetKit

@available(iOS 18.0, *)
struct QingzhouVPNControl: ControlWidget {
    // 同 widget kind：系统持久化键，定死别动
    static let kind = "QingzhouVPNControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: Provider()) { isOn in
            ControlWidgetToggle(
                "轻舟 VPN",
                isOn: isOn,
                action: SetQingzhouVPNIntent()
            ) { on in
                Label(on ? "已连接" : "未连接",
                      systemImage: on ? "checkmark.shield.fill" : "shield.slash")
            }
        }
        .displayName("轻舟 VPN")
        .description("一键启停 VPN。")
    }

    struct Provider: ControlValueProvider {
        /// 控制中心编辑态的预览值
        var previewValue: Bool { false }

        func currentValue() async throws -> Bool {
            // connecting/disconnecting 的过渡态归入"开"——用户刚点开就显示开，符合直觉
            await VPNWidgetSnapshot.read().phase != .disconnected
        }
    }
}

/// ControlWidgetToggle 专用的 SetValueIntent 包装：开 → Start，关 → Stop。
/// 在 widget 扩展进程执行，依赖本 target 的 NE entitlement。
@available(iOS 18.0, *)
struct SetQingzhouVPNIntent: SetValueIntent {
    static let title: LocalizedStringResource = "设定轻舟 VPN"
    static let description = IntentDescription("开 = 连接上次使用的节点，关 = 断开。")

    @Parameter(title: "开启")
    var value: Bool

    func perform() async throws -> some IntentResult {
        if value {
            _ = try await StartVPNIntent().perform()
        } else {
            _ = try await StopVPNIntent().perform()
        }
        return .result()
    }
}
#endif
