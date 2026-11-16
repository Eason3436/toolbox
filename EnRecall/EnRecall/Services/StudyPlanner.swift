import Foundation

struct StudyCounts: Equatable {
    var due = 0
    var new = 0
    var total: Int { due + new }
}

struct StudySummary: Equatable {
    var all = StudyCounts()
    var byCategory: [DeckCategory: StudyCounts] = [:]
    /// 今天已經學過的新卡數
    var newDoneToday = 0
    /// 今天的新卡上限（全部牌組合計）
    var newLimit = 0

    func counts(for category: DeckCategory) -> StudyCounts {
        byCategory[category] ?? StudyCounts()
    }
}

/// 決定今天要複習哪些卡：到期的複習卡全部出，新卡依「全部上限」與「各牌組每天新卡」兩層限制，
/// 照牌組順序（sortIndex）領。暫停的牌組不出卡，「只出複習」的牌組不出新卡。
enum StudyPlanner {
    struct Plan {
        var due: [Card] = []
        var new: [Card] = []
        /// 每張卡是從哪個牌組領的（同一張卡可以在好幾個牌組，複習紀錄記在領它的牌組）
        var deckOf: [String: String] = [:]
    }

    static func todaysLogs(_ logs: [ReviewLog], now: Date, calendar: Calendar = .current) -> [ReviewLog] {
        let start = calendar.startOfDay(for: now)
        return logs.filter { $0.reviewedAt >= start }
    }

    static func plan(
        decks: [Deck],
        logs: [ReviewLog],
        globalNewLimit: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Plan {
        let today = todaysLogs(logs, now: now, calendar: calendar)
        let newToday = today.filter(\.wasNew)
        var newDoneByDeck: [String: Int] = [:]
        for log in newToday {
            newDoneByDeck[log.deckId ?? "", default: 0] += 1
        }
        var remaining = max(0, globalNewLimit - newToday.count)
        let dayKey = Int(calendar.startOfDay(for: now).timeIntervalSince1970 / 86_400)

        var plan = Plan()
        // 同一張卡在好幾個牌組時只出一次
        var planned: Set<String> = []
        for deck in decks.sorted(by: { $0.sortIndex < $1.sortIndex }) where deck.mode != .paused {
            let cards = deck.orderedActiveCards.filter { !planned.contains($0.id) }
            for card in cards where card.isDue(at: now) {
                plan.due.append(card)
                plan.deckOf[card.id] = deck.id
                planned.insert(card.id)
            }

            guard deck.mode == .active, remaining > 0 else { continue }
            let allowance = min(remaining, max(0, deck.dailyNewLimit - newDoneByDeck[deck.id, default: 0]))
            guard allowance > 0 else { continue }

            var candidates = cards.filter(\.isNew)
            if deck.order == .random {
                // 同一天內順序固定，隔天換一批（依序：orderedActiveCards 已經照這個牌組的順序）
                candidates.sort { stableHash("\(dayKey)|\($0.id)") < stableHash("\(dayKey)|\($1.id)") }
            }
            let picked = candidates.prefix(allowance)
            for card in picked {
                plan.new.append(card)
                plan.deckOf[card.id] = deck.id
                planned.insert(card.id)
            }
            remaining -= picked.count
        }
        plan.due.sort { $0.due < $1.due }
        return plan
    }

    static func summary(
        decks: [Deck],
        logs: [ReviewLog],
        globalNewLimit: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> StudySummary {
        let plan = plan(decks: decks, logs: logs, globalNewLimit: globalNewLimit, now: now, calendar: calendar)
        var summary = StudySummary()
        summary.all = StudyCounts(due: plan.due.count, new: plan.new.count)
        for card in plan.due {
            summary.byCategory[card.deck?.category ?? .word, default: StudyCounts()].due += 1
        }
        for card in plan.new {
            summary.byCategory[card.deck?.category ?? .word, default: StudyCounts()].new += 1
        }
        summary.newDoneToday = todaysLogs(logs, now: now, calendar: calendar).filter(\.wasNew).count
        summary.newLimit = globalNewLimit
        return summary
    }

    /// 依「混合／只背新字／只複習」排出這一輪。混合：新卡平均穿插在複習卡之間
    static func arrange<T>(due: [T], new: [T], mix: ReviewMix) -> [T] {
        switch mix {
        case .reviewOnly:
            return due
        case .newOnly:
            return new
        case .mixed:
            guard !due.isEmpty, !new.isEmpty else { return due + new }
            let total = due.count + new.count
            var result: [T] = []
            result.reserveCapacity(total)
            var d = 0
            var n = 0
            for position in 0..<total {
                let target = Int((Double(n) + 0.5) * Double(total) / Double(new.count))
                if n < new.count && (position >= target || d >= due.count) {
                    result.append(new[n])
                    n += 1
                } else {
                    result.append(due[d])
                    d += 1
                }
            }
            return result
        }
    }

    /// 複習順序：先到期的複習卡，再新卡（新卡穿插在後面，避免一開始全是沒看過的字）
    static func queue(
        decks: [Deck],
        logs: [ReviewLog],
        globalNewLimit: Int,
        category: DeckCategory? = nil,
        now: Date = Date()
    ) -> [Card] {
        let plan = plan(decks: decks, logs: logs, globalNewLimit: globalNewLimit, now: now)
        let due = plan.due.filter { category == nil || $0.deck?.category == category }
        let fresh = plan.new.filter { category == nil || $0.deck?.category == category }
        return due + fresh
    }

    /// FNV-1a，跨啟動結果一樣（String.hashValue 每次啟動都不同）
    static func stableHash(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}
