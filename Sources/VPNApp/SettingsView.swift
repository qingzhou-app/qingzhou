import SwiftUI
import VPNCore

public struct SettingsView: View {
    @Bindable var state: AppState

    public init(state: AppState) { self.state = state }

    public var body: some View {
        Form {
            proxySection
            autoSelectSection
            appearanceSection
            ruleSourceSection
            shellSnippetSection
            #if os(macOS)
            macIntegrationSection
            #endif
            aboutSection
        }
        .navigationTitle("设置")
        .formStyle(.grouped)
    }

    private var proxySection: some View {
        Section("代理") {
            Picker("代理模式", selection: state.setting(\.proxyMode)) {
                ForEach(ProxyMode.allCases, id: \.self) { m in
                    Text(label(for: m)).tag(m)
                }
            }
            HStack {
                Text("HTTP 端口")
                Spacer()
                TextField(
                    "7890",
                    value: state.setting(\.httpPort),
                    format: .number.grouping(.never)
                )
                .multilineTextAlignment(.trailing)
                .frame(width: 100)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                Stepper("", value: state.setting(\.httpPort), in: 1024...65535)
                    .labelsHidden()
            }
            HStack {
                Text("SOCKS 端口")
                Spacer()
                TextField(
                    "7891",
                    value: state.setting(\.socksPort),
                    format: .number.grouping(.never)
                )
                .multilineTextAlignment(.trailing)
                .frame(width: 100)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                Stepper("", value: state.setting(\.socksPort), in: 1024...65535)
                    .labelsHidden()
            }
            Picker("日志级别", selection: state.setting(\.logLevel)) {
                Text("DEBUG").tag("DEBUG")
                Text("INFO").tag("INFO")
                Text("WARN").tag("WARN")
                Text("ERROR").tag("ERROR")
            }
        }
    }

    private var autoSelectSection: some View {
        Section("自动化") {
            // 自动测速：周期性刷延迟列，不改 currentNodeId
            Picker("自动测速", selection: state.setting(\.autoMeasureIntervalSeconds)) {
                Text("关闭").tag(TimeInterval(0))
                Text("15 分钟").tag(TimeInterval(15 * 60))
                Text("30 分钟").tag(TimeInterval(30 * 60))
                Text("1 小时").tag(TimeInterval(60 * 60))
                Text("6 小时").tag(TimeInterval(6 * 60 * 60))
            }
            Text("只刷新延迟数据，不会自动切换当前节点。")
                .font(.caption2).foregroundStyle(.secondary)

            // 自动择优：测速 + 自动切节点
            Picker("自动择优时机", selection: state.setting(\.autoSelectTrigger)) {
                Text("启动时").tag(AutoSelectTrigger.onAppLaunch)
                Text("定时").tag(AutoSelectTrigger.interval)
                Text("启动 + 定时").tag(AutoSelectTrigger.onAppLaunchAndInterval)
                Text("关闭").tag(AutoSelectTrigger.off)
            }
            Stepper(value: state.setting(\.autoSelectIntervalSeconds), in: 60...86400, step: 60) {
                LabeledContent("择优间隔", value: "\(Int(state.settings.autoSelectIntervalSeconds / 60)) 分钟")
            }
            Text("开启后会主动把「当前节点」切到测速最快的那个 —— 如果你手选了节点不想被换，关掉这一项。")
                .font(.caption2).foregroundStyle(.secondary)

            Picker("订阅自动刷新", selection: state.setting(\.subscriptionRefreshIntervalSeconds)) {
                Text("关闭").tag(TimeInterval(0))
                Text("15 分钟").tag(TimeInterval(15 * 60))
                Text("30 分钟").tag(TimeInterval(30 * 60))
                Text("1 小时").tag(TimeInterval(60 * 60))
                Text("6 小时").tag(TimeInterval(6 * 60 * 60))
                Text("24 小时").tag(TimeInterval(24 * 60 * 60))
            }
            Text("当前节点：\(state.currentNode?.name ?? "未选")")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var appearanceSection: some View {
        Section("外观") {
            Picker("主题", selection: state.setting(\.theme)) {
                Text("跟随系统").tag(AppearanceTheme.system)
                Text("浅色").tag(AppearanceTheme.light)
                Text("深色").tag(AppearanceTheme.dark)
            }
            Picker("语言", selection: state.setting(\.language)) {
                Text("跟随系统").tag(AppLanguage.system)
                Text("简体中文").tag(AppLanguage.zhHans)
                Text("繁體中文").tag(AppLanguage.zhHant)
                Text("English").tag(AppLanguage.en)
                Text("日本語").tag(AppLanguage.ja)
            }
        }
    }

    private var ruleSourceSection: some View {
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

    private var shellSnippetSection: some View {
        Section("终端环境变量") {
            Text(shellExportSnippet(httpPort: state.settings.httpPort, socksPort: state.settings.socksPort))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    #if os(macOS)
    private var macIntegrationSection: some View {
        Section("macOS 集成") {
            Toggle("启用系统代理", isOn: state.setting(\.systemProxyEnabled))
            Text("会通过 `networksetup` 给所有网络服务设置 127.0.0.1:\(state.settings.httpPort) / SOCKS:\(state.settings.socksPort)。需要 app 不在 sandbox 中运行。")
                .font(.caption2).foregroundStyle(.secondary)
            Toggle("开机自启", isOn: state.setting(\.launchAtLogin))
            Button("立即应用") {
                state.applyMacSystemPreferences()
            }
        }
    }
    #endif

    private var aboutSection: some View {
        Section("关于") {
            LabeledContent("App 版本", value: appVersion)
            LabeledContent("数据目录", value: dataDir).font(.caption.monospaced())
            Link("GitHub 仓库", destination: URL(string: "https://github.com/sbraveyoung/vpn")!)
        }
    }

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    private var dataDir: String {
        Persistence.defaultDirectory().path
    }

    private func label(for mode: ProxyMode) -> String {
        switch mode {
        case .global: return "全局代理"
        case .rule:   return "规则代理"
        case .direct: return "直连"
        }
    }

    private func shellExportSnippet(httpPort: Int, socksPort: Int) -> String {
        """
        # bash / zsh:
        export http_proxy=http://127.0.0.1:\(httpPort)
        export https_proxy=http://127.0.0.1:\(httpPort)
        export all_proxy=socks5://127.0.0.1:\(socksPort)

        # fish:
        set -x http_proxy http://127.0.0.1:\(httpPort)
        set -x https_proxy http://127.0.0.1:\(httpPort)
        set -x all_proxy socks5://127.0.0.1:\(socksPort)

        # powershell:
        $env:HTTP_PROXY="http://127.0.0.1:\(httpPort)"
        $env:HTTPS_PROXY="http://127.0.0.1:\(httpPort)"
        $env:ALL_PROXY="socks5://127.0.0.1:\(socksPort)"
        """
    }
}
