#if DEBUG
import Foundation
import QingzhouApp

/// Explicit developer-run acceptance only. Never exports hosts, credentials, URLs or IP addresses.
/// Does not change selection, settings, cloud data or the VPN connection state.
@MainActor
enum NetworkAcceptanceRecorder {
    private struct NodeResult: Codable {
        let id: UUID
        let report: String?
        var alternativeProxyLatencyMs: Int?
        var alternativeProxyFailure: String?
    }
    private struct Report: Codable {
        let startedAt: Date
        let build: String
        var completedAt: Date?
        var running = false
        var directAvailable = false
        var proxyAvailable = false
        var differentExits: Bool?
        var directFailed = false
        var proxyFailed = false
        var directFetchedAt: Date?
        var proxyFetchedAt: Date?
        var appliedID: UUID?
        var nodes: [NodeResult] = []
    }
    static func record(_ state: AppState, diagnoseNodes: Bool) async {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let directory = documents.appendingPathComponent("Diagnostics", isDirectory: true)
        let url = directory.appendingPathComponent("network-acceptance.json")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var report = Report(startedAt: Date(), build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown")
        func save() throws { try encoder.encode(report).write(to: url, options: .atomic) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Allow ordinary system adoption / configuration acknowledgement to settle.
            try await Task.sleep(for: .seconds(6))
            await state.refreshPublicIPInfo()
            report.running = state.isVPNRunning
            report.directAvailable = state.directIPInfo != nil
            report.proxyAvailable = state.proxyIPInfo != nil
            if let direct = state.directIPInfo, let proxy = state.proxyIPInfo {
                report.differentExits = direct.ip != proxy.ip
            }
            report.directFailed = state.directIPFailed; report.proxyFailed = state.proxyIPFailed
            report.directFetchedAt = state.directIPInfo?.fetchedAt; report.proxyFetchedAt = state.proxyIPInfo?.fetchedAt
            report.appliedID = state.appliedTunnelConfiguration?.id
            try save()
            if diagnoseNodes {
                // Existing per-node diagnostics enforce direct/proxy budgets and cancellation.
                // Sequential: the extension permits only one temporary proxy instance at a time.
                let requestedIDs = Set(CommandLine.arguments.compactMap { argument -> UUID? in
                    let prefix = "--qz-diagnostic-node="
                    return argument.hasPrefix(prefix) ? UUID(uuidString: String(argument.dropFirst(prefix.count))) : nil
                })
                let nodes = Array(state.nodes.filter { requestedIDs.isEmpty || requestedIDs.contains($0.id) }.prefix(64))
                for node in nodes {
                    try Task.checkCancellation()
                    var result = await state.diagnoseNode(node)
                    if result == nil { result = await state.diagnoseNode(node) }
                    var row = NodeResult(id: node.id, report: result?.sanitizedText)
                    if result?.conclusion == .proxyFailed {
                        do {
                            row.alternativeProxyLatencyMs = try await state.tunnelManager.pingNode(node: node,
                                targetURL: "https://www.google.com/generate_204", timeoutSeconds: 5)
                        } catch { row.alternativeProxyFailure = "not_completed" }
                    }
                    report.nodes.append(row)
                    try save()
                }
            }
            // Re-sample after startup and node diagnostics settle; do not classify an early
            // refresh superseded by normal startup adoption as a path failure.
            await state.refreshPublicIPInfo()
            report.running = state.isVPNRunning
            report.directAvailable = state.directIPInfo != nil; report.proxyAvailable = state.proxyIPInfo != nil
            report.differentExits = nil
            if let direct = state.directIPInfo, let proxy = state.proxyIPInfo { report.differentExits = direct.ip != proxy.ip }
            report.directFailed = state.directIPFailed; report.proxyFailed = state.proxyIPFailed
            report.directFetchedAt = state.directIPInfo?.fetchedAt; report.proxyFetchedAt = state.proxyIPInfo?.fetchedAt
            report.appliedID = state.appliedTunnelConfiguration?.id
            report.completedAt = Date(); try save()
        } catch { state.logger.warn("Network acceptance recording interrupted", category: "diagnostics") }
    }
}
#endif
