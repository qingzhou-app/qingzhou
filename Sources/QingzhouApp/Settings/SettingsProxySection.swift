import SwiftUI
import QingzhouCore

struct SettingsProxySection: View {
    @Bindable var state: AppState

    var body: some View {
        Section("代理") {
            Picker("代理模式", selection: state.proxyModeBinding) {
                ForEach(ProxyMode.allCases, id: \.self) { m in
                    Text(label(for: m)).tag(m)
                }
            }
            Text("全程走虚拟网卡（TUN），整机流量自动经隧道转发，无需配置系统代理。")
                .font(.caption2).foregroundStyle(.secondary)
            Picker("阻断 QUIC", selection: state.quicPolicyBinding) {
                Text("自动").tag(QUICPolicy.auto)
                Text("强制开启").tag(QUICPolicy.alwaysBlock)
                Text("强制关闭").tag(QUICPolicy.neverBlock)
            }
            Text("自动：hysteria2 节点放行并实测，其余挡 QUIC 走 TCP")
                .font(.caption2).foregroundStyle(.secondary)
            // 当前 QUIC 运行态（隧道开着才显示）—— auto 档的「放行→实测→通过/改挡」过程
            // 从此在真机上可见，不再是黑箱。状态推导是 QingzhouCore 纯函数，见 docs/QUIC.md §9。
            if let quicStatus = state.quicRuntimeStatus {
                Text(Self.quicStatusText(quicStatus))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Picker("日志级别", selection: state.setting(\.logLevel)) {
                Text("DEBUG").tag("DEBUG")
                Text("INFO").tag("INFO")
                Text("WARN").tag("WARN")
                Text("ERROR").tag("ERROR")
            }
        }
    }

    /// QUIC 运行态 → 状态行文案。状态推导在 QingzhouCore（纯函数、有单测），这里只做文案映射。
    static func quicStatusText(_ status: QUICRuntimeStatus) -> String {
        switch status {
        case .forcedBlock:         return L("当前：已阻断 QUIC（策略强制开启）")
        case .forcedAllow:         return L("当前：放行 QUIC（策略强制关闭）")
        case .autoBlockedTCPBased: return L("当前：已阻断 QUIC（TCP 系协议节点）")
        case .autoProbing:         return L("当前：暂放行 QUIC，HTTP/3 实测中…")
        case .autoProbePassed:     return L("当前：放行 QUIC（HTTP/3 实测通过）")
        case .autoBrokenBlocked:   return L("当前：已阻断 QUIC（实测不通，已自动改挡）")
        }
    }

    private func label(for mode: ProxyMode) -> String {
        switch mode {
        case .global: return L("全局代理")
        case .rule:   return L("规则代理")
        case .direct: return L("直连")
        }
    }
}
