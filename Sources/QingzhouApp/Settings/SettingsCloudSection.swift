import SwiftUI
import QingzhouCore

struct SettingsCloudSection: View {
    @Bindable var state: AppState

    var body: some View {
        Section("iCloud 同步") {
            Toggle("同步到 iCloud Drive", isOn: cloudSyncBinding)
            LabeledContent("状态", value: state.cloudSyncStatus.displayText)
                .font(.caption)
            Button {
                Task { await state.requestManualCloudRestore() }
            } label: {
                Label("立即恢复 iCloud 数据", systemImage: "icloud.and.arrow.down")
            }
            .disabled(!state.settings.iCloudSyncEnabled)
            Text("不会自动弹出恢复提示。需要恢复时，请点上方按钮选择云端版本；出现版本差异时会暂停自动上传，保留两边配置。")
                .font(.caption2).foregroundStyle(.secondary)
            Text("配置（订阅、节点、规则、设置）会镜像到你 iCloud Drive 的「轻舟」文件夹，卸载 App 不会丢失，重装或换设备时可一键恢复。云端保留最近 \(CloudVaultStore.maxBackups) 份历史版本。不含连接记录与流量统计。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// iCloud 同步开关走专用方法 —— 开启时要立刻跑一次云端比对（只更新状态，不弹恢复提示）。
    private var cloudSyncBinding: Binding<Bool> {
        Binding(
            get: { state.settings.iCloudSyncEnabled },
            set: { state.setCloudSyncEnabled($0) }
        )
    }
}

/// 版本选择 sheet 三态：点击瞬间以 .loading 呈现（iCloud 读取秒级，sheet 不能干等），
/// 读完切列表；失败留在 sheet 内展示 + 重试。
struct SettingsCloudVersionPicker: View {
    @Bindable var state: AppState
    @Environment(\.locale) private var locale

    var body: some View {
        NavigationStack {
            Group {
                switch state.cloudVersionLoad {
                case nil, .loading:
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在读取 iCloud 版本…")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.icloud")
                            .font(.largeTitle).foregroundStyle(.secondary)
                        Text(message)
                            .font(.subheadline).multilineTextAlignment(.center)
                        Button("重试") {
                            Task { await state.loadCloudVersionOptions() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .loaded(let options):
                    List(options) { option in
                        Button {
                            state.chooseCloudRestoreCandidate(option)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(option.backupFileName == nil ? "云端当前版本" : "历史版本")
                                        .font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text("r\(option.header.revision)")
                                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                                // 内容计数醒目展示 —— 空数据（0 订阅）一眼可见
                                Text(option.header.contentSummary)
                                    .font(.subheadline)
                                    .foregroundStyle(
                                        (option.header.nodeCount ?? 1) == 0 ? AnyShapeStyle(.orange)
                                                                            : AnyShapeStyle(.primary))
                                Text("\(option.header.deviceName) · "
                                     + option.header.modifiedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("选择要恢复的版本")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { state.dismissCloudVersionOptions() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 320)
        #endif
    }
}
