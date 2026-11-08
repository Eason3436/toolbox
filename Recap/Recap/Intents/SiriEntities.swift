import AppIntents
import Foundation

// MARK: - 錯誤（Siri 會把這些句子唸出來）

enum RecapIntentError: Error, CustomLocalizedStringResourceConvertible {
    case microphoneDenied
    case notRecording
    case notPaused
    case lectureNotFound
    case remindersDenied
    case failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .microphoneDenied: "Recap 沒有麥克風權限，請到「設定 → Recap」打開麥克風。"
        case .notRecording: "Recap 目前沒有在錄音。"
        case .notPaused: "Recap 沒有暫停，正在錄音中。"
        case .lectureNotFound: "找不到這堂課，可能已經刪除了。"
        case .remindersDenied: "Recap 沒有提醒事項權限，請到「設定 → Recap」打開。"
        case .failed(let message): "\(message)"
        }
    }

    /// 把 App 內部錯誤轉成 Siri 唸得出來的句子
    static func from(_ error: Error) -> Error {
        if let error = error as? RecapError, case .microphoneDenied = error { return RecapIntentError.microphoneDenied }
        if error is CalendarError { return RecapIntentError.remindersDenied }
        if error is RecapIntentError { return error }
        return RecapIntentError.failed(error.localizedDescription)
    }
}

// MARK: - 科目

extension SchoolSubject: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "科目"
    static let caseDisplayRepresentations: [SchoolSubject: DisplayRepresentation] = [
        .general: DisplayRepresentation(title: "不指定"),
        .chinese: DisplayRepresentation(title: "國文", synonyms: ["國文課", "Chinese"]),
        .english: DisplayRepresentation(title: "英文", synonyms: ["英文課", "英語", "English"]),
        .math: DisplayRepresentation(title: "數學", synonyms: ["數學課", "Math"]),
        .physics: DisplayRepresentation(title: "物理", synonyms: ["物理課", "Physics"]),
        .chemistry: DisplayRepresentation(title: "化學", synonyms: ["化學課", "Chemistry"]),
        .biology: DisplayRepresentation(title: "生物", synonyms: ["生物課", "Biology"]),
        .earth: DisplayRepresentation(title: "地球科學", synonyms: ["地科", "Earth Science"]),
        .history: DisplayRepresentation(title: "歷史", synonyms: ["歷史課", "History"]),
        .geography: DisplayRepresentation(title: "地理", synonyms: ["地理課", "Geography"]),
        .civics: DisplayRepresentation(title: "公民與社會", synonyms: ["公民", "Civics"]),
        .seminar: DisplayRepresentation(title: "講座", synonyms: ["演講", "Seminar", "Talk"]),
    ]
}

// MARK: - 錄音片段

struct RecordingSegmentEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "錄音片段"
    static let defaultQuery = RecordingSegmentQuery()

    /// 「日期|片段 UUID」
    var id: String

    @Property(title: "開始時間")
    var start: Date
    @Property(title: "結束時間")
    var end: Date
    @Property(title: "標題")
    var title: String
    @Property(title: "重點")
    var points: [String]
    @Property(title: "逐字稿")
    var transcript: String

    init(dayKey: String, segment: Segment) {
        id = Self.makeID(dayKey: dayKey, segmentID: segment.id)
        start = segment.start
        end = segment.end
        title = (segment.title ?? "").isEmpty ? "\(segment.start.hm) 的錄音" : segment.title ?? ""
        points = segment.points
        transcript = String((segment.bestTranscript ?? "").prefix(4_000))
    }

    static func makeID(dayKey: String, segmentID: UUID) -> String { "\(dayKey)|\(segmentID.uuidString)" }

    static func parse(_ id: String) -> SegmentRoute? {
        let parts = id.split(separator: "|")
        guard parts.count == 2, let uuid = UUID(uuidString: String(parts[1])) else { return nil }
        return SegmentRoute(dayKey: String(parts[0]), id: uuid)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(start.formatted(.dateTime.month().day().hour().minute()))–\(end.hm)",
            image: .init(systemName: "waveform")
        )
    }

    var fullText: String {
        var text = "\(start.formatted(.dateTime.month().day().hour().minute())) 的錄音「\(title)」"
        if !points.isEmpty { text += "\n重點：\n" + points.map { "・\($0)" }.joined(separator: "\n") }
        if !transcript.isEmpty { text += "\n逐字稿：\n\(transcript)" }
        return text
    }
}

struct RecordingSegmentQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [RecordingSegmentEntity] {
        identifiers.compactMap { id in
            guard let route = RecordingSegmentEntity.parse(id),
                  let segment = RecapStore.shared.day(route.dayKey).segments.first(where: { $0.id == route.id }) else { return nil }
            return RecordingSegmentEntity(dayKey: route.dayKey, segment: segment)
        }
    }

    @MainActor
    func suggestedEntities() async throws -> [RecordingSegmentEntity] {
        Array(Self.all().prefix(30))
    }

    @MainActor
    func entities(matching string: String) async throws -> [RecordingSegmentEntity] {
        Self.all().filter { $0.title.localizedCaseInsensitiveContains(string) || $0.transcript.localizedCaseInsensitiveContains(string) }
    }

    /// 有內容的片段，新的在前
    @MainActor
    static func all(days: Int = 30) -> [RecordingSegmentEntity] {
        let store = RecapStore.shared
        return store.dayKeys.prefix(days).flatMap { key in
            store.day(key).segments
                .filter { $0.hasText }
                .sorted { $0.start > $1.start }
                .map { RecordingSegmentEntity(dayKey: key, segment: $0) }
        }
    }
}

// MARK: - 待辦

struct TodoEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Recap 待辦"
    static let defaultQuery = TodoQuery()

    /// 「day|日期|序號」或「lecture|課堂 UUID|序號」
    var id: String

    @Property(title: "內容")
    var text: String
    @Property(title: "來源")
    var source: String
    @Property(title: "提到的日期")
    var dueDate: Date?

    init(id: String, text: String, source: String) {
        self.id = id
        self.text = text
        self.source = source
        dueDate = CalendarActions.detectDateNonisolated(in: text)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(text)", subtitle: "\(source)", image: .init(systemName: "checklist"))
    }
}

struct TodoQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [TodoEntity] {
        let all = Self.all()
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    @MainActor
    func suggestedEntities() async throws -> [TodoEntity] {
        Array(Self.all().prefix(30))
    }

    @MainActor
    func entities(matching string: String) async throws -> [TodoEntity] {
        Self.all().filter { $0.text.localizedCaseInsensitiveContains(string) || $0.source.localizedCaseInsensitiveContains(string) }
    }

    /// 最近 14 天 Recap 與課堂裡的待辦，新的在前
    @MainActor
    static func all(days: Int = 14) -> [TodoEntity] {
        let store = RecapStore.shared
        var result: [TodoEntity] = []
        for key in store.dayKeys.prefix(days) {
            let record = store.day(key)
            let dayName = record.date.formatted(.dateTime.month().day())
            for (index, todo) in (record.recap?.todos ?? []).enumerated() {
                result.append(TodoEntity(id: "day|\(key)|\(index)", text: todo, source: "\(dayName) 的 Recap"))
            }
            for lecture in record.lectures.sorted(by: { $0.start > $1.start }) {
                for (index, todo) in (lecture.summary?.todos ?? []).enumerated() {
                    result.append(TodoEntity(id: "lecture|\(lecture.id.uuidString)|\(index)", text: todo, source: lecture.displayTitle))
                }
            }
        }
        return result
    }
}

extension CalendarActions {
    /// 給 Entity 用（不在主執行緒也能呼叫）
    nonisolated static func detectDateNonisolated(in text: String) -> Date? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        return detector.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text))?.date
    }
}

/// 螢幕感知用的 NSUserActivity 類型（也列在 Info.plist 的 NSUserActivityTypes）
enum SiriScreen {
    static let lectureActivity = "com.eason3436.recap.lecture"
    static let dayActivity = "com.eason3436.recap.day"
    static let segmentActivity = "com.eason3436.recap.segment"
}
