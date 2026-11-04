import Foundation
import Observation
import UIKit

/// 背後處理：轉文字 → 每段摘要 → 課堂重點 → 今日 Recap。一次只做一件事。
@MainActor
@Observable
final class ProcessingQueue {
    private let store: RecapStore
    private let settings: AppSettings

    private(set) var isRunning = false
    private(set) var statusText: String?
    private(set) var readiness: ModelReadiness = .current
    private var task: Task<Void, Never>?
    /// 是否允許跑 AI 摘要（App 在前景、背景任務、或使用者按了「整理」）
    private var allowSummaries = false
    private var rerunRequested = false
    /// 正在被即時錄音寫入的那天，Recap 不要太頻繁重算
    private var lastRecapRun: [String: Date] = [:]

    init(store: RecapStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
    }

    var pendingTranscriptions: Int {
        store.days.values.reduce(0) { $0 + $1.segments.filter { $0.status == .recorded }.count }
    }

    var pendingSummaries: Int {
        store.days.values.reduce(0) { total, day in
            total + day.segments.filter { $0.status == .transcribed }.count + day.lectures.filter(\.needsSummary).count
        }
    }

    var hasWork: Bool { pendingTranscriptions > 0 || pendingSummaries > 0 || store.days.values.contains { $0.recapDirty } }

    /// 叫醒佇列。`summaries` 為 true 時連摘要也做。
    func kick(summaries: Bool) {
        if summaries { allowSummaries = true }
        if isRunning { rerunRequested = true; return }
        isRunning = true
        task = Task { [weak self] in
            guard let self else { return }
            await self.runLoop()
        }
    }

    /// App 退到背景：不再開始新的摘要（轉文字照做，錄音中 App 會一直活著）。
    func enterBackground() {
        allowSummaries = false
    }

    /// 背景任務（接電源時）要用：跑完全部再回來。
    func runToCompletion() async {
        allowSummaries = true
        if isRunning, let task { await task.value }
        isRunning = true
        let t = Task { [weak self] in
            guard let self else { return }
            await self.runLoop()
        }
        task = t
        await t.value
    }

    func cancel() {
        task?.cancel()
    }

    /// 立即重新產生某天的 Recap（使用者按按鈕）。
    func regenerateRecap(_ key: String) {
        store.update(key) { $0.recapDirty = true }
        lastRecapRun[key] = nil
        kick(summaries: true)
    }

    func resummarizeLecture(_ id: UUID) {
        guard var lecture = store.lecture(id) else { return }
        lecture.summary = nil
        lecture.summaryError = nil
        lecture.richNotes = nil
        lecture.richNotesError = nil
        store.upsertLecture(lecture)
        kick(summaries: true)
    }

    // MARK: -

    private func runLoop() async {
        var background = UIBackgroundTaskIdentifier.invalid
        background = UIApplication.shared.beginBackgroundTask(withName: "RecapProcessing") {
            UIApplication.shared.endBackgroundTask(background)
        }
        defer {
            UIApplication.shared.endBackgroundTask(background)
            isRunning = false
            statusText = nil
        }
        repeat {
            rerunRequested = false
            await transcribeAll()
            readiness = .current
            if allowSummaries, readiness == .available, !Task.isCancelled {
                await summarizeSegments()
                await summarizeLectures()
                await buildRichNotes()
                await buildRecaps()
            }
        } while rerunRequested && !Task.isCancelled
        store.purgeAudio(olderThan: settings.audioRetentionDays)
        SiriIndex.refresh()
    }

    private func transcribeAll() async {
        while !Task.isCancelled, let next = nextSegment(status: .recorded) {
            let (key, segment) = next
            guard let file = segment.audioFile else {
                store.updateSegment(segment.id, in: key) { $0.status = .failed; $0.error = "音檔不存在" }
                continue
            }
            statusText = "轉文字中（\(segment.start.formatted(date: .omitted, time: .shortened))）・還有 \(pendingTranscriptions) 段"
            do {
                let url = store.audioURL(file)
                let vocabulary = settings.recognitionVocabulary()
                var text: String
                var windows: [AlignedWindow]?
                if let secondary = settings.secondaryLocale(for: settings.transcriptionLocale) {
                    let mixed = try await FileTranscriber.transcribeMixed(url: url, primary: settings.transcriptionLocale, secondary: secondary, vocabulary: vocabulary)
                    text = mixed.text
                    windows = mixed.windows.isEmpty ? nil : mixed.windows
                } else {
                    text = try await FileTranscriber.transcribe(url: url, localeID: settings.transcriptionLocale, vocabulary: vocabulary)
                }
                let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                store.updateSegment(segment.id, in: key) {
                    $0.transcript = text
                    $0.aligned = windows
                    $0.correctedTranscript = nil
                    $0.status = empty ? .silent : .transcribed
                    $0.error = nil
                }
                if settings.deleteAudioAfterTranscribe {
                    store.removeAudio(file)
                    store.updateSegment(segment.id, in: key) { $0.audioFile = nil }
                }
            } catch {
                appLog.error("轉文字失敗：\(error.localizedDescription)")
                store.updateSegment(segment.id, in: key) { $0.status = .failed; $0.error = error.localizedDescription }
                if error is RecapError { break } // 語言不支援等：先停，等使用者改設定
            }
        }
    }

    private func summarizeSegments() async {
        while !Task.isCancelled, allowSummaries, let next = nextSegment(status: .transcribed) {
            let (key, segment) = next
            statusText = "AI 摘要中・還有 \(pendingSummaries) 項"
            let label = segment.start.formatted(date: .omitted, time: .shortened)
            var text = segment.bestTranscript ?? ""
            if segment.correctedTranscript == nil, let windows = segment.aligned, !windows.isEmpty {
                statusText = "AI 合併中英辨識・還有 \(pendingSummaries) 項"
                let names = Self.languageNames(settings.transcriptionLocale)
                if let merged = await Summarizer.mergeMixed(windows, primaryName: names.0, secondaryName: names.1, vocabulary: settings.recognitionVocabulary(), context: settings.highSchoolMode ? "使用者是台灣高中生，內容可能是上課或同學間的對話。" : "") {
                    text = merged
                    store.updateSegment(segment.id, in: key) { $0.correctedTranscript = merged }
                    LearningMemory.shared.learn(corrected: merged, original: segment.transcript ?? "", subject: nil)
                }
                statusText = "AI 摘要中・還有 \(pendingSummaries) 項"
            } else if settings.aiCorrection, segment.correctedTranscript == nil, let raw = segment.transcript {
                statusText = "AI 校正逐字稿・還有 \(pendingSummaries) 項"
                if let fixed = await Summarizer.correctTranscript(raw, vocabulary: settings.recognitionVocabulary(), context: settings.highSchoolMode ? "使用者是台灣高中生，內容可能是上課或同學間的對話。" : "") {
                    text = fixed
                    store.updateSegment(segment.id, in: key) { $0.correctedTranscript = fixed }
                    LearningMemory.shared.learn(corrected: fixed, original: raw, subject: nil)
                }
                statusText = "AI 摘要中・還有 \(pendingSummaries) 項"
            }
            do {
                let digest = try await Summarizer.summarizeSegment(text, timeLabel: label)
                store.updateSegment(segment.id, in: key) {
                    $0.title = digest.title
                    $0.points = digest.points
                    $0.todos = digest.todos
                    $0.status = .summarized
                    $0.error = nil
                }
                store.update(key) { $0.recapDirty = true }
            } catch is CancellationError {
                return
            } catch {
                let message = Summarizer.describe(error)
                appLog.error("摘要失敗：\(message)")
                // 用逐字稿開頭當標題，不要卡住整個佇列
                store.updateSegment(segment.id, in: key) {
                    $0.title = String(($0.transcript ?? "").prefix(16))
                    $0.points = []
                    $0.status = .summarized
                    $0.error = message
                }
                store.update(key) { $0.recapDirty = true }
            }
        }
    }

    private func summarizeLectures() async {
        let pending = store.allLectures.filter(\.needsSummary)
        for lecture in pending {
            guard !Task.isCancelled, allowSummaries else { return }
            statusText = "整理課堂重點：\(lecture.displayTitle)"
            let languageName = Locale(identifier: "zh-Hant-TW").localizedString(forIdentifier: lecture.sourceLocale) ?? lecture.sourceLocale
            var updated = lecture
            // 中英夾雜：下課後用錄音重新辨識一次，AI 合併成更準的逐字稿
            if updated.refinedTranscript == nil, let secondary = settings.secondaryLocale(for: lecture.sourceLocale), !lecture.audioParts.isEmpty {
                statusText = "重新辨識中英夾雜：\(lecture.displayTitle)"
                if let refined = await refineLecture(lecture, secondary: secondary) {
                    updated.refinedTranscript = refined
                    if var latest = store.lecture(lecture.id) {
                        latest.refinedTranscript = refined
                        store.upsertLecture(latest)
                    }
                }
                statusText = "整理課堂重點：\(lecture.displayTitle)"
            }
            do {
                let memory = LearningMemory.previousLectureContext(for: lecture, in: store)
                let output = try await Summarizer.summarizeLecture(sourceText: updated.refinedTranscript ?? lecture.sourceText, languageName: languageName, subject: lecture.subject, memory: memory)
                updated.summary = LectureSummary(title: output.title, overview: output.overview, keyPoints: output.keyPoints, terms: output.terms, todos: output.todos, generatedAt: .now, examPoints: output.examPoints)
                // 沒選科目：用 AI 判斷的
                if updated.subject == nil || updated.subject == .general, let guess = output.subject {
                    updated.subject = guess
                }
                LearningMemory.shared.learn(fromTerms: output.terms, subject: updated.subject)
                updated.summaryError = nil
            } catch is CancellationError {
                return
            } catch {
                updated.summaryError = Summarizer.describe(error)
                updated.summary = LectureSummary(title: "", overview: "", keyPoints: [], terms: [], todos: [], generatedAt: .now)
            }
            // 重新取一次，避免覆蓋錄音中途更新的內容
            if var latest = store.lecture(lecture.id) {
                latest.summary = updated.summary
                latest.summaryError = updated.summaryError
                latest.subject = updated.subject
                store.upsertLecture(latest)
            }
        }
    }

    /// 選了 Gemini：每堂整理好的課再做一份詳細筆記。
    private func buildRichNotes() async {
        guard AIConfig.usesGemini else { return }
        let pending = store.allLectures.filter { $0.end != nil && $0.summary != nil && $0.richNotes == nil && $0.richNotesError == nil && !$0.lines.isEmpty }
        for lecture in pending {
            guard !Task.isCancelled, allowSummaries else { return }
            statusText = "Gemini 製作課程筆記：\(lecture.displayTitle)"
            let transcript = lecture.refinedTranscript ?? lecture.lines.map { "[\($0.offset.clockText)] \($0.source)" }.joined(separator: "\n")
            var notes: String?
            var failure: String?
            do {
                notes = try await RichNotes.generate(lecture: lecture, transcript: transcript, memory: LearningMemory.previousLectureContext(for: lecture, in: store))
            } catch is CancellationError {
                return
            } catch {
                failure = error.localizedDescription
                appLog.error("課程筆記失敗：\(error.localizedDescription)")
            }
            if var latest = store.lecture(lecture.id) {
                latest.richNotes = notes
                latest.richNotesError = failure
                store.upsertLecture(latest)
            }
        }
    }

    /// 重新產生某堂課的詳細筆記。
    func regenerateRichNotes(_ id: UUID) {
        guard var lecture = store.lecture(id) else { return }
        lecture.richNotes = nil
        lecture.richNotesError = nil
        store.upsertLecture(lecture)
        kick(summaries: true)
    }

    private func refineLecture(_ lecture: Lecture, secondary: String) async -> String? {
        let vocabulary = settings.recognitionVocabulary(subject: lecture.subject)
        let names = Self.languageNames(lecture.sourceLocale)
        var parts: [String] = []
        for part in lecture.audioParts.sorted(by: { $0.start < $1.start }) {
            guard !Task.isCancelled else { return nil }
            let url = store.audioURL(part.file)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                let mixed = try await FileTranscriber.transcribeMixed(url: url, primary: lecture.sourceLocale, secondary: secondary, vocabulary: vocabulary)
                let context = "這是台灣高中\(lecture.subject.map { $0 == .general ? "" : "「\($0.title)」" } ?? "")課的錄音，老師上課常中英夾雜。"
                let merged = await Summarizer.mergeMixed(mixed.windows, primaryName: names.0, secondaryName: names.1, vocabulary: vocabulary, context: context)
                if let merged { LearningMemory.shared.learn(corrected: merged, original: mixed.text, subject: lecture.subject) }
                if let text = merged ?? (mixed.text.isEmpty ? nil : mixed.text) { parts.append(text) }
            } catch {
                appLog.info("課堂重新辨識失敗：\(error.localizedDescription)")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// (主要語言名, 第二語言名)
    static func languageNames(_ primary: String) -> (String, String) {
        primary.hasPrefix("en") ? ("英文", "中文") : ("中文", "英文")
    }

    private func buildRecaps() async {
        for key in store.dayKeys {
            guard !Task.isCancelled, allowSummaries else { return }
            let record = store.day(key)
            guard record.recapDirty else { continue }
            // 還有這天的段落沒整理完，就先不做
            if record.segments.contains(where: { $0.status == .recorded || $0.status == .transcribed }) { continue }
            // 今天：最多 10 分鐘重算一次
            if let last = lastRecapRun[key], Date().timeIntervalSince(last) < 600 { continue }
            let entries: [Summarizer.Entry] = record.segments
                .filter { $0.status == .summarized && !($0.title ?? "").isEmpty }
                .map { Summarizer.Entry(time: $0.start, title: $0.title ?? "", points: $0.points, todos: $0.todos, isLecture: false) }
            // 課堂內容只放在課堂頁，不進今日 Recap
            guard !entries.isEmpty else {
                store.update(key) { $0.recapDirty = false; $0.recap = nil }
                continue
            }
            statusText = "產生 \(key) 的 Recap"
            lastRecapRun[key] = .now
            let dayLabel = record.date.formatted(.dateTime.month().day().weekday(.wide))
            do {
                let output = try await Summarizer.dailyRecap(entries: entries, dayLabel: dayLabel)
                store.update(key) {
                    $0.recap = DailyRecap(title: output.title, overview: output.overview, highlights: output.highlights, todos: output.todos, generatedAt: .now, sourceCount: entries.count)
                    $0.recapDirty = false
                }
            } catch is CancellationError {
                return
            } catch {
                appLog.error("Recap 失敗：\(Summarizer.describe(error))")
                statusText = "Recap 失敗：\(Summarizer.describe(error))"
            }
        }
    }

    /// 最舊的待處理段落（舊的先做，今天的也照時間順序）。
    private func nextSegment(status: SegmentStatus) -> (String, Segment)? {
        for key in store.dayKeys.reversed() {
            if let segment = store.day(key).segments.first(where: { $0.status == status }) {
                return (key, segment)
            }
        }
        return nil
    }
}
