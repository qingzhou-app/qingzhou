import Foundation
import SwiftUI
import QingzhouCore

/// 把 `AppLanguage` 设置映射到 SwiftUI 的 `Locale` 环境值。
/// 一旦应用，所有 `Date.formatted` / `Text(date:)` / 数字 / 相对时间会立刻按目标 locale 渲染。
///
/// UI 字符串的翻译来自 app target 里的 `Apps/App-Shared/Localizable.xcstrings`（开发语言
/// zh-Hans，key 即中文原文）。SwiftUI 的 `Text("中文")` 默认查 `Bundle.main`，所以目录放在
/// app target 里即可命中翻译，包内视图代码无需指定 bundle；语种跟随根视图注入的
/// `\.locale` 环境值（`state.settings.language`）。
public enum LocaleResolver {
    public static func locale(for language: AppLanguage) -> Locale {
        switch language {
        case .system:  return Locale.autoupdatingCurrent
        case .zhHans:  return Locale(identifier: "zh-Hans")
        case .zhHant:  return Locale(identifier: "zh-Hant")
        case .en:      return Locale(identifier: "en")
        case .ja:      return Locale(identifier: "ja")
        }
    }

    /// 语言对应的 `.lproj` 目录名（xcstrings 编译产物的语种目录）。`.system` 返回 nil。
    static func lprojName(for language: AppLanguage) -> String? {
        switch language {
        case .system:  return nil
        case .zhHans:  return "zh-Hans"
        case .zhHant:  return "zh-Hant"
        case .en:      return "en"
        case .ja:      return "ja"
        }
    }
}

/// 动态字符串（toast / 错误文案等 **非** `LocalizedStringKey` 场景）的本地化通道。
///
/// 为什么不用裸 `String(localized:)`：它按**进程首选语言**（系统语言）解析，感知不到
/// App 内的语言设置 —— 用户在系统中文、App 选 English 时，静态 UI 会变英文
/// （`\.locale` 环境值生效），toast / 错误却仍是中文。这里把 App 语言映射到
/// `Bundle.main` 里对应的 `.lproj` 子 bundle，保证动态字符串和静态 UI 语种一致。
///
/// `AppState` 在初始化和语言设置变化时调 `setLanguage(_:)`；语言为「跟随系统」或找不到
/// 语种目录（如 `swift test` 环境没有字符串目录）时回落 `Bundle.main` —— 此时
/// `String(localized:bundle:)` 原样返回 key（中文原文），行为与本地化前完全一致。
public enum L10n {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var overrideBundle: Bundle?
    private nonisolated(unsafe) static var overrideLocale: Locale?

    /// App 语言设置变化时更新动态字符串使用的 bundle / locale。
    public static func setLanguage(_ language: AppLanguage) {
        let resolvedBundle: Bundle?
        if let lproj = LocaleResolver.lprojName(for: language),
           let path = Bundle.main.path(forResource: lproj, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            resolvedBundle = bundle
        } else {
            resolvedBundle = nil
        }
        let resolvedLocale: Locale? = language == .system ? nil : LocaleResolver.locale(for: language)
        lock.lock()
        overrideBundle = resolvedBundle
        overrideLocale = resolvedLocale
        lock.unlock()
    }

    /// 当前动态字符串应查的 bundle（App 语言的 lproj 子 bundle，或 `Bundle.main`）。
    public static var bundle: Bundle {
        lock.lock()
        defer { lock.unlock() }
        return overrideBundle ?? .main
    }

    /// 当前 App 语言对应的 locale（「跟随系统」时即系统 locale）。
    /// **模型层**动态字符串里的日期/数字格式化用它 —— `.formatted()` 默认吃进程首选语言，
    /// 感知不到 App 内语言设置；视图层请优先用 `@Environment(\.locale)`。
    public static var locale: Locale {
        lock.lock()
        defer { lock.unlock() }
        return overrideLocale ?? Locale.autoupdatingCurrent
    }

    /// 按 key 查表（值本身是动态数据的场景：地区名、模式名等）。没有翻译时原样返回 key。
    public static func lookup(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }
}

/// 动态拼接字符串的本地化入口，等价于 `String(localized:bundle:)` 但跟随 App 内语言设置。
/// 用法：`showToast(L("已复制 \(n) 条"))` —— key 写中文原文（开发语言），插值自动变成
/// 格式占位符（Int → %lld、String → %@），与 xcstrings 里的 key 一一对应。
public func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: L10n.bundle)
}
