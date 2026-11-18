import AVFoundation

/// 單字、例句發音。Siri 的聲音 Apple 不開放給 App，能用的是「設定 › 輔助使用 › 朗讀內容 › 聲音」裡下載的聲音。
/// 設定 › 發音可以選聲音（預設「自動」：品質最好的美式英文）和語速
@MainActor
final class SpeechService {
    static let shared = SpeechService()

    /// 語速（AVSpeechUtteranceDefaultSpeechRate 的倍數）
    static let rateRange: ClosedRange<Double> = 0.5...1.5
    static let defaultRate = 0.9

    private let synthesizer = AVSpeechSynthesizer()

    private init() {}

    /// 手機上 App 看得到的英文聲音：品質好的在前，美式在前，其餘照名字。不含 Bubbles 那種趣味聲音
    static func englishVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") && !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice) }
            .sorted { a, b in
                if a.quality.rawValue != b.quality.rawValue { return a.quality.rawValue > b.quality.rawValue }
                let aUS = a.language == "en-US"
                let bUS = b.language == "en-US"
                if aUS != bUS { return aUS }
                if a.name != b.name { return a.name < b.name }
                return a.language < b.language
            }
    }

    /// 「自動」用的聲音：品質最好的 en-US
    static var automaticVoice: AVSpeechSynthesisVoice? {
        englishVoices().first { $0.language == "en-US" } ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    /// 設定選的聲音；沒選或已經被刪掉就用自動
    static var selectedVoice: AVSpeechSynthesisVoice? {
        let identifier = UserDefaults.standard.string(forKey: SettingsKey.speechVoice) ?? ""
        if !identifier.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            return voice
        }
        return automaticVoice
    }

    static var selectedRate: Double {
        let stored = UserDefaults.standard.object(forKey: SettingsKey.speechRate) as? Double ?? defaultRate
        return min(max(stored, rateRange.lowerBound), rateRange.upperBound)
    }

    /// voice、rate 沒給就用設定的（試聽時才會給）
    func speak(_ text: String, voice: AVSpeechSynthesisVoice? = nil, rate: Double? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // 靜音模式也要能聽到發音
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = voice ?? Self.selectedVoice
        let speed = Float(rate ?? Self.selectedRate) * AVSpeechUtteranceDefaultSpeechRate
        utterance.rate = min(max(speed, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
        synthesizer.speak(utterance)
    }
}

extension AVSpeechSynthesisVoice {
    /// 「英文（美國）」
    var languageTitle: String {
        Locale.current.localizedString(forIdentifier: language) ?? language
    }

    var qualityTitle: String {
        switch quality {
        case .premium: "高音質"
        case .enhanced: "增強音質"
        default: "標準"
        }
    }
}
