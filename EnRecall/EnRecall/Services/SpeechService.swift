import AVFoundation

/// 單字發音。Siri 的聲音 Apple 不開放給 App，這裡改挑手機上品質最好的美式英文聲音：
/// 使用者在「設定 › 輔助使用 › 朗讀內容 › 聲音」下載過的高品質（Premium）或增強（Enhanced）聲音優先。
@MainActor
final class SpeechService {
    static let shared = SpeechService()

    private let synthesizer = AVSpeechSynthesizer()

    private init() {}

    /// 品質最好的 en-US 聲音；同品質時挑名字排序第一個，讓每次都是同一個聲音
    var bestVoice: AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "en-US" }
        let best = voices.max { a, b in
            if a.quality.rawValue != b.quality.rawValue { return a.quality.rawValue < b.quality.rawValue }
            return a.name > b.name
        }
        return best ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // 靜音模式也要能聽到發音
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = bestVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        synthesizer.speak(utterance)
    }
}
