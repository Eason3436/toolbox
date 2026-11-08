import AppIntents
import CoreSpotlight
import Foundation

// 讓 Siri / Apple Intelligence 讀得到 Recap 的內容：每日 Recap 與課堂筆記都是 App Entity，
// 並索引到 Spotlight，Siri 可以搜尋、引用，也可以用下面的 Intent 直接提問。

struct DayRecapEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "每日 Recap"
    static let defaultQuery = DayRecapQuery()

    /// yyyy-MM-dd
    var id: String

    @Property(title: "日期")
    var date: Date
    @Property(title: "標題")
    var title: String
    @Property(title: "總結")
    var overview: String
    @Property(title: "重點")
    var highlights: [String]
    @Property(title: "待辦")
    var todos: [String]
    @Property(title: "時間軸")
    var timeline: String

    init(record: DayRecord) {
        id = record.dayKey
        date = record.date
        title = record.recap?.title ?? "尚未整理"
        overview = record.recap?.overview ?? ""
        highlights = record.recap?.highlights ?? []
        todos = record.recap?.todos ?? []
        timeline = record.spokenSegments
            .filter { !($0.title ?? "").isEmpty }
            .map { "\($0.start.hm) \($0.title ?? "")：\($0.points.joined(separator: "；"))" }
            .joined(separator: "\n")
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(date.formatted(.dateTime.month().day())) \(title)",
            subtitle: "\(overview)",
            image: .init(systemName: "sparkles")
        )
    }

    /// 給 Siri 讀的完整文字。
    var fullText: String {
        var text = "\(date.formatted(.dateTime.year().month().day().weekday(.wide))) 的 Recap：\(title)。\(overview)"
        if !highlights.isEmpty { text += "\n重點：\n" + highlights.map { "・\($0)" }.joined(separator: "\n") }
        if !todos.isEmpty { text += "\n待辦：\n" + todos.map { "・\($0)" }.joined(separator: "\n") }
        if !timeline.isEmpty { text += "\n時間軸：\n\(timeline)" }
        return text
    }
}

struct DayRecapQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [DayRecapEntity] {
        identifiers.map { DayRecapEntity(record: RecapStore.shared.day($0)) }
    }

    @MainActor
    func suggestedEntities() async throws -> [DayRecapEntity] {
        RecapStore.shared.dayKeys.prefix(14).map { DayRecapEntity(record: RecapStore.shared.day($0)) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [DayRecapEntity] {
        if let key = Self.relativeDayKey(string) { return [DayRecapEntity(record: RecapStore.shared.day(key))] }
        return RecapStore.shared.dayKeys.map { RecapStore.shared.day($0) }
            .map(DayRecapEntity.init(record:))
            .filter { $0.fullText.localizedCaseInsensitiveContains(string) }
    }
}

extension DayRecapQuery {
    /// 「今天」「昨天」「前天」「星期一」「today」「yesterday」
    static func relativeDayKey(_ text: String) -> String? {
        let t = text.lowercased()
        let calendar = Calendar.current
        let today = Date()
        if t.contains("今天") || t.contains("today") { return DayKey.key(for: today) }
        if t.contains("前天") { return calendar.date(byAdding: .day, value: -2, to: today).map(DayKey.key(for:)) }
        if t.contains("昨天") || t.contains("yesterday") { return calendar.date(byAdding: .day, value: -1, to: today).map(DayKey.key(for:)) }
        let names = [("日", 1), ("天", 1), ("一", 2), ("二", 3), ("三", 4), ("四", 5), ("五", 6), ("六", 7)]
        for prefix in ["星期", "禮拜", "週", "周"] {
            for (name, weekday) in names where t.contains(prefix + name) {
                // 最近的那一天（今天以前，含今天）
                for back in 0..<7 {
                    if let day = calendar.date(byAdding: .day, value: -back, to: today), calendar.component(.weekday, from: day) == weekday {
                        return DayKey.key(for: day)
                    }
                }
            }
        }
        return nil
    }
}

struct LectureEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "課堂筆記"
    static let defaultQuery = LectureQuery()

    var id: UUID

    @Property(title: "上課時間")
    var start: Date
    @Property(title: "主題")
    var title: String
    @Property(title: "科目")
    var subject: String
    @Property(title: "總結")
    var overview: String
    @Property(title: "重點")
    var keyPoints: [String]
    @Property(title: "老師說會考")
    var examPoints: [String]
    @Property(title: "術語")
    var terms: [String]
    @Property(title: "作業與提醒")
    var todos: [String]

    init(lecture: Lecture) {
        id = lecture.id
        start = lecture.start
        title = lecture.displayTitle
        subject = lecture.subject.map { $0 == .general ? "" : $0.title } ?? ""
        overview = lecture.summary?.overview ?? ""
        keyPoints = lecture.summary?.keyPoints ?? []
        examPoints = lecture.summary?.examPoints ?? []
        terms = lecture.summary?.terms ?? []
        todos = lecture.summary?.todos ?? []
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(subject.isEmpty ? "" : subject + "・")\(start.formatted(date: .abbreviated, time: .shortened))",
            image: .init(systemName: "graduationcap")
        )
    }

    var fullText: String {
        var text = "課堂「\(title)」（\(start.formatted(date: .abbreviated, time: .shortened))）。\(overview)"
        if !keyPoints.isEmpty { text += "\n重點：\n" + keyPoints.map { "・\($0)" }.joined(separator: "\n") }
        if !examPoints.isEmpty { text += "\n老師說會考：\n" + examPoints.map { "・\($0)" }.joined(separator: "\n") }
        if !terms.isEmpty { text += "\n術語：\n" + terms.map { "・\($0)" }.joined(separator: "\n") }
        if !todos.isEmpty { text += "\n作業與提醒：\n" + todos.map { "・\($0)" }.joined(separator: "\n") }
        return text
    }
}

struct LectureQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [LectureEntity] {
        identifiers.compactMap { RecapStore.shared.lecture($0) }.map(LectureEntity.init(lecture:))
    }

    @MainActor
    func suggestedEntities() async throws -> [LectureEntity] {
        RecapStore.shared.allLectures.prefix(20).map(LectureEntity.init(lecture:))
    }

    @MainActor
    func entities(matching string: String) async throws -> [LectureEntity] {
        let query = string.replacingOccurrences(of: "課", with: "").trimmingCharacters(in: .whitespaces)
        let all = RecapStore.shared.allLectures.map(LectureEntity.init(lecture:))
        guard !query.isEmpty else { return all }
        // 先比課名和科目（「化學課」「上一堂英文」），再比內容
        let byName = all.filter { $0.title.localizedCaseInsensitiveContains(query) || (!$0.subject.isEmpty && query.contains($0.subject)) || $0.subject.localizedCaseInsensitiveContains(query) }
        if !byName.isEmpty { return byName }
        return all.filter { $0.fullText.localizedCaseInsensitiveContains(query) }
    }
}

/// 把 Recap 與課堂筆記放進 Spotlight，Siri 才找得到。
enum SiriIndex {
    @MainActor
    static func refresh() {
        let store = RecapStore.shared
        let days = store.dayKeys.prefix(60).map { store.day($0) }.filter { $0.recap != nil }.map(DayRecapEntity.init(record:))
        let lectures = store.allLectures.prefix(100).filter { $0.summary != nil }.map(LectureEntity.init(lecture:))
        let segments = Array(RecordingSegmentQuery.all(days: 14).filter { !$0.points.isEmpty }.prefix(300))
        let todos = TodoQuery.all()
        Task.detached {
            do {
                try await CSSearchableIndex.default().indexAppEntities(days)
                try await CSSearchableIndex.default().indexAppEntities(lectures)
                try await CSSearchableIndex.default().indexAppEntities(segments)
                try await CSSearchableIndex.default().indexAppEntities(todos)
            } catch {
                appLog.error("Spotlight 索引失敗：\(error.localizedDescription)")
            }
        }
        // 讓「打開 Recap 的〇〇課」這類帶參數的語句認得最新的課
        RecapShortcuts.updateAppShortcutParameters()
    }

    /// 刪掉課堂時一起從 Siri／Spotlight 移除
    static func remove(lecture id: UUID) {
        Task.detached {
            try? await CSSearchableIndex.default().deleteAppEntities(identifiedBy: [id], ofType: LectureEntity.self)
        }
    }
}

// MARK: - 給 Siri 用的 Intent

/// 「取得 Recap」：回傳某天（預設今天）的完整摘要文字，Siri 可以拿來回答或做後續動作。
struct GetDayRecapIntent: AppIntent {
    static let title: LocalizedStringResource = "取得 Recap"
    static let description = IntentDescription("取得某一天錄音整理出的標題、重點、待辦與時間軸。")

    @Parameter(title: "日期", description: "不填就是今天")
    var date: Date?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let key = DayKey.key(for: date ?? .now)
        let record = RecapStore.shared.day(key)
        guard record.recap != nil || !record.segments.isEmpty else {
            return .result(value: "這天沒有錄音紀錄。", dialog: "這天沒有錄音紀錄。")
        }
        let entity = DayRecapEntity(record: record)
        let text = record.recap == nil ? "這天的 Recap 還沒整理好。\n\(entity.timeline)" : entity.fullText
        return .result(value: text, dialog: "\(entity.title)。\(entity.overview)")
    }
}

/// 「問 Recap」：用錄音逐字稿回答問題（含課堂）。
struct AskRecapIntent: AppIntent {
    static let title: LocalizedStringResource = "問 Recap"
    static let description = IntentDescription("根據你最近的錄音與課堂逐字稿回答問題，並附上是幾點講的。")
    static let openAppWhenRun = false

    @Parameter(title: "問題")
    var question: String

    @Parameter(title: "查最近幾天", default: 7)
    var days: Int

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let passages = AskService.passages(for: .recent(max(1, days)), store: RecapStore.shared)
        let result = try await AskService.ask(question, passages: passages, previous: nil)
        var text = result.answer
        if !result.sources.isEmpty {
            text += "\n\n出處：" + result.sources.prefix(4).map(\.label).joined(separator: "、")
        }
        return .result(value: text, dialog: "\(result.answer)")
    }
}

/// 「搜尋錄音內容」：回傳逐字稿裡提到關鍵字的片段原文。
struct SearchTranscriptsIntent: AppIntent {
    static let title: LocalizedStringResource = "搜尋錄音內容"
    static let description = IntentDescription("在最近的錄音與課堂逐字稿裡找關鍵字，回傳相關片段。")

    @Parameter(title: "關鍵字")
    var keyword: String

    @Parameter(title: "查最近幾天", default: 7)
    var days: Int

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        let passages = AskService.passages(for: .recent(max(1, days)), store: RecapStore.shared)
        let found = AskService.rank(passages, question: keyword, keywords: [keyword])
        return .result(value: found.map { "\($0.label)：\($0.text)" })
    }
}

/// 「取得課堂筆記」：回傳某堂課的重點。
struct GetLectureNotesIntent: AppIntent {
    static let title: LocalizedStringResource = "取得課堂筆記"
    static let description = IntentDescription("取得某堂課整理好的重點、術語與作業提醒。")

    @Parameter(title: "課堂")
    var lecture: LectureEntity

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: lecture.fullText)
    }
}
