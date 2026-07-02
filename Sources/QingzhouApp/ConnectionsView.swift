import SwiftUI
import QingzhouCore

public struct ConnectionsView: View {
    @Bindable var state: AppState
    @State private var keyword: String = ""
    @State private var filter: ConnectionFilter = .active
    @State private var showDomainAnalysis = false

    enum ConnectionFilter: String, CaseIterable, Identifiable {
        case active = "活跃"
        case closed = "已关闭"
        case all = "全部"
        var id: String { rawValue }
    }

    public init(state: AppState) { self.state = state }

    public var body: some View {
        VStack(spacing: 0) {
            controls
            if filtered.isEmpty {
                ContentUnavailableView {
                    Label("暂无连接", systemImage: "antenna.radiowaves.left.and.right.slash")
                } description: {
                    Text("开启 VPN 后，这里会展示真实的访问记录。")
                }
                .frame(maxHeight: .infinity)
            } else {
                List(filtered) { c in
                    connectionRow(c)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("连接")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showDomainAnalysis = true } label: {
                    Label("域名分析", systemImage: "chart.pie")
                }
            }
        }
        .sheet(isPresented: $showDomainAnalysis) {
            NavigationStack {
                DomainAnalysisView(state: state)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { showDomainAnalysis = false }
                        }
                    }
            }
            // macOS 上 sheet 不给尺寸会缩成一个小空框（看起来"啥都没有"）——显式给最小尺寸。
            #if os(macOS)
            .frame(minWidth: 480, minHeight: 560)
            #endif
        }
        .searchable(text: $keyword, prompt: "搜索 host / route / app")
    }

    private var controls: some View {
        HStack {
            Picker("", selection: $filter) {
                ForEach(ConnectionFilter.allCases) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var filtered: [Connection] {
        let kw = keyword.lowercased()
        return state.connections.filter { c in
            let scopeOK: Bool
            switch filter {
            case .active: scopeOK = c.isActive
            case .closed: scopeOK = !c.isActive
            case .all:    scopeOK = true
            }
            let kwOK = kw.isEmpty
                || c.targetHost.lowercased().contains(kw)
                || c.route.lowercased().contains(kw)
                || c.matchedRule.lowercased().contains(kw)
                || (c.sourceApp?.lowercased().contains(kw) ?? false)
            return scopeOK && kwOK
        }
    }

    private func connectionRow(_ c: Connection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill(c.isActive ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(c.targetHost).font(.headline)
                Spacer()
                Text(c.type.rawValue.uppercased())
                    .font(.caption2.monospaced())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.18))
                    .clipShape(Capsule())
            }
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.swap").imageScale(.small)
                Text(c.matchedRule).font(.caption.monospaced()).lineLimit(1)
                Text("→ \(c.route)").font(.caption.monospaced())
                Spacer()
                // 字节/速率在接上 xray QueryStats 前没有真实来源（恒 0），先不显示假数字；
                // 接上后在这里恢复 upload/download 字节 + 速率展示。
                Text(c.openedAt.formatted(.relative(presentation: .named)))
                    .font(.caption2.monospaced())
            }
            .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                // 来源 app：macOS 由 content-filter 提供 bundle id，显示真实图标+名字；iOS 拿不到时省略。
                if let app = c.sourceApp, !app.isEmpty {
                    SourceAppLabel(bundleID: app)
                    Text("·")
                }
                Text("\(c.sourceAddress) → \(c.targetAddress)").lineLimit(1)
            }
            .font(.caption2.monospaced()).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
