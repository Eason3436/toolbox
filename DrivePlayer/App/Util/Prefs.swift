import Core
import SwiftUI
import UIKit

/// 使用者設定（UserDefaults／@AppStorage 的 key 與預設值）
enum Prefs {
    // 播放
    static let skipForward = "skipForward"
    static let skipBackward = "skipBackward"
    static let longPressRate = "longPressRate"
    static let resumeMode = "resumeMode"
    static let autoPlayNext = "autoPlayNext"
    static let skipIntroOutro = "skipIntroOutro"
    static let autoMarkWatched = "autoMarkWatched"
    static let rememberSpeed = "rememberSpeed"
    static let lastSpeed = "lastSpeed"
    static let autoPiP = "autoPiP"
    static let haptics = "haptics"
    static let cellularWarning = "cellularWarning"
    static let forwardBuffer = "forwardBuffer"

    // 字幕與音軌
    static let externalSubtitles = "externalSubtitles"
    static let autoEmbeddedSubtitles = "autoEmbeddedSubtitles"
    static let subtitleLanguage = "subtitleLanguage"
    static let audioLanguage = "audioLanguage"
    static let subtitleColor = "subtitleColor"
    static let subtitleEdgeColor = "subtitleEdgeColor"
    static let subtitleBold = "subtitleBold"
    static let subtitleItalic = "subtitleItalic"
    static let subtitleScale = "subtitleScale"

    /// 舊版的「續播時先詢問」
    static let legacyAskBeforeResume = "askBeforeResume"

    static func register() {
        let d = UserDefaults.standard
        // 0.2 版只有「續播時先詢問」開關
        if d.object(forKey: resumeMode) == nil, d.bool(forKey: legacyAskBeforeResume) {
            d.set(ResumeMode.ask.rawValue, forKey: resumeMode)
        }
        d.register(defaults: [
            skipForward: 10,
            skipBackward: 10,
            longPressRate: 2.0,
            resumeMode: ResumeMode.resume.rawValue,
            autoPlayNext: true,
            skipIntroOutro: true,
            autoMarkWatched: true,
            rememberSpeed: false,
            lastSpeed: 1.0,
            autoPiP: true,
            haptics: true,
            cellularWarning: true,
            forwardBuffer: 0.0,
            externalSubtitles: true,
            autoEmbeddedSubtitles: true,
            subtitleLanguage: MediaLanguage.traditionalChinese.rawValue,
            audioLanguage: "",
            subtitleColor: "FFFFFF",
            subtitleEdgeColor: "000000",
            subtitleBold: false,
            subtitleItalic: false,
            subtitleScale: 1.0,
        ])
    }

    static var defaults: UserDefaults { .standard }
    static func bool(_ key: String) -> Bool { defaults.bool(forKey: key) }
    static func double(_ key: String) -> Double { defaults.double(forKey: key) }
    static func string(_ key: String) -> String { defaults.string(forKey: key) ?? "" }

    static var resume: ResumeMode { ResumeMode(rawValue: string(resumeMode)) ?? .resume }
    static var subtitleLanguagePreference: MediaLanguage? { MediaLanguage(rawValue: string(subtitleLanguage)) }
    static var audioLanguagePreference: MediaLanguage? { MediaLanguage(rawValue: string(audioLanguage)) }
}

enum ResumeMode: String, CaseIterable, Identifiable {
    case resume, beginning, ask
    var id: Self { self }
    var title: String {
        switch self {
        case .resume: "繼續播放"
        case .beginning: "從頭播放"
        case .ask: "每次詢問"
        }
    }
}

/// 字幕顏色存成 RRGGBB
enum HexColor {
    static func uiColor(_ hex: String) -> UIColor {
        var value: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&value)
        return UIColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    static func string(_ color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        func c(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "%02X%02X%02X", c(r), c(g), c(b))
    }

    /// 給 ColorPicker 用的 Binding
    static func binding(_ storage: Binding<String>) -> Binding<Color> {
        Binding(
            get: { Color(uiColor: uiColor(storage.wrappedValue)) },
            set: { storage.wrappedValue = string(UIColor($0)) }
        )
    }
}

/// 觸覺回饋（設定可以關）
struct AppFeedback<T: Equatable>: ViewModifier {
    @AppStorage(Prefs.haptics) private var enabled = true
    let feedback: SensoryFeedback
    let trigger: T

    func body(content: Content) -> some View {
        content.sensoryFeedback(feedback, trigger: trigger) { _, _ in enabled }
    }
}

extension View {
    func appFeedback<T: Equatable>(_ feedback: SensoryFeedback, trigger: T) -> some View {
        modifier(AppFeedback(feedback: feedback, trigger: trigger))
    }

    /// 捲動內容碰到固定元件（導覽列、分頁列）時用柔和的漸層模糊過渡（iOS 26 起）
    @ViewBuilder
    func softScrollEdges() -> some View {
        if #available(iOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .all)
        } else {
            self
        }
    }
}
