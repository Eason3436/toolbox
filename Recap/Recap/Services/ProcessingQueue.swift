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
            await self?.runLoop()
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
        let t = Task { [weak self] in await self?.runLoop() }
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
                await buildRecaps()
            }
        } while rerunRequested && !Task.isCancelled
    }

    private func transcribeAll() async {
        while !Task.isCancelled, let (key, segment) = nextSegment(status: .recorded) {
            guard let file = segment.audioFile else {
                store.updateSegment(segment.id, in: key) { $0.status = .failed; $0.error = "音檔不存在" }
                continue
            }
            statusText = "轉文字中（\(segment.start.formatted(date: .omitted, time: .shortened))）・還有 \(pendingTranscriptions) 段"
            do {
                let text = try await FileTranscriber.transcribe(url: store.audioURL(file), localeID: settings.transcriptionLocale)
                let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                store.updateSegment(segment.id, in: key) {
                    $0.transcript = text
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
        while !Task.isCancelled, allowSummaries, let (key, segment) = nextSegment(status: .transcribed) {
            statusText = "AI 摘要中・還有 \(pendingSummaries) 項"
            let label = segment.start.formatted(date: .omitted, time: .shortened)
            do {
                let digest = try await Summarizer.summarizeSegment(segment.transcript ?? "", timeLabel: label)
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
            do {
                let output = try await Summarizer.summarizeLecture(sourceText: lecture.sourceText, languageName: languageName)
                updated.summary = LectureSummary(title: output.title, overview: output.overview, keyPoints: output.keyPoints, terms: output.terms, todos: output.todos, generatedAt: .now)
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
                store.upsertLecture(latest)
            }
            store.update(DayKey.key(for: lecture.start)) { $0.recapDirty = true }
        }
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
            var entries: [Summarizer.Entry] = record.segments
                .filter { $0.status == .summarized && !($0.title ?? "").isEmpty }
                .map { Summarizer.Entry(time: $0.start, title: $0.title ?? "", points: $0.points, todos: $0.todos, isLecture: false) }
            entries += record.lectures.compactMap { lecture in
                guard let s = lecture.summary, !s.title.isEmpty else { return nil }
                return Summarizer.Entry(time: lecture.start, title: s.title, points: Array(s.keyPoints.prefix(4)), todos: s.todos, isLecture: true)
            }
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
