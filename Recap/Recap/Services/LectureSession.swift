import Foundation
import Observation

/// 進行中的一堂課：即時字幕與翻譯。
@MainActor
@Observable
final class LectureSession {
    private(set) var lecture: Lecture
    /// 還沒確定的那句（原文）
    private(set) var volatileText = ""
    /// 暫定句的翻譯（草稿）
    private(set) var volatileTranslation = ""
    private(set) var translatorName = ""
    private(set) var lastTranslation: String?

    let transcriber = LiveTranscriber()
    private let translator: LiveTranslator
    private var volatileTranslating = false
    private var pendingVolatile: String?
    private var lastSave = Date()
    private let store: RecapStore
    var onNewTranslation: ((String) -> Void)?

    /// 即時字幕與翻譯（非中文授課）；false 時只錄音
    let isLive: Bool

    init(lecture: Lecture, store: RecapStore, live: Bool = true) {
        self.lecture = lecture
        self.store = store
        isLive = live
        translator = LiveTranslator(sourceLocale: lecture.sourceLocale, target: lecture.targetLanguage)
    }

    func start() async throws {
        guard isLive else {
            translatorName = "只錄音"
            store.upsertLecture(lecture)
            return
        }
        await translator.prepare()
        translatorName = translator.engineName
        transcriber.onResult = { [weak self] text, isFinal in
            self?.handle(text: text, isFinal: isFinal)
        }
        try await transcriber.start(localeID: lecture.sourceLocale, vocabulary: AppSettings.shared.recognitionVocabulary(subject: lecture.subject))
        store.upsertLecture(lecture)
    }

    func addAudioPart(_ part: AudioPart) {
        lecture.audioParts.append(part)
        store.upsertLecture(lecture)
    }

    /// 結束這堂課，回傳最後的資料。
    func finish() async -> Lecture {
        if !isLive {
            lecture.end = .now
            store.upsertLecture(lecture)
            return lecture
        }
        await transcriber.finish()
        if !volatileText.trimmingCharacters(in: .whitespaces).isEmpty {
            handle(text: volatileText, isFinal: true)
        }
        // 等最後幾句翻譯（最多 5 秒）
        for _ in 0..<10 where lecture.lines.contains(where: { $0.translation == nil }) {
            try? await Task.sleep(for: .milliseconds(500))
        }
        lecture.end = .now
        store.upsertLecture(lecture)
        return lecture
    }

    private func handle(text: String, isFinal: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinal {
            volatileText = ""
            volatileTranslation = ""
            guard !trimmed.isEmpty else { return }
            let line = LiveLine(offset: Date().timeIntervalSince(lecture.start), source: trimmed)
            lecture.lines.append(line)
            translateLine(line.id, text: trimmed)
            saveIfNeeded()
        } else {
            volatileText = trimmed
            translateVolatile(trimmed)
        }
    }

    private func translateLine(_ id: UUID, text: String) {
        Task {
            let result = await translator.translate(text)
            guard let index = lecture.lines.firstIndex(where: { $0.id == id }) else { return }
            lecture.lines[index].translation = result ?? ""
            if let result, !result.isEmpty {
                lastTranslation = result
                onNewTranslation?(result)
            }
        }
    }

    /// 暫定句：同時只翻一句，翻完再翻最新的那版。
    private func translateVolatile(_ text: String) {
        guard text.count > 8 else { return }
        if volatileTranslating { pendingVolatile = text; return }
        volatileTranslating = true
        Task {
            let result = await translator.translate(text)
            volatileTranslating = false
            if !volatileText.isEmpty, let result { volatileTranslation = result }
            if let next = pendingVolatile {
                pendingVolatile = nil
                if next == volatileText { translateVolatile(next) }
            }
        }
    }

    private func saveIfNeeded() {
        if Date().timeIntervalSince(lastSave) > 20 {
            lastSave = .now
            store.upsertLecture(lecture)
        }
    }
}
