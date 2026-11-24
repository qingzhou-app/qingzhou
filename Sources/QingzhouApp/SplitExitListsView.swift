import SwiftUI
import QingzhouCore

#if os(macOS)
/// 查看「分流方案」用的国内名单（Loyalsoldier direct.txt / cncidr.txt）实际内容。
///
/// 为什么要给界面看：这份名单是每天从外网拉的、注入进 xray 规则里的，
/// 一旦解析或抽样出问题，用户只看到一个数字（30000/110202），没法核对到底装进去了什么。
/// 这个页面把三类条目（域名 / 关键字 / 网段）分开列出来，可搜索、可翻页。
struct SplitExitListsView: View {
    let lists: SplitExitLists
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    private enum Kind: String, CaseIterable, Identifiable {
        case domains, keywords, cidrs
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .domains:  return "域名"
            case .keywords: return "关键字"
            case .cidrs:    return "网段"
            }
        }
    }

    @State private var kind: Kind = .domains
    @State private var query = ""
    @State private var limit = 200

    private var allItems: [String] {
        switch kind {
        case .domains:  return lists.domains
        case .keywords: return lists.domainKeywords
        case .cidrs:    return lists.cidrs
        }
    }

    private var items: [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return allItems }
        return allItems.filter { $0.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let at = lists.fetchedAt {
                        LabeledContent("更新时间",
                                       value: at.formatted(Date.FormatStyle(date: .numeric, time: .shortened).locale(locale)))
                    }
                    ForEach(lists.sources, id: \.self) { src in
                        Text(src)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if lists.sourceDomainCount > 0 {
                        LabeledContent("域名",
                                       value: L("\(lists.domains.count) / 源 \(lists.sourceDomainCount)"))
                        LabeledContent("网段",
                                       value: L("\(lists.cidrs.count) / 源 \(lists.sourceCIDRCount)"))
                    }
                } header: {
                    Text("来源")
                } footer: {
                    Text("「实收 / 源」不相等说明按内存预算抽样过；未注入的部分仍由内置 geosite:cn / geoip:cn 兜底。")
                }

                Section {
                    Picker("类型", selection: $kind) {
                        ForEach(Kind.allCases) { k in
                            Text(k.title).tag(k)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: kind) { _, _ in limit = 200 }
                }

                Section {
                    if items.isEmpty {
                        Text(allItems.isEmpty ? LocalizedStringKey("这一类是空的") : LocalizedStringKey("无匹配"))
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(items.prefix(limit), id: \.self) { entry in
                            Text(entry)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                        if items.count > limit {
                            Text("已显示 \(limit) / \(items.count) 条")
                                .font(.caption2).foregroundStyle(.secondary)
                            Button {
                                limit += 200
                            } label: {
                                Label("再显示 200 条", systemImage: "chevron.down")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                } header: {
                    Text("\(items.count) 条")
                }
            }
            .searchable(text: $query, prompt: "搜索条目")
            .onChange(of: query) { _, _ in limit = 200 }
            .navigationTitle("国内名单")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
#endif
