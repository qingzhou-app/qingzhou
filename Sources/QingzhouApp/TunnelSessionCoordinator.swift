import Foundation
import NetworkExtension
import QingzhouCore

/// 主 App 对扩展会话的采认状态。只处理已提交的元数据，不执行 VPN IO 或推断界面选择。
///
/// requestID/回执约束本进程发起的操作；新鲜流量心跳可否定残留会话文件。
/// 值类型由 AppState 的主线程生命周期拥有，所有相关状态一起迁移和清理。
struct TunnelSessionCoordinator: Sendable {
    private(set) var appliedConfiguration: AppliedTunnelConfiguration?
    private(set) var startedAtFloor: Date?
    private var expectedConfigurationID: UUID?
    private var expectedRequestID: UUID?
    private var contradictedConfigurationIDs: Set<UUID> = []

    /// 启动请求提交后，旧会话与旧切换回执不能确认本次启动。
    mutating func startSubmitted(at date: Date, requestID: UUID?) {
        expectedConfigurationID = nil
        expectedRequestID = requestID
        startedAtFloor = date
    }

    /// 主 App 重开或系统从外部启动隧道时，没有本进程的启动时间下限。
    mutating func adoptRunningSession() {
        startedAtFloor = .distantPast
    }

    mutating func expectRequest(_ requestID: UUID?) {
        expectedRequestID = requestID
    }

    mutating func recordAcknowledgement(_ configurationID: UUID?) {
        expectedConfigurationID = configurationID
    }

    /// 断开时清理确认状态；时间下限仍供既有连接计时流程过滤旧文件。
    mutating func clearAppliedState() {
        appliedConfiguration = nil
        expectedConfigurationID = nil
        expectedRequestID = nil
        contradictedConfigurationIDs.removeAll()
    }

    mutating func ingestHeartbeat(_ stats: TrafficStats, now: Date = Date()) {
        guard abs(stats.sampledAt.timeIntervalSince(now)) <= 3,
              let id = stats.configurationID else { return }
        contradictedConfigurationIDs.remove(id)
        if let appliedConfiguration, id != appliedConfiguration.id {
            contradictedConfigurationIDs.insert(appliedConfiguration.id)
            self.appliedConfiguration = nil
        }
    }

    /// 共享文件是扩展的提交点，必须同时满足系统状态、本次请求与心跳证据。
    mutating func update(session: TunnelSessionInfo?, status: NEVPNStatus) {
        guard status == .connected || status == .reasserting,
              let session, session.stoppedAt == nil,
              session.startedAt >= (startedAtFloor ?? .distantPast).addingTimeInterval(-1) else {
            appliedConfiguration = nil
            return
        }
        if let expectedConfigurationID, session.appliedConfiguration?.id != expectedConfigurationID {
            appliedConfiguration = nil
            return
        }
        if let expectedRequestID, session.appliedConfiguration?.requestID != expectedRequestID {
            appliedConfiguration = nil
            return
        }
        if let id = session.appliedConfiguration?.id, contradictedConfigurationIDs.contains(id) {
            appliedConfiguration = nil
            return
        }
        appliedConfiguration = session.appliedConfiguration
    }
}
