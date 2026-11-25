import SwiftUI
import QingzhouCore

public struct SettingsView: View {
    @Bindable var state: AppState

    public init(state: AppState) { self.state = state }

    public var body: some View {
        Form {
            SettingsProxySection(state: state)
            #if os(macOS)
            SettingsSplitExitSection(state: state)
            SettingsGuardSection()
            #endif
            SettingsAutoSelectSection(state: state)
            SettingsRegionSection(state: state)
            appearanceSection
            SettingsRuleSourceSection(state: state)
            SettingsGeoDataSection(state: state)
            #if os(macOS)
            SettingsMacIntegrationSection(state: state)
            #endif
            SettingsCloudSection(state: state)
            SettingsDiagnosticsSection(state: state)
            aboutSection
        }
        // 语言切换时强制整页重建：iOS 的 Form 是 UICollectionView，cell 复用会让个别
        // 收起态 Picker 的**值文案**（L() 预解析的 String）残留旧语种（真机踩过：
        // 切 English 后「定时关闭」的值仍显示「关闭」）。静态 Text 靠 \.locale 环境值
        // 自动刷新不受影响，但 String 值内容不变时 cell 未必重渲染 —— id 直接换树。
        .id(state.settings.language)
        .navigationTitle(AppSection.settings.localizedTitle(language: state.settings.language))
        .formStyle(.grouped)
        // 「立即恢复」的版本选择 sheet。两条呈现纪律（复验 #18 两轮打回换来的）：
        // 1. 挂在 Form 顶层，**不要挂进 Section** —— iOS 的 Form 是惰性容器（UICollectionView），
        //    cell 重渲染会重建 hosting view，呈现动画中的 sheet 会被连带 dismiss（弹出即沉）。
        // 2. isPresented 只依赖专用稳定 Bool —— 加载态 .loading→.loaded 落在呈现动画中，
        //    binding 若依赖它，mid-transition 重渲染同样会打断呈现。
        // onDismiss：sheet 完全收起后才把点选的候选交给确认 alert（挂在 RootView）——
        // 收起动画中就置 cloudRestoreOffer 会撞呈现层，alert 被吞掉。
        .sheet(isPresented: cloudVersionSheetBinding, onDismiss: {
            state.presentPendingCloudRestoreOffer()
        }) {
            SettingsCloudVersionPicker(state: state)
        }
    }

    /// 「上次采样」的人话时间差（转发给 SettingsDiagnosticsSection，保持既有测试接口）。
    static func ageText(_ age: TimeInterval) -> String {
        SettingsDiagnosticsSection.ageText(age)
    }

    private var appearanceSection: some View {
        Section("外观") {
            Picker("主题", selection: state.setting(\.theme)) {
                Text("跟随系统").tag(AppearanceTheme.system)
                Text("浅色").tag(AppearanceTheme.light)
                Text("深色").tag(AppearanceTheme.dark)
            }
            // 已放出的语种（E.18 补齐繁中 / 日语翻译）。每种语言的 Text 用其母语自称，
            // 不随当前界面语言变化（惯例：语言选择项永远显示各自的原生名）。
            Picker("语言", selection: state.setting(\.language)) {
                Text("简体中文").tag(AppLanguage.zhHans)
                Text("繁體中文").tag(AppLanguage.zhHant)
                Text("English").tag(AppLanguage.en)
                Text("日本語").tag(AppLanguage.ja)
            }
        }
    }

    /// 只读专用稳定 Bool（呈现开关），不读会中途变化的加载态 —— 见 body 上 sheet 的注释。
    private var cloudVersionSheetBinding: Binding<Bool> {
        Binding(
            get: { state.isCloudVersionSheetPresented },
            set: { if !$0 { state.dismissCloudVersionOptions() } }
        )
    }

    private var aboutSection: some View {
        Section("关于") {
            LabeledContent("App 版本", value: appVersion)
            LabeledContent("数据目录", value: dataDir).font(.caption.monospaced())
            Link("GitHub 仓库", destination: URL(string: "https://github.com/qingzhou-app/qingzhou")!)
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
}
