import Foundation
import SwiftData

/// 單字庫的完整內容（CardDetail 的 JSON），跟 Card 分開存：
/// 首頁、牌組那些統計會把所有卡讀進來，內容放在 Card 裡會讓每次評分都卡一下
@Model
final class CardContent {
    /// 跟 Card.id 一樣（w:／p:）
    @Attribute(.unique) var id: String
    var data: Data

    init(id: String, data: Data) {
        self.id = id
        self.data = data
    }
}

extension CardDetail {
    /// 找不到（例如從 Claude 寫的字）就是 nil
    static func load(for cardID: String, in context: ModelContext) -> CardDetail? {
        var descriptor = FetchDescriptor<CardContent>(predicate: #Predicate { $0.id == cardID })
        descriptor.fetchLimit = 1
        guard let data = try? context.fetch(descriptor).first?.data else { return nil }
        return try? JSONDecoder().decode(CardDetail.self, from: data)
    }
}
