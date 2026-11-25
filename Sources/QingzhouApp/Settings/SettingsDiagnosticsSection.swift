import SwiftUI
import QingzhouCore

/// 诊断：隧道扩展进程的内存水位。iOS 对 NE 扩展有 50MB jetsam 硬上限，超限即"断流"——
/// 高速测速 / 大流量下载是竞品翻车的典型场景，这里给用户/开发者一个随时可查的数字。
///
/// 用 TimelineView **每秒自驱动重算**，不依赖任何数据变更就能走字 —— 于是
/// 「上次采样：N 秒前」这行读数把故障环节一劈两半：秒数持续增大 = 扩展没在写
/// （旧扩展进程没换新代码 / 写入失败）；秒数一直 ≤2 秒但数字不动 = 不可能
/// （数字和采样时间在同一个文件里）。「扩展尚未上报」= 文件根本不存在。
struct SettingsDiagnosticsSection: View {
    @Bindable var state: AppState

    var body: some View {
        Section("诊断") {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let mem = state.tunnelMemory {
                    let age = context.date.timeIntervalSince(mem.sampledAt)
                    let live = age <= 3
                    // footprint==0 && error != nil = 扩展在写但采样失败 —— 显示失败而不是"0 B"
                    let samplingFailed = mem.footprintBytes <= 0 && mem.error != nil
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent("扩展内存", value: live
                            ? (samplingFailed
                               ? L("采样失败")
                               : L("\(ByteFormatter.format(mem.footprintBytes)) · 峰值 \(ByteFormatter.format(mem.sessionPeakBytes))"))
                            : L("未在上报"))
                        Text(live && !samplingFailed
                            ? memoryCaption(mem)
                            : idleMemoryCaption(mem))
                            .font(.caption2)
                            .foregroundStyle(live && mem.warningCount > 0 ? .orange : .secondary)
                        // 采样诊断（扩展带出的失败/降级原因）—— 用户截图这一行就能远程定位
                        if let err = mem.error {
                            Text("采样诊断：\(err)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.orange)
                        }
                        Text("上次采样：\(Self.ageText(age))")
                            .font(.caption2)
                            .foregroundStyle(live ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent("扩展内存", value: L("暂无数据"))
                        Text("扩展尚未上报 —— 需 VPN 处于开启状态，且隧道扩展为最新版本（更新 App 后要关-开一次 VPN，运行中的旧扩展进程才会换成新代码）。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            #if os(iOS)
            // iOS tab 收敛到 5 个后「日志」不再占 tab，从这里 push 进去（macOS 侧栏有独立项）
            NavigationLink {
                LogsView(state: state)
            } label: {
                Label("日志", systemImage: "doc.text.magnifyingglass")
            }
            #endif
        }
    }

    /// 「上次采样」的人话时间差。负值（时钟偏差）并进"刚刚"。
    static func ageText(_ age: TimeInterval) -> String {
        if age < 2 { return L("刚刚") }
        if age < 60 { return L("\(Int(age)) 秒前") }
        if age < 3600 { return L("\(Int(age / 60)) 分钟前") }
        return L("\(Int(age / 3600)) 小时前")
    }

    private func memoryCaption(_ mem: TunnelMemoryStats) -> String {
        var parts: [String] = []
        if mem.limitBytes > 0 {
            let headroom = max(0, mem.limitBytes - mem.footprintBytes)
            parts.append(L("距 \(ByteFormatter.format(mem.limitBytes)) 上限余 \(ByteFormatter.format(headroom))"))
        } else {
            // macOS：NE 扩展没有 iOS 那条 50MB jetsam 硬上限，如实说，别让人找"余量"
            parts.append(L("无硬性内存上限"))
        }
        parts.append(L("历史最高 \(ByteFormatter.format(mem.allTimePeakBytes))"))
        if mem.warningCount > 0 {
            parts.append(L("本次会话越过 40 MB 告警线 \(mem.warningCount) 次"))
        }
        return parts.joined(separator: " · ")
    }

    /// 扩展没有实时上报时的内存说明行（上次会话峰值 + 历史最高 + 可选上限）。
    private func idleMemoryCaption(_ mem: TunnelMemoryStats) -> String {
        var line = L("上次会话峰值 \(ByteFormatter.format(mem.sessionPeakBytes)) · 历史最高 \(ByteFormatter.format(mem.allTimePeakBytes))")
        if mem.limitBytes > 0 {
            line += L("（上限 \(ByteFormatter.format(mem.limitBytes))）")
        }
        return line
    }
}
