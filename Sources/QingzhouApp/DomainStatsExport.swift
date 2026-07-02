import SwiftUI
import QingzhouCore
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// 域名统计的 CSV 渲染（域名分析工具栏「导出」）。
/// 导出的是**当前过滤视图**（搜索关键字 + 忽略 IP 生效后的域名 tab 聚合），
/// 列：域名/路由/连接次数/命中规则/首次出现/最近出现。
enum DomainStatsCSV {

    /// 带 UTF-8 BOM —— Excel 打开无 BOM 的 UTF-8 CSV 中文会乱码。
    static func render(_ stats: [DomainStat]) -> String {
        var lines = ["域名,路由,连接次数,命中规则,首次出现,最近出现"]
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        for s in stats {
            let rule = DomainAnalyzer.isUnmatchedRule(s.lastMatchedRule)
                ? Connection.noMatchedRule : s.lastMatchedRule
            lines.append([
                s.domain, routeName(s.route), "\(s.connectionCount)", rule,
                f.string(from: s.firstSeen), f.string(from: s.lastSeen),
            ].map(escape).joined(separator: ","))
        }
        return "\u{FEFF}" + lines.joined(separator: "\n") + "\n"
    }

    static func suggestedFileName(now: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "Qingzhou-domains-\(f.string(from: now)).csv"
    }

    private static func routeName(_ r: DomainRoute) -> String {
        switch r {
        case .proxy:  return "代理"
        case .direct: return "直连"
        case .reject: return "拒绝"
        case .mixed:  return "混合"
        }
    }

    /// RFC 4180：含逗号/引号/换行的字段整体加引号，内嵌引号翻倍。
    private static func escape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// 域名分析工具栏的导出按钮。照 LogsView 的现成模式：
/// iOS 用 ShareLink（存文件 / AirDrop 都行），macOS 用 NSSavePanel（更符合 Mac 习惯，
/// 沙箱下 user-selected read-write entitlement 已有）。
struct DomainStatsExportButton: View {
    let stats: [DomainStat]
    let state: AppState

    var body: some View {
        exportControl
            .disabled(stats.isEmpty)
            .help("把当前过滤视图的域名统计导出成 CSV")
    }

    @ViewBuilder private var exportControl: some View {
        #if os(iOS)
        ShareLink(
            item: DomainStatsCSVExport(stats: stats),
            preview: SharePreview("轻舟域名统计", image: Image(systemName: "tablecells"))
        ) {
            Label("导出 CSV", systemImage: "square.and.arrow.up")
        }
        #else
        Button {
            exportViaSavePanel()
        } label: {
            Label("导出 CSV", systemImage: "square.and.arrow.up")
        }
        #endif
    }

    #if os(macOS)
    private func exportViaSavePanel() {
        let text = DomainStatsCSV.render(stats)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = DomainStatsCSV.suggestedFileName()

        let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                state.showToast("已导出 \(stats.count) 个域名：\(url.lastPathComponent)")
            } catch {
                state.logger.error("导出域名统计失败: \(error)", category: "app")
                state.showToast("导出失败，详见日志")
            }
        }
        // 同 LogsView：优先挂当前窗口做 sheet，拿不到就模态兜底
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            handleResponse(panel.runModal())
        }
    }
    #endif
}

#if os(iOS)
/// ShareLink 的惰性文件导出：用户真点了分享目标才渲染 + 写临时文件（同 LogsView 模式）。
private struct DomainStatsCSVExport: Transferable {
    let stats: [DomainStat]

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { export in
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(DomainStatsCSV.suggestedFileName())
            try DomainStatsCSV.render(export.stats)
                .write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }
}
#endif
