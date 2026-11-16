import SwiftUI

/// @AppStorage 的 key 集中在這裡
enum SettingsKey {
    static let appearance = "appearance"
    static let dailyNewLimit = "dailyNewLimit"
    static let reminderEnabled = "reminderEnabled"
    /// 一天中的秒數（預設 21:00）
    static let reminderSeconds = "reminderSeconds"
    /// 複習時接下來出什麼：混合／只背新字／只複習
    static let reviewMix = "reviewMix"
}

/// 複習時接下來出什麼
enum ReviewMix: String, CaseIterable, Identifiable {
    case mixed
    case newOnly
    case reviewOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mixed: "混合"
        case .newOnly: "新字"
        case .reviewOnly: "複習"
        }
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "跟隨系統"
        case .light: "淺色"
        case .dark: "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum AppDefaults {
    static let dailyNewLimit = 20
    static let reminderSeconds = 21 * 3600
}
