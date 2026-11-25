import SwiftUI
import QingzhouCore

struct SettingsRuleSourceSection: View {
    @Bindable var state: AppState

    var body: some View {
        Section("规则源") {
            TextField(
                "Rule source URL",
                text: state.setting(\.ruleSourceURL).mapURL()
            )
            .font(.caption.monospaced())
            Button {
                Task { await state.refreshRemoteRules() }
            } label: {
                Label("立即刷新", systemImage: "arrow.clockwise")
            }
        }
    }
}

/// Geo 数据：内置精简版（geoip 仅 cn/private）↔ 完整版（全部国家码，~20MB）。
/// 下载走主备源（轻舟源 → v2fly 官方），sha256 校验通过才落盘；成功后自动热切换生效。
struct SettingsGeoDataSection: View {
    @Bindable var state: AppState
    @Environment(\.locale) private var locale

    var body: some View {
        Section {
            LabeledContent("当前版本") {
                if state.geoData.hasFullGeoIP, let info = state.geoData.info {
                    Text("完整版 · \(info.downloadedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))) · 来源：\(L10n.lookup(info.sourceName))")
                        .font(.caption)
                } else {
                    Text("精简版（内置，GEOIP 仅 cn / private）")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            switch state.geoData.phase {
            case .downloading(let sourceName, let progress):
                HStack(spacing: 8) {
                    ProgressView(value: progress)
                    Text("正在从\(sourceName)下载…")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize()
                }
            case .verifying:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("sha256 校验中…").font(.caption).foregroundStyle(.secondary)
                }
            default:
                Button {
                    Task { await state.downloadFullGeoData() }
                } label: {
                    Label(state.geoData.hasFullGeoIP ? "重新下载完整版" : "下载完整版（约 20 MB）",
                          systemImage: "arrow.down.circle")
                }
                Button {
                    Task { await state.geoData.checkForUpdate() }
                } label: {
                    Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
                }
                if let message = state.geoData.lastCheckMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                if case .failed(let message) = state.geoData.phase {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
        } header: {
            Text("Geo 数据")
        } footer: {
            Text("完整版解锁所有国家/地区码的 GEOIP 规则（如 GEOIP,us）。数据来自 v2fly 上游，主源为轻舟自建发布仓库、每周自动同步，主源不可用时自动切换 v2fly 官方源。")
                .font(.caption2)
        }
    }
}
