import Foundation
import FoundationModels
import Translation

/// 課堂模式的即時翻譯：優先用系統「翻譯」框架（裝置上、很快），不能用時改用 Foundation Models。
@MainActor
final class LiveTranslator {
    private let source: Locale.Language
    private let target: Locale.Language
    private var session: TranslationSession?
    private var useModelFallback = false
    private var fallbackSession: LanguageModelSession?

    init(sourceLocale: String, target: String) {
        source = Locale(identifier: sourceLocale).language
        self.target = Locale.Language(identifier: target)
    }

    /// 檢查語言包；已下載就用翻譯框架，否則改用 Foundation Models。
    func prepare() async {
        let status = await LanguageAvailability().status(from: source, to: target)
        if status == .installed {
            session = TranslationSession(installedSource: source, target: target)
        } else {
            useModelFallback = true
            appLog.info("翻譯語言包未下載，改用 Foundation Models 翻譯")
        }
    }

    var engineName: String { useModelFallback ? "Apple Intelligence 翻譯" : "系統翻譯（裝置上）" }

    func translate(_ text: String) async -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !useModelFallback, let session {
            do {
                return try await session.translate(trimmed).targetText
            } catch {
                appLog.error("翻譯失敗，改用 Foundation Models：\(error.localizedDescription)")
                useModelFallback = true
            }
        }
        return await translateWithModel(trimmed)
    }

    private func translateWithModel(_ text: String) async -> String? {
        guard SystemLanguageModel.default.isAvailable else { return nil }
        // 每次新開 session，避免上下文累積爆掉
        let session = LanguageModelSession(
            model: SystemLanguageModel(guardrails: .permissiveContentTransformations),
            instructions: "你是即時口譯。把使用者給的句子翻成自然的台灣繁體中文，只輸出翻譯結果，不要解釋。專有名詞可保留原文。"
        )
        do {
            return try await session.respond(to: text).content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}

/// 翻譯語言包狀態（給設定畫面用）。
enum TranslationSupport {
    static func status(sourceLocale: String, target: String) async -> LanguageAvailability.Status {
        await LanguageAvailability().status(from: Locale(identifier: sourceLocale).language, to: Locale.Language(identifier: target))
    }
}
