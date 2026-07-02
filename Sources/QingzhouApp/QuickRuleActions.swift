import SwiftUI
import QingzhouCore

/// 「一键规则」上下文操作：域名分析页的域名行、连接页的连接行共用。
/// 按平台惯例挂载：iOS 长按菜单 + 左滑操作，macOS 右键菜单。
/// 动作本体是 `AppState.quickAddDomainRule`（生成 DOMAIN-SUFFIX 规则、去重/改目标、
/// 持久化 + 热切换、toast 反馈都在那边）。
struct QuickRuleActionsModifier: ViewModifier {
    let host: String
    let state: AppState

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .contextMenu { menuItems }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                // 左滑空间有限：只放文字按钮，色和路由徽章一致（直连绿/代理蓝/拒绝红）
                Button("直连") { state.quickAddDomainRule(forHost: host, target: .direct) }
                    .tint(.green)
                Button("代理") { state.quickAddDomainRule(forHost: host, target: .proxy) }
                    .tint(.blue)
                Button("拒绝") { state.quickAddDomainRule(forHost: host, target: .reject) }
                    .tint(.red)
            }
        #else
        content.contextMenu { menuItems }
        #endif
    }

    @ViewBuilder private var menuItems: some View {
        // 追踪器域名：把「拒绝」提到最前并标注推荐 —— 这是对追踪器最合理的动作
        let isTracker = TrackerDomains.isTracker(host)
        Section("为 \(DomainAnalyzer.registrableDomain(host)) 添加规则") {
            if isTracker {
                Button(role: .destructive) { state.quickAddDomainRule(forHost: host, target: .reject) } label: {
                    Label("加入拒绝（追踪器，推荐）", systemImage: "nosign")
                }
            }
            Button { state.quickAddDomainRule(forHost: host, target: .direct) } label: {
                Label("加入直连", systemImage: "arrow.down.right.circle")
            }
            Button { state.quickAddDomainRule(forHost: host, target: .proxy) } label: {
                Label("加入代理", systemImage: "arrow.up.right.circle")
            }
            if !isTracker {
                Button(role: .destructive) { state.quickAddDomainRule(forHost: host, target: .reject) } label: {
                    Label("加入拒绝", systemImage: "nosign")
                }
            }
        }
    }
}

extension View {
    /// 给列表行挂「加入直连 / 代理 / 拒绝」上下文操作。
    func quickRuleActions(host: String, state: AppState) -> some View {
        modifier(QuickRuleActionsModifier(host: host, state: state))
    }
}

/// toast 胶囊（浮层本体）。RootView 挂在根上；sheet（如域名分析页）会盖住根浮层，
/// 需要在 sheet 内容上再挂一份，否则 sheet 里触发的一键规则看不到任何反馈。
struct ToastCapsule: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(.secondary.opacity(0.2)))
            .shadow(radius: 8, y: 2)
            .padding(.top, 10)
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}

extension View {
    /// 在视图顶部挂 toast 浮层（观察 `state.toast`）。根视图与各 sheet 复用同一实现。
    func toastOverlay(state: AppState) -> some View {
        overlay(alignment: .top) {
            if let toast = state.toast { ToastCapsule(text: toast) }
        }
        .animation(.spring(duration: 0.3), value: state.toast)
    }
}
