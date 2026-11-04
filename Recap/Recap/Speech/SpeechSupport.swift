import AVFoundation
import Speech

/// SpeechAnalyzer（iOS 26+）相關的共用工具。
enum SpeechSupport {
    /// 這台裝置支援哪些語言（實際查詢才準）
    static func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
    }

    /// 已下載好語音模型的語言
    static func installedLocales() async -> [Locale] {
        await SpeechTranscriber.installedLocales
    }

    /// 把設定裡的語言代碼對應到裝置真的支援的 Locale。
    static func resolve(_ identifier: String) async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier))
    }

    /// 確保語音模型已下載（第一次使用某語言時需要網路下載一次）。
    static func ensureAssets(for modules: [any SpeechModule]) async throws {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            try await request.downloadAndInstall()
        }
    }

    static func displayName(_ locale: Locale) -> String {
        let name = Locale(identifier: "zh-Hant-TW").localizedString(forIdentifier: locale.identifier) ?? locale.identifier
        return "\(name)（\(locale.identifier)）"
    }

    static func requestSpeechPermission() async {
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
            }
        }
    }
}

/// 把一個錄好的音檔轉成文字（全天模式用；不需連網，沒有時間長度限制）。
enum FileTranscriber {
    static func transcribe(url: URL, localeID: String) async throws -> String {
        guard let locale = await SpeechSupport.resolve(localeID) else { throw RecapError.localeUnsupported(localeID) }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        try await SpeechSupport.ensureAssets(for: [transcriber])
        let file = try AVAudioFile(forReading: url)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () throws -> [String] in
            var parts: [String] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { parts.append(text) }
            }
            return parts
        }
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collector.value.joined(separator: "\n")
    }
}
