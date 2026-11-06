import Foundation
import Observation

/// 「最近 N 分鐘重點」：錄音中點一下，把最近一段時間的內容馬上轉文字並摘要。
@MainActor
@Observable
final class QuickRecap {
    enum State: Equatable {
        case idle
        case working(String)
        case done
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var minutes = 15
    private(set) var digest: SegmentDigest?
    private(set) var transcript = ""
    private(set) var range: ClosedRange<Date>?

    private let store: RecapStore
    private let settings: AppSettings
    private let recorder: RecordingController

    init(store: RecapStore, settings: AppSettings, recorder: RecordingController) {
        self.store = store
        self.settings = settings
        self.recorder = recorder
    }

    func run(minutes: Int) async {
        self.minutes = minutes
        digest = nil
        transcript = ""
        let now = Date()
        let cutoff = now.addingTimeInterval(-Double(minutes) * 60)
        range = cutoff...now
        guard ModelReadiness.current == .available else {
            state = .failed(ModelReadiness.current.message)
            return
        }
        do {
            let text: String
            let header: String
            if recorder.isActive, recorder.mode == .lecture, let session = recorder.lecture {
                state = .working("整理課堂內容…")
                let start = session.lecture.start
                text = session.lecture.lines
                    .filter { start.addingTimeInterval($0.offset) >= cutoff }
                    .map(\.source)
                    .joined(separator: "\n")
                header = "以下是課堂最近 \(minutes) 分鐘的逐字稿，請用繁體中文整理："
            } else {
                text = try await allDayText(since: cutoff)
                header = "以下是最近 \(minutes) 分鐘（\(cutoff.hm)–\(now.hm)）錄到的逐字稿："
            }
            transcript = text
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                state = .failed("最近 \(minutes) 分鐘沒有辨識到說話的內容。")
                return
            }
            state = .working("\(AIConfig.engineName) 摘要中…")
            let chunks = Summarizer.chunk(text)
            var parts: [SegmentDigest] = []
            var lastError: Error?
            for piece in chunks {
                do { parts.append(try await Summarizer.digest(text: piece, header: header)) } catch { lastError = error }
            }
            guard !parts.isEmpty else { throw lastError ?? RecapError.modelUnavailable("無法摘要") }
            digest = try await Summarizer.merge(parts, header: "以下是最近 \(minutes) 分鐘幾個部分的摘要，請合併：")
            state = .done
            Haptics.success()
        } catch {
            state = .failed(Summarizer.describe(error))
            Haptics.error()
        }
    }

    /// 全天模式：先把錄到一半的段落存起來，沒轉文字的馬上轉。
    private func allDayText(since cutoff: Date) async throws -> String {
        state = .working("存下目前的錄音…")
        recorder.flushCurrentSegment()
        try? await Task.sleep(for: .milliseconds(600))
        let keys = Set([DayKey.key(for: cutoff), DayKey.today])
        let segments = keys.flatMap { key in store.day(key).segments.map { (key, $0) } }
            .filter { $0.1.end >= cutoff && $0.1.status != .silent }
            .sorted { $0.1.start < $1.1.start }
        var parts: [String] = []
        for (index, item) in segments.enumerated() {
            let (key, segment) = item
            var text = segment.bestTranscript
            if text == nil, segment.status == .recorded, let file = segment.audioFile {
                state = .working("轉文字中（\(index + 1)/\(segments.count)）…")
                let result = try await FileTranscriber.transcribe(url: store.audioURL(file), localeID: settings.transcriptionLocale, vocabulary: settings.recognitionVocabulary())
                text = result
                let empty = result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                store.updateSegment(segment.id, in: key) {
                    if $0.status == .recorded {
                        $0.transcript = result
                        $0.status = empty ? .silent : .transcribed
                    }
                }
            }
            if let text, !text.isEmpty { parts.append("[\(segment.start.hm)]\n\(text)") }
        }
        return parts.joined(separator: "\n")
    }
}
