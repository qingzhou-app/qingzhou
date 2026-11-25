#if os(macOS)
import AppKit
import SwiftUI

/// 断网开关：命令面板。root 操作没法在 App 内完成（sudo 密码框不允许预填），
/// 所以把命令摆出来让用户一键复制、到终端粘贴执行，并显示当前状态。
struct SettingsGuardSection: View {
    /// 断网开关的安装/拦截状态（命令面板展示用）。每次进页刷新一次。
    @State private var guardStatus: GuardStatus = .checking

    var body: some View {
        Group {
            Section {
                statusRow("已安装（中继 + 守护进程）", ok: guardStatus.installed)
                statusRow("拦截已启用", ok: guardStatus.enabled)
                statusRow("中继在监听 10808", ok: guardStatus.relayListening)

                if !guardStatus.installed {
                    Text("尚未安装。先装 guard，再配分流 + 「经 root 中继出网」，确认能上网后开拦截。")
                        .font(.caption2).foregroundStyle(.orange)
                }
            } header: {
                Text("断网开关")
            } footer: {
                Text("以下命令需要 root（sudo）。App 无法代替你敲密码，请点「复制」后到终端粘贴执行。")
            }

            Section("命令（复制到终端执行）") {
                commandRow("安装 guard（只装不拦）", cmd: guardInstallCommand, danger: false)
                commandRow("启用拦截", cmd: guardEnableCommand, danger: false)
                commandRow("解除拦截（断网时急救）", cmd: guardOffCommand, danger: true)
                commandRow("彻底卸载", cmd: guardUninstallCommand, danger: false)
            }
        }
        .onAppear { refreshGuardStatus() }
    }

    /// 断网开关的运行状态（命令面板展示）。检测只读、不触发任何 root 操作。
    private struct GuardStatus {
        var installed = false
        var enabled = false
        var relayListening = false
        static let checking = GuardStatus()
    }

    /// 只读检测断网开关三态：装没装（目录+守护进程）、开没开（enabled 标记）、
    /// 中继在不在听（127.0.0.1:10808）。不做任何特权操作。
    private func refreshGuardStatus() {
        var s = GuardStatus()
        let base = Self.guardBase
        let fm = FileManager.default
        s.installed = fm.fileExists(atPath: base + "/qingzhou-relay")
            && fm.fileExists(atPath: "/Library/LaunchDaemons/com.sbraveyoung.qingzhou.guard.plist")
        s.enabled = fm.fileExists(atPath: base + "/enabled")
        // 探测 10808 是否在听（不产生副作用，连上就关）
        s.relayListening = Self.isPortOpen(10808)
        guardStatus = s
    }

    private static func isPortOpen(_ port: UInt16) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let r = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
                connect(sock, sap, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return r == 0
    }

    private func statusRow(_ title: LocalizedStringKey, ok: Bool) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ok ? Color.green : Color.secondary)
            Text(title).font(.caption)
            Spacer()
        }
    }

    private func commandRow(_ title: LocalizedStringKey, cmd: String, danger: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).fontWeight(.medium)
            Text(cmd)
                .font(.caption2.monospaced())
                .foregroundStyle(danger ? Color.red : Color.secondary)
                .textSelection(.enabled)
            Button {
                copyGuardCommand(cmd)
            } label: {
                Label("复制", systemImage: "doc.on.doc")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
        }
    }

    private func copyGuardCommand(_ cmd: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
    }

    private static let guardBase = "/Library/Application Support/qingzhou-guard"

    private var guardInstallCommand: String {
        "sudo sh Tools/qingzhou-guard/install.sh"
    }
    private var guardEnableCommand: String {
        "sudo sh \"\(Self.guardBase)/enable.sh\""
    }
    private var guardOffCommand: String {
        "sudo sh \"\(Self.guardBase)/off.sh\""
    }
    private var guardUninstallCommand: String {
        "sudo sh \"\(Self.guardBase)/uninstall.sh\""
    }
}
#endif
