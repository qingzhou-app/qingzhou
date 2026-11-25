import SwiftUI
import QingzhouCore

struct SettingsRegionSection: View {
    @Bindable var state: AppState

    var body: some View {
        Section {
            let regions = state.regionCounts
            if regions.isEmpty {
                Text("还没有节点，添加订阅后这里会列出各地区。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                // 优先地区
                Picker("优先地区", selection: state.setting(\.preferredRegion)) {
                    Text("无（按综合评分）").tag(String?.none)
                    ForEach(regions, id: \.region) { item in
                        Text(L10n.lookup(item.region)).tag(String?.some(item.region))
                    }
                }
                Text("优先地区有符合条件的候选时，在该地区内按综合评分选择；否则在所有符合条件的候选中选择。")
                    .font(.caption2).foregroundStyle(.secondary)

                // 地区排除列表
                ForEach(regions, id: \.region) { item in
                    Toggle(isOn: regionExcludedBinding(item.region)) {
                        HStack {
                            Text(L10n.lookup(item.region))
                            Text("\(item.count) 个节点")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityLabel(Text(L10n.lookup(item.region)))
                    .accessibilityHint(Text("\(item.count) 个节点；开启后排除此地区"))
                }
                Text("打开开关 = 排除该地区的所有节点（不参与自动择优、不会被自动选中）。例如排除「香港」以避开 Anthropic / OpenAI 等对香港 IP 的限制。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        } header: {
            Text("地区")
        }
    }

    /// 某地区是否被排除的 Binding（toggle）。
    private func regionExcludedBinding(_ region: String) -> Binding<Bool> {
        Binding(
            get: { state.settings.excludedRegions.contains(region) },
            set: { _ in state.toggleRegionExclusion(region) }
        )
    }
}
