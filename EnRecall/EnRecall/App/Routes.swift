import SwiftUI

/// 各分頁 NavigationStack 共用的推入目的地
enum Route: Hashable {
    case store
    case pack(StorePack)
    case deck(Deck)
}

/// 開始一輪複習（fullScreenCover 用）
struct ReviewSession: Identifiable {
    let id = UUID()
    /// nil = 全部
    var category: DeckCategory?
    /// 只複習某個牌組
    var deckID: String?
}

extension View {
    func appDestinations() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .store:
                StoreView()
            case .pack(let pack):
                PackDetailView(pack: pack)
            case .deck(let deck):
                DeckDetailView(deck: deck)
            }
        }
    }
}
