import Foundation
import SwiftData

/// overview、analyze_learning、list_words：算法跟 MCP 一樣（supabase/DEPLOY-3.md 第 3 節、DEPLOY-5.md），
/// 只是直接讀 App 的資料（用同一份 StudySnapshot），所以永遠是最新的
@MainActor
enum LearningTools {
    /// 計算用的資料：快照＋時區
    struct StudyData {
        let snapshot: StudySnapshot
        let now: Date
        let calendar: Calendar
        let deckNames: [String: String]

        init(snapshot: StudySnapshot, now: Date, calendar: Calendar = .current) {
            self.snapshot = snapshot
            self.now = now
            self.calendar = calendar
            deckNames = Dictionary(snapshot.decks.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        }

        func recall(_ card: StudySnapshot.CardRow) -> Double? {
            Memory.recall(state: FSRSState(name: card.state), stability: card.stability, lastReview: card.lastReview, now: now)
        }

        func startOfDay(_ offset: Int = 0) -> Date {
            calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) ?? now
        }

        /// 牌組名稱或 id → id
        func deckID(_ query: String?) -> String?? {
            guard let query, !query.isEmpty else { return .some(nil) }
            if let deck = snapshot.decks.first(where: { $0.id == query || $0.name == query }) { return .some(deck.id) }
            let lowered = query.lowercased()
            if let deck = snapshot.decks.first(where: { $0.name.lowercased().contains(lowered) }) { return .some(deck.id) }
            return nil
        }
    }

    static func data(_ ctx: ToolContext) throws -> StudyData {
        StudyData(snapshot: try StudySnapshot.make(context: ctx.modelContext, now: ctx.now), now: ctx.now)
    }

    /// 答對率：r ≥ 2 的比例；s = new 的不算
    static func accuracy(_ logs: [StudySnapshot.LogRow]) -> Double? {
        let counted = logs.filter { $0.s != "new" }
        guard !counted.isEmpty else { return nil }
        return Memory.round(Double(counted.filter { $0.r >= 2 }.count) / Double(counted.count))
    }

    private static func number(_ value: Double?) -> JSONValue { value.map(JSONValue.number) ?? .null }
    private static func number(_ value: Int) -> JSONValue { .number(Double(value)) }

    // MARK: overview

    static func overview(_ args: ToolArgs, _ ctx: ToolContext) -> JSONValue {
        guard let data = try? Self.data(ctx) else { return .error("讀不到學習紀錄") }
        let s = data.snapshot
        let todayStart = data.startOfDay()
        let today = s.logs.filter { $0.t >= todayStart }
        let week = s.logs.filter { $0.t >= data.startOfDay(-6) }
        let endToday = data.startOfDay(1), endTomorrow = data.startOfDay(2), endWeek = data.startOfDay(7)
        let learned = s.cards.filter { $0.state != "new" }
        let activeDays = Set(week.map { data.calendar.startOfDay(for: $0.t) }).count

        let dueToday = learned.filter { $0.due < endToday }.count
        let streakDays = streak(s.logs, data: data)
        let todayJSON: JSONValue = [
            "reviews": number(today.count),
            "new_learned": number(today.filter { $0.s == "new" }.count),
            "accuracy": number(accuracy(today)),
            "minutes_est": number(Int((Double(today.count) * 8 / 60).rounded())),
        ]
        let dueJSON: JSONValue = [
            "today": number(dueToday),
            "tomorrow": number(learned.filter { $0.due >= endToday && $0.due < endTomorrow }.count),
            "next_7_days": number(learned.filter { $0.due < endWeek }.count),
        ]
        let weekJSON: JSONValue = [
            "reviews": number(week.count),
            "new_learned": number(week.filter { $0.s == "new" }.count),
            "accuracy": number(accuracy(week)),
            "active_days": number(activeDays),
        ]
        let decksJSON: [JSONValue] = s.decks.map { deck in
            var row: [String: JSONValue] = ["name": .string(deck.name), "mode": .string(deck.mode)]
            row["total"] = number(deck.total)
            row["learned"] = number(deck.total - deck.new)
            row["mastered"] = number(deck.mastered)
            row["new_left"] = number(deck.new)
            return .object(row)
        }
        let totalsJSON: JSONValue = [
            "learned": number(learned.count),
            "mastered": number(learned.filter { $0.state == "review" && $0.stability >= 21 }.count),
        ]
        var result: [String: JSONValue] = [:]
        result["snapshot_at"] = .string(s.generatedAt.ISO8601Format())
        result["app_version"] = .string(s.appVersion)
        result["today"] = todayJSON
        result["due"] = dueJSON
        result["streak_days"] = number(streakDays)
        result["last_7_days"] = weekJSON
        result["decks"] = .array(decksJSON)
        result["totals"] = totalsJSON

        ctx.host.addCard(ToolCard(kind: .learning(LearningCard(
            title: "學習總覽",
            numbers: [
                .init(title: "今天複習", value: today.count.formatted()),
                .init(title: "答對率", value: accuracy(today).map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "—"),
                .init(title: "今天到期", value: dueToday.formatted()),
                .init(title: "連續天數", value: streakDays.formatted()),
            ],
            daily: (0..<7).map { offset in
                let start = data.startOfDay(offset - 6), end = data.startOfDay(offset - 5)
                return s.logs.filter { $0.t >= start && $0.t < end }.count
            },
            words: []
        ))))
        return .object(result)
    }

    /// 到今天（今天還沒複習就從昨天算）連續有複習的天數
    static func streak(_ logs: [StudySnapshot.LogRow], data: StudyData) -> Int {
        let days = Set(logs.map { data.calendar.startOfDay(for: $0.t) })
        var day = data.startOfDay()
        if !days.contains(day) { day = data.startOfDay(-1) }
        var count = 0
        while days.contains(day) {
            count += 1
            day = data.calendar.date(byAdding: .day, value: -1, to: day) ?? day
        }
        return count
    }

    // MARK: analyze_learning

    static func analyze(_ args: ToolArgs, _ ctx: ToolContext) -> JSONValue {
        guard let data = try? Self.data(ctx) else { return .error("讀不到學習紀錄") }
        let days = args.int("days", default: 14, range: 1...90)
        let top = args.int("top", default: 15, range: 1...50)
        guard let deckFilter = data.deckID(args.string("deck")) else {
            return .error("找不到牌組「\(args.string("deck") ?? "")」。現有牌組：\(data.snapshot.decks.map(\.name).joined(separator: "、"))")
        }
        let s = data.snapshot
        let cardsByID = Dictionary(s.cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let start = data.startOfDay(-(days - 1))
        func inDeck(_ id: String) -> Bool {
            guard let deckFilter else { return true }
            return cardsByID[id]?.decks.contains(deckFilter) ?? false
        }
        let logs = s.logs.filter { $0.t >= start && inDeck($0.c) }

        let daily: [JSONValue] = (0..<days).map { offset in
            let from = data.startOfDay(offset - (days - 1)), to = data.startOfDay(offset - (days - 1) + 1)
            let dayLogs = logs.filter { $0.t >= from && $0.t < to }
            return ["date": .string(from.dayString), "reviews": number(dayLogs.count),
                    "new_learned": number(dayLogs.filter { $0.s == "new" }.count), "accuracy": number(accuracy(dayLogs))]
        }
        var ratings: [String: JSONValue] = [:]
        for rating in 1...4 { ratings[String(rating)] = number(logs.filter { $0.r == rating }.count) }

        let cards = s.cards.filter { inDeck($0.id) }
        let forgotten = cards.filter { $0.lapses > 0 }
            .sorted { ($0.lapses, -(data.recall($0) ?? 0)) > ($1.lapses, -(data.recall($1) ?? 0)) }
            .prefix(top)
        let fading = cards.filter { $0.state == "review" && (data.recall($0) ?? 1) < 0.9 }
            .sorted { (data.recall($0) ?? 0) < (data.recall($1) ?? 0) }
            .prefix(top)

        var deckRows: [JSONValue] = []
        var deckAccuracy: [(String, Double)] = []
        for deck in s.decks where deckFilter == nil || deck.id == deckFilter {
            let deckLogs = logs.filter { cardsByID[$0.c]?.decks.contains(deck.id) ?? false }
            guard !deckLogs.isEmpty else { continue }
            let acc = accuracy(deckLogs)
            if let acc { deckAccuracy.append((deck.name, acc)) }
            deckRows.append(["name": .string(deck.name), "reviews": number(deckLogs.count), "accuracy": number(acc),
                             "learned_in_range": number(deckLogs.filter { $0.s == "new" }.count)])
        }

        // 只寫事實，建議讓模型自己說
        var notes: [String] = []
        let missing = (0..<days).filter { offset in
            let from = data.startOfDay(offset - (days - 1)), to = data.startOfDay(offset - (days - 1) + 1)
            return !logs.contains { $0.t >= from && $0.t < to }
        }.count
        if missing > 0 { notes.append("這 \(days) 天有 \(missing) 天沒複習") }
        if deckAccuracy.count >= 2, let worst = deckAccuracy.min(by: { $0.1 < $1.1 }) {
            let others = deckAccuracy.filter { $0.0 != worst.0 }.map(\.1)
            let average = others.reduce(0, +) / Double(others.count)
            let gap = Int(((average - worst.1) * 100).rounded())
            if gap > 0 { notes.append("\(worst.0)的答對率比其他牌組低 \(gap)%") }
        }
        if !logs.isEmpty {
            let again = Double(logs.filter { $0.r == 1 }.count) / Double(logs.count)
            notes.append("評「不會」佔 \(Int((again * 100).rounded()))%")
        }

        func wordJSON(_ card: StudySnapshot.CardRow, extra: [String: JSONValue]) -> JSONValue {
            var dict: [String: JSONValue] = [
                "id": .string(card.id), "word": .string(card.word), "zh": .string(card.zh),
                "recall": number(data.recall(card).map { Memory.round($0) }), "memory": .string(Memory.dots(data.recall(card))),
                "decks": .array(card.decks.map { JSONValue.string(data.deckNames[$0] ?? $0) }),
            ]
            for (key, value) in extra { dict[key] = value }
            return .object(dict)
        }

        ctx.host.addCard(ToolCard(kind: .learning(LearningCard(
            title: "最近 \(days) 天",
            numbers: [
                .init(title: "複習", value: logs.count.formatted()),
                .init(title: "答對率", value: accuracy(logs).map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "—"),
                .init(title: "新學", value: logs.filter { $0.s == "new" }.count.formatted()),
            ],
            daily: (0..<days).map { offset in
                let from = data.startOfDay(offset - (days - 1)), to = data.startOfDay(offset - (days - 1) + 1)
                return logs.filter { $0.t >= from && $0.t < to }.count
            },
            words: forgotten.prefix(5).map { .init(word: $0.word, zh: $0.zh, memory: Memory.dots(data.recall($0))) }
        ))))

        var result: [String: JSONValue] = [:]
        result["snapshot_at"] = .string(s.generatedAt.ISO8601Format())
        result["range"] = ["from": .string(start.dayString), "to": .string(data.startOfDay().dayString), "days": number(days)]
        result["daily"] = .array(daily)
        result["ratings"] = .object(ratings)
        result["accuracy"] = [
            "review": number(accuracy(logs.filter { $0.s == "review" })),
            "learning": number(accuracy(logs.filter { $0.s == "learning" || $0.s == "relearning" })),
        ]
        result["most_forgotten"] = .array(forgotten.map { wordJSON($0, extra: ["lapses": number($0.lapses)]) })
        result["fading"] = .array(fading.map { wordJSON($0, extra: ["due": .string($0.due.dayString)]) })
        result["decks"] = .array(deckRows)
        result["notes"] = .array(notes.map(JSONValue.string))
        return .object(result)
    }

    // MARK: list_words

    static func listWords(_ args: ToolArgs, _ ctx: ToolContext) -> JSONValue {
        guard let data = try? Self.data(ctx) else { return .error("讀不到學習紀錄") }
        guard let deckFilter = data.deckID(args.string("deck")) else {
            return .error("找不到牌組「\(args.string("deck") ?? "")」。現有牌組：\(data.snapshot.decks.map(\.name).joined(separator: "、"))")
        }
        let state = args.string("state") ?? "all"
        let sort = args.string("sort") ?? "weakest"
        let minLapses = args.optionalInt("min_lapses") ?? 0
        let within = args.optionalInt("reviewed_within_days")
        let limit = args.int("limit", default: 50, range: 1...300)

        var cards = data.snapshot.cards.filter { card in
            if let deckFilter, !card.decks.contains(deckFilter) { return false }
            if card.lapses < minLapses { return false }
            switch state {
            case "learning": if card.state != "learning" && card.state != "relearning" { return false }
            case "review": if card.state != "review" { return false }
            case "mastered": if !(card.state == "review" && card.stability >= 21) { return false }
            default: break
            }
            if let within {
                guard let last = card.lastReview, last >= data.startOfDay(-(max(within, 1) - 1)) else { return false }
            }
            return true
        }
        switch sort {
        case "lapses": cards.sort { ($0.lapses, -(data.recall($0) ?? 0)) > ($1.lapses, -(data.recall($1) ?? 0)) }
        case "recent": cards.sort { ($0.lastReview ?? .distantPast) > ($1.lastReview ?? .distantPast) }
        case "due": cards.sort { $0.due < $1.due }
        case "alphabet": cards.sort { $0.word.lowercased() < $1.word.lowercased() }
        default: cards.sort { (data.recall($0) ?? 2) < (data.recall($1) ?? 2) }
        }
        return [
            "snapshot_at": .string(data.snapshot.generatedAt.ISO8601Format()),
            "total_matched": number(cards.count),
            "words": .array(cards.prefix(limit).map { card -> JSONValue in
                let recall = data.recall(card)
                var row: [String: JSONValue] = ["id": .string(card.id), "word": .string(card.word), "zh": .string(card.zh)]
                row["pos"] = card.pos.map(JSONValue.string) ?? .null
                row["deck"] = .string(data.deckNames[card.deck ?? ""] ?? card.deck ?? "")
                row["decks"] = .array(card.decks.map { JSONValue.string(data.deckNames[$0] ?? $0) })
                row["state"] = .string(card.state)
                row["recall"] = number(recall.map { Memory.round($0) })
                row["memory"] = .string(Memory.dots(recall))
                row["lapses"] = number(card.lapses)
                row["reps"] = number(card.reps)
                row["due"] = .string(card.due.dayString)
                row["last_review"] = card.lastReview.map { JSONValue.string($0.dayString) } ?? .null
                row["source"] = .string(card.source)
                return .object(row)
            }),
        ]
    }
}

extension FSRSState {
    init(name: String) {
        switch name {
        case "learning": self = .learning
        case "review": self = .review
        case "relearning": self = .relearning
        default: self = .new
        }
    }
}
