#if DEBUG
import Foundation
import QingzhouApp

/// 明确带验收参数时，记录15秒只读状态。只导出白名单元数据，不导出节点/URL/原始日志。
@MainActor
enum AcceptanceRecorder {
    private struct Sample: Codable {
        let at: Date
        let systemStatus: Int
        let running: Bool
        let switching: Bool
        let connectedSince: Date?
        let appliedID: UUID?
        let appliedNodeID: UUID?
        let selectedNodeID: UUID?
        let selectionMatchesApplied: Bool?
        let remoteRuleCount: Int
        let requestedMode: String
        let appliedMode: String?
    }

    private struct Report: Codable {
        let runID: UUID
        let build: String
        let startedAt: Date
        var samples: [Sample]
        var events: [AcceptanceTrace.Event]
    }

    static func record(_ state: AppState) async {
        defer { AcceptanceTrace.end() }
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let directory = documents.appendingPathComponent("Diagnostics", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("acceptance.json")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var report = Report(runID: UUID(), build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
                startedAt: Date(), samples: [], events: [])
            for tick in 0...15 {
                guard !Task.isCancelled else { return }
                let applied = state.appliedTunnelConfiguration
                report.samples.append(Sample(at: Date(), systemStatus: state.tunnelManager.status.rawValue,
                    running: state.isVPNRunning, switching: state.isSwitchingTunnel,
                    connectedSince: state.connectedSince, appliedID: applied?.id,
                    appliedNodeID: applied?.nodeID, selectedNodeID: state.currentNodeId,
                    selectionMatchesApplied: state.currentNode.map { applied?.matches($0) } ?? nil,
                    remoteRuleCount: state.remoteRules.count, requestedMode: state.settings.proxyMode.rawValue,
                    appliedMode: applied?.mode.rawValue))
                report.events = AcceptanceTrace.events
                try encoder.encode(report).write(to: url, options: .atomic)
                if tick < 15 { try await Task.sleep(for: .seconds(1)) }
            }
        } catch {
            // 诊断写入失败不改变VPN/配置，不在输出中暴露路径或配置。
            state.logger.warn("Acceptance recording unavailable", category: "diagnostics")
        }
    }
}
#endif
