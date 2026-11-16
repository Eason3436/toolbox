import Foundation

/// 一張卡的記憶狀態（FSRS 需要的欄位）。複習前先存一份，「復原」時整份放回去
struct CardMemory: Equatable {
    var state: FSRSState
    var stability: Double
    var difficulty: Double
    var due: Date
    var lastReview: Date?
    var reps: Int
    var lapses: Int
}

extension Card {
    var memory: CardMemory {
        get {
            CardMemory(state: state, stability: stability, difficulty: difficulty, due: due, lastReview: lastReview, reps: reps, lapses: lapses)
        }
        set {
            state = newValue.state
            stability = newValue.stability
            difficulty = newValue.difficulty
            due = newValue.due
            lastReview = newValue.lastReview
            reps = newValue.reps
            lapses = newValue.lapses
        }
    }
}

/// FSRS-5（預設參數、目標記憶率 90%）。學習／重新學習用短期步驟：
/// 新卡 不會 1 分、模糊 5 分、認識 10 分；學習中 不會 5 分、模糊 10 分；忘記的複習卡 5 分後再看
struct FSRSScheduler {
    struct Outcome: Equatable {
        var memory: CardMemory
        /// 距離上次複習幾天（寫進 ReviewLog）
        var elapsedDays: Double
        /// 排到幾天後（學習步驟是 0）
        var scheduledDays: Double
    }

    static let defaultWeights: [Double] = [
        0.40255, 1.18385, 3.173, 15.69105, 7.1949, 0.5345, 1.4604, 0.0046, 1.54575, 0.1192,
        1.01925, 1.9395, 0.11, 0.29605, 2.2698, 0.2315, 2.9898, 0.51655, 0.6621,
    ]

    var w: [Double] = FSRSScheduler.defaultWeights
    var requestRetention = 0.9
    var maximumInterval = 36_500.0

    private let decay = -0.5
    private var factor: Double { pow(0.9, 1 / decay) - 1 }

    // MARK: 排程

    func next(_ memory: CardMemory, rating: Rating, now: Date = Date()) -> Outcome {
        let elapsed = memory.lastReview.map { max(0, now.timeIntervalSince($0) / 86_400) } ?? 0
        var result = memory
        result.reps += 1
        result.lastReview = now
        let g = Double(rating.rawValue)

        var state = memory.state
        if state != .new && memory.stability <= 0 { state = .new }

        switch state {
        case .new:
            result.difficulty = initialDifficulty(g)
            result.stability = initialStability(rating)
            switch rating {
            case .again: return learning(result, minutes: 1, elapsed: elapsed, now: now)
            case .hard: return learning(result, minutes: 5, elapsed: elapsed, now: now)
            case .good: return learning(result, minutes: 10, elapsed: elapsed, now: now)
            case .easy:
                let days = interval(result.stability)
                return review(result, days: days, elapsed: elapsed, now: now)
            }

        case .learning, .relearning:
            result.difficulty = nextDifficulty(memory.difficulty, g)
            switch rating {
            case .again:
                result.stability = shortTermStability(memory.stability, g)
                return learning(result, minutes: 5, elapsed: elapsed, now: now)
            case .hard:
                result.stability = shortTermStability(memory.stability, g)
                return learning(result, minutes: 10, elapsed: elapsed, now: now)
            case .good:
                result.stability = shortTermStability(memory.stability, g)
                return review(result, days: interval(result.stability), elapsed: elapsed, now: now)
            case .easy:
                let goodDays = interval(shortTermStability(memory.stability, 3))
                result.stability = shortTermStability(memory.stability, g)
                return review(result, days: max(interval(result.stability), goodDays + 1), elapsed: elapsed, now: now)
            }

        case .review:
            let r = retrievability(elapsedDays: elapsed, stability: memory.stability)
            result.difficulty = nextDifficulty(memory.difficulty, g)
            if rating == .again {
                result.stability = forgetStability(memory.difficulty, memory.stability, r)
                result.lapses += 1
                result.state = .relearning
                result.due = now.addingTimeInterval(5 * 60)
                return Outcome(memory: result, elapsedDays: elapsed, scheduledDays: 0)
            }
            let hardS = recallStability(memory.difficulty, memory.stability, r, 2)
            let goodS = recallStability(memory.difficulty, memory.stability, r, 3)
            let easyS = recallStability(memory.difficulty, memory.stability, r, 4)
            var hardDays = interval(hardS)
            var goodDays = interval(goodS)
            hardDays = min(hardDays, goodDays)
            goodDays = max(goodDays, hardDays + 1)
            let easyDays = max(interval(easyS), goodDays + 1)
            switch rating {
            case .hard:
                result.stability = hardS
                return review(result, days: hardDays, elapsed: elapsed, now: now)
            case .good:
                result.stability = goodS
                return review(result, days: goodDays, elapsed: elapsed, now: now)
            default:
                result.stability = easyS
                return review(result, days: easyDays, elapsed: elapsed, now: now)
            }
        }
    }

    /// 四個按鈕各自的結果（按鈕下方的間隔）
    func preview(_ memory: CardMemory, now: Date = Date()) -> [Rating: Outcome] {
        Dictionary(uniqueKeysWithValues: Rating.allCases.map { ($0, next(memory, rating: $0, now: now)) })
    }

    private func learning(_ memory: CardMemory, minutes: Double, elapsed: Double, now: Date) -> Outcome {
        var m = memory
        m.state = memory.state == .review || memory.state == .relearning ? .relearning : .learning
        m.due = now.addingTimeInterval(minutes * 60)
        return Outcome(memory: m, elapsedDays: elapsed, scheduledDays: 0)
    }

    private func review(_ memory: CardMemory, days: Double, elapsed: Double, now: Date) -> Outcome {
        var m = memory
        m.state = .review
        m.due = now.addingTimeInterval(days * 86_400)
        return Outcome(memory: m, elapsedDays: elapsed, scheduledDays: days)
    }

    // MARK: 公式

    func retrievability(elapsedDays: Double, stability: Double) -> Double {
        guard stability > 0 else { return 0 }
        return pow(1 + factor * elapsedDays / stability, decay)
    }

    func interval(_ stability: Double) -> Double {
        let raw = stability / factor * (pow(requestRetention, 1 / decay) - 1)
        return min(max(raw.rounded(), 1), maximumInterval)
    }

    private func initialStability(_ rating: Rating) -> Double {
        max(w[rating.rawValue - 1], 0.1)
    }

    private func initialDifficulty(_ g: Double) -> Double {
        clampDifficulty(w[4] - exp(w[5] * (g - 1)) + 1)
    }

    private func nextDifficulty(_ d: Double, _ g: Double) -> Double {
        let delta = -w[6] * (g - 3)
        let damped = d + delta * (10 - d) / 9
        let reverted = w[7] * initialDifficulty(4) + (1 - w[7]) * damped
        return clampDifficulty(reverted)
    }

    private func recallStability(_ d: Double, _ s: Double, _ r: Double, _ g: Double) -> Double {
        let hardPenalty = g == 2 ? w[15] : 1
        let easyBonus = g == 4 ? w[16] : 1
        let growth = exp(w[8]) * (11 - d) * pow(s, -w[9]) * (exp((1 - r) * w[10]) - 1)
        return s * (1 + growth * hardPenalty * easyBonus)
    }

    private func forgetStability(_ d: Double, _ s: Double, _ r: Double) -> Double {
        let longTerm = w[11] * pow(d, -w[12]) * (pow(s + 1, w[13]) - 1) * exp((1 - r) * w[14])
        return max(0.1, min(longTerm, s / exp(w[17] * w[18])))
    }

    private func shortTermStability(_ s: Double, _ g: Double) -> Double {
        max(0.1, s * exp(w[17] * (g - 3 + w[18])))
    }

    private func clampDifficulty(_ d: Double) -> Double {
        min(max(d, 1), 10)
    }
}

extension FSRSScheduler.Outcome {
    /// 按鈕下方的「10 分」「3 天」：依語系格式化
    func intervalLabel(from now: Date) -> String {
        let seconds = max(60, memory.due.timeIntervalSince(now))
        let units: Set<Duration.UnitsFormatStyle.Unit> = seconds < 86_400 ? [.hours, .minutes] : [.days]
        return Duration.seconds(Int64(seconds.rounded())).formatted(
            .units(allowed: units, width: .abbreviated, maximumUnitCount: 1)
        )
    }
}
