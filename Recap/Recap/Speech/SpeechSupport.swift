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

    /// 自訂詞彙（人名、術語）告訴辨識器，提高這些詞的辨識率。
    static func applyVocabulary(_ words: [String], to analyzer: SpeechAnalyzer) async {
        let cleaned = words.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }
        let context = AnalysisContext()
        context.contextualStrings[.general] = cleaned
        do {
            try await analyzer.setContext(context)
        } catch {
            appLog.info("設定自訂詞彙失敗：\(error.localizedDescription)")
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
    static func transcribe(url: URL, localeID: String, vocabulary: [String] = []) async throws -> String {
        guard let locale = await SpeechSupport.resolve(localeID) else { throw RecapError.localeUnsupported(localeID) }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        try await SpeechSupport.ensureAssets(for: [transcriber])
        let file = try AVAudioFile(forReading: url)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        await SpeechSupport.applyVocabulary(vocabulary, to: analyzer)
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

extension FileTranscriber {
    /// 帶時間的辨識結果（秒數, 文字）
    static func transcribeTimed(url: URL, localeID: String, vocabulary: [String] = []) async throws -> [(Double, String)] {
        guard let locale = await SpeechSupport.resolve(localeID) else { throw RecapError.localeUnsupported(localeID) }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        try await SpeechSupport.ensureAssets(for: [transcriber])
        let file = try AVAudioFile(forReading: url)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        await SpeechSupport.applyVocabulary(vocabulary, to: analyzer)
        let collector = Task { () throws -> [(Double, String)] in
            var parts: [(Double, String)] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                let seconds = result.range.start.seconds
                if !text.isEmpty { parts.append((seconds.isFinite ? seconds : 0, text)) }
            }
            return parts
        }
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collector.value
    }

    /// 中英夾雜：主要語言、第二語言各辨識一次，切成約 20 秒的時間窗對齊。
    /// 回傳主要語言的全文（顯示用）與對齊結果（給 AI 合併）。
    static func transcribeMixed(url: URL, primary: String, secondary: String, vocabulary: [String]) async throws -> (text: String, windows: [AlignedWindow]) {
        let first = try await transcribeTimed(url: url, localeID: primary, vocabulary: vocabulary)
        let text = first.map(\.1).joined(separator: "\n")
        guard !first.isEmpty else { return (text, []) }
        let second: [(Double, String)]
        do {
            second = try await transcribeTimed(url: url, localeID: secondary, vocabulary: vocabulary)
        } catch {
            appLog.info("第二語言辨識失敗：\(error.localizedDescription)")
            return (text, [])
        }
        return (text, align(first, second))
    }

    static func align(_ first: [(Double, String)], _ second: [(Double, String)], window: Double = 20) -> [AlignedWindow] {
        let end = max(first.last?.0 ?? 0, second.last?.0 ?? 0)
        var result: [AlignedWindow] = []
        var start = 0.0
        while start <= end {
            let a = first.filter { $0.0 >= start && $0.0 < start + window }.map(\.1).joined(separator: " ")
            let b = second.filter { $0.0 >= start && $0.0 < start + window }.map(\.1).joined(separator: " ")
            if !a.isEmpty || !b.isEmpty { result.append(AlignedWindow(offset: start, primary: a, secondary: b)) }
            start += window
        }
        return result
    }
}
