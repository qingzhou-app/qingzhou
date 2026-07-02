import SwiftUI
import QingzhouLogging
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

public struct LogsView: View {
    @Bindable var state: AppState
    @State private var keyword: String = ""
    @State private var level: LogLevel = .all
    @State private var entries: [LogEntry] = []
    /// 底层日志总条数（未过滤）。用来区分「一条日志都没有」和「过滤后没有匹配」两种空态。
    @State private var totalCount: Int = 0
    @State private var showClearConfirm = false

    public init(state: AppState) { self.state = state }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("级别", selection: $level) {
                    ForEach(LogLevel.allCases, id: \.self) { l in
                        Text(l.rawValue).tag(l)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(.horizontal)

            if entries.isEmpty {
                emptyState
            } else {
                List(entries) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(entry.level.rawValue)
                                .font(.caption2.monospaced())
                                .foregroundStyle(color(for: entry.level))
                            Text(entry.category)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(entry.timestamp, style: .time)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Text(entry.message).font(.system(.caption, design: .monospaced))
                    }
                }
            }
        }
        .navigationTitle("日志")
        .searchable(text: $keyword)
        .toolbar {
            ToolbarItem {
                exportButton
                    .disabled(totalCount == 0)
                    .help("把全部日志导出成文本文件")
            }
            ToolbarItem {
                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    Label("清空", systemImage: "trash")
                }
                .disabled(totalCount == 0)
                .help("清空全部日志")
            }
        }
        .confirmationDialog(
            "确定清空全部日志？",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("清空", role: .destructive) {
                state.logger.clear()
                refresh()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除全部 \(totalCount) 条日志记录，此操作不可撤销。")
        }
        .onAppear { refresh() }
        .onChange(of: keyword) { _, _ in refresh() }
        .onChange(of: level) { _, _ in refresh() }
    }

    // MARK: - 空态

    @ViewBuilder
    private var emptyState: some View {
        if totalCount == 0 {
            ContentUnavailableView {
                Label("暂无日志", systemImage: "doc.text")
            } description: {
                Text("应用运行时的事件（连接 VPN、刷新订阅、测速、报错等）会记录在这里。")
            }
        } else if !keyword.isEmpty {
            // 有日志但搜索无命中 —— 用系统标准的「无结果」样式
            ContentUnavailableView.search(text: keyword)
        } else {
            ContentUnavailableView {
                Label("没有匹配的日志", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("当前级别下没有日志，试试切换回 ALL。")
            }
        }
    }

    // MARK: - 导出

    /// iOS 用系统分享面板（存到文件 / AirDrop / 发给别人都行）；
    /// macOS 用 NSSavePanel 存成文件（比 ShareLink 更符合 Mac 习惯）。
    /// 导出的是**全部**日志（不随当前过滤），格式与 Logger 文件落盘一致，一条一行。
    @ViewBuilder
    private var exportButton: some View {
        #if os(iOS)
        ShareLink(
            item: LogFileExport(logger: state.logger),
            preview: SharePreview("轻舟日志", image: Image(systemName: "doc.text"))
        ) {
            Label("导出", systemImage: "square.and.arrow.up")
        }
        #else
        Button {
            exportViaSavePanel()
        } label: {
            Label("导出", systemImage: "square.and.arrow.up")
        }
        #endif
    }

    #if os(macOS)
    private func exportViaSavePanel() {
        state.logger.debug("打开日志导出保存面板", category: "app")
        let text = LogExportText.render(state.logger.snapshot())
        let panel = NSSavePanel()
        // .log 没有系统静态 UTType，用扩展名构造；失败退回 plainText（会存成 .txt，仍可用）
        panel.allowedContentTypes = [UTType(filenameExtension: "log") ?? .plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = LogExportText.suggestedFileName()

        let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                state.showToast("日志已导出：\(url.lastPathComponent)")
            } catch {
                state.logger.error("导出日志失败: \(error)", category: "app")
                state.showToast("导出失败，详见日志")
            }
        }
        // 优先挂到当前窗口做 sheet —— 独立 panel.begin() 在个别情况下会沉底/不获焦；
        // 拿不到窗口（理论上不会）就退化成模态。两者都必须在主线程调用（这里本来就在）。
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            handleResponse(panel.runModal())
        }
    }
    #endif

    private func refresh() {
        entries = state.logger.search(level: level, keyword: keyword).reversed()
        totalCount = state.logger.snapshot().count
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .error: return .red
        case .warn:  return .orange
        case .info:  return .primary
        case .debug: return .secondary
        case .all:   return .secondary
        }
    }
}

/// 日志导出的文本渲染，行格式与 `Logger.FileSink` 保持一致（ISO8601 [LEVEL] [category] message）。
enum LogExportText {
    static func render(_ entries: [LogEntry]) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return entries
            .map { "\(f.string(from: $0.timestamp)) [\($0.level.rawValue)] [\($0.category)] \($0.message)" }
            .joined(separator: "\n") + "\n"
    }

    static func suggestedFileName(now: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "Qingzhou-logs-\(f.string(from: now)).log"
    }
}

#if os(iOS)
/// ShareLink 的惰性文件导出：只有用户真点了分享面板里的目标，才 snapshot + 写临时文件，
/// 避免每次视图刷新都把上万条日志拼成大字符串。
private struct LogFileExport: Transferable {
    let logger: Logger

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { export in
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(LogExportText.suggestedFileName())
            try LogExportText.render(export.logger.snapshot())
                .write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }
}
#endif
