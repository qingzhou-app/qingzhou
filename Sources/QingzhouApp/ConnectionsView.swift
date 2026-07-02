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
        let result = filtered
        VStack(spacing: 0) {
            controls(hiddenIPCount: result.hiddenIPCount)
            if result.visible.isEmpty {
                ContentUnavailableView {
                    Label("暂无连接", systemImage: "antenna.radiowaves.left.and.right.slash")
                } description: {
                    if result.hiddenIPCount > 0 {
                        Text("「忽略 IP」已隐藏 \(result.hiddenIPCount) 条纯 IP 连接。")
                    } else {
                        Text("开启 VPN 后，这里会展示真实的访问记录。")
                    }
                }
                .frame(maxHeight: .infinity)
            } else {
                List(result.visible) { c in
                    connectionRow(c)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("连接")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                IgnoreIPToggle(state: state)
            }
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

    private func controls(hiddenIPCount: Int) -> some View {
        VStack(spacing: 4) {
            Picker("", selection: $filter) {
                ForEach(ConnectionFilter.allCases) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.segmented)
            // 过滤生效时的轻提示：避免用户忘了开着「忽略 IP」，以为数据丢了
            if hiddenIPCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "eye.slash").imageScale(.small)
                    Text("忽略 IP：已隐藏 \(hiddenIPCount) 条纯 IP 连接")
                }
                .font(.caption2)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    /// 三层过滤：状态（活跃/已关闭）→ 关键字 → 「忽略 IP」。
    /// `hiddenIPCount` 只统计前两层已命中、仅因裸 IP 被隐藏的条数，用于轻提示。
    private var filtered: (visible: [Connection], hiddenIPCount: Int) {
        let kw = keyword.lowercased()
        let hideIP = state.settings.hideBareIPConnections
        var visible: [Connection] = []
        var hiddenIP = 0
        for c in state.connections {
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
            guard scopeOK && kwOK else { continue }
            if hideIP && HostClassifier.isBareIP(c.targetHost) {
                hiddenIP += 1
                continue
            }
            visible.append(c)
        }
        return (visible, hiddenIP)
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
            }
            .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Label(ByteFormatter.format(c.uploadBytes), systemImage: "arrow.up")
                Label(ByteFormatter.format(c.downloadBytes), systemImage: "arrow.down")
                Text("\(ByteFormatter.format(c.uploadSpeedBps))/s · \(ByteFormatter.format(c.downloadSpeedBps))/s")
                Spacer()
                Text(c.openedAt.formatted(.relative(presentation: .named)))
            }
            .font(.caption2.monospaced()).foregroundStyle(.secondary)
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
