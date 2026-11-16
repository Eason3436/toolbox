import Foundation
import SwiftData

@Model
final class ReviewLog {
    var cardId: String
    var deckId: String?
    /// 1 不會 / 2 模糊 / 3 認識 / 4 很熟
    var rating: Int
    /// 評分前的狀態；new 代表這是「今日新學」
    var stateBeforeRaw: Int = FSRSState.new.rawValue
    var reviewedAt: Date
    var elapsedDays: Double = 0
    var scheduledDays: Double = 0

    init(
        cardId: String,
        deckId: String?,
        rating: Rating,
        stateBefore: FSRSState,
        reviewedAt: Date = Date(),
        elapsedDays: Double = 0,
        scheduledDays: Double = 0
    ) {
        self.cardId = cardId
        self.deckId = deckId
        self.rating = rating.rawValue
        self.stateBeforeRaw = stateBefore.rawValue
        self.reviewedAt = reviewedAt
        self.elapsedDays = elapsedDays
        self.scheduledDays = scheduledDays
    }

    var wasNew: Bool { stateBeforeRaw == FSRSState.new.rawValue }
}
