import SwiftUI

/// 線條圖示（PulsoIcon），點選或出現時會依圖示播放自己的小動畫；
/// 沒有對應的就退回系統 SF Symbol
struct LedgerIcon: View {
    var symbol: String
    var size: CGFloat
    var color: Color? = nil
    var weight: CGFloat = 2
    /// 每次數值改變就播放一次
    var trigger: Int = 0

    @State private var handle = PulsoIconHandle()

    var body: some View {
        if let icon = LedgerIcon.pulso(for: symbol) {
            PulsoIconView(icon, size: size, color: color, strokeWidth: weight, autoAnimated: false, handle: handle)
                .onChange(of: trigger) {
                    Task { await handle.startAnimation() }
                }
        } else {
            Image(systemName: symbol)
                .font(.system(size: size * 0.85, weight: .semibold))
                .foregroundStyle(color ?? .primary)
                .symbolEffect(.bounce, value: trigger)
        }
    }

    static func pulso(for symbol: String) -> PulsoIcon? {
        // 新增的圖示直接存成「pulso:圖示名稱」
        if symbol.hasPrefix("pulso:") { return PulsoIcon.byKey(String(symbol.dropFirst(6))) }
        guard let key = map[symbol] else { return nil }
        return PulsoIcon.byKey(key)
    }

    /// SF Symbol 名稱 → PulsoIcon 名稱
    static let map: [String: String] = [
        "arrow.counterclockwise": "rotate-ccw", "arrow.triangle.2.circlepath": "refresh-cw",
        "arrow.uturn.backward": "undo-2", "arrow.uturn.backward.circle.fill": "undo-2",
        "bag.fill": "shopping-bag", "banknote.fill": "banknote", "basket.fill": "shopping-basket",
        "bell.badge.fill": "bell-ring", "birthday.cake.fill": "cake", "bolt.fill": "zap",
        "book.fill": "book-open", "book.closed.fill": "book", "briefcase.fill": "briefcase",
        "building.columns.fill": "landmark", "building.2.fill": "building", "bus.fill": "bus",
        "car.fill": "car", "car.side.fill": "car", "cart.fill": "shopping-cart",
        "chart.line.uptrend.xyaxis": "trending-up", "chart.pie.fill": "chart-pie",
        "creditcard.fill": "credit-card", "creditcard": "credit-card",
        "cross.case.fill": "briefcase-medical", "cup.and.saucer.fill": "coffee", "mug.fill": "coffee",
        "doc.text.fill": "file-text", "doc.text": "file-text", "dollarsign.circle.fill": "circle-dollar-sign",
        "drop.fill": "droplet", "dumbbell.fill": "dumbbell", "envelope.fill": "mail",
        "figure.2.and.child.holdinghands": "users", "figure.and.child.holdinghands": "baby",
        "figure.run": "footprints", "film.fill": "film", "flame.fill": "flame", "fork.knife": "utensils",
        "fuelpump.fill": "fuel", "gamecontroller.fill": "gamepad-2", "gift.fill": "gift", "gift": "gift",
        "graduationcap.fill": "graduation-cap", "heart.fill": "heart", "house.fill": "house",
        "key.fill": "key", "leaf.fill": "leaf", "moon.fill": "moon", "moon.stars.fill": "moon-star",
        "music.note": "music-note", "parkingsign.circle.fill": "parking", "pawprint.fill": "paw-print",
        "pencil.and.ruler.fill": "pencil-ruler", "person.2.fill": "users", "person.fill": "user",
        "pills.fill": "pill", "play.tv.fill": "tv", "tv.fill": "tv", "shield.lefthalf.filled": "shield",
        "sparkles.tv.fill": "popcorn", "popcorn.fill": "popcorn", "sportscourt.fill": "volleyball",
        "star.fill": "star", "star.circle.fill": "star", "sunrise.fill": "sunrise", "tag.fill": "tag",
        "takeoutbag.and.cup.and.straw.fill": "cup-soda", "tram.fill": "tram-front", "tshirt.fill": "shirt",
        "wand.and.stars": "wand-sparkles", "sparkles": "sparkles", "plus.circle.fill": "circle-plus",
        "square.grid.2x2.fill": "layout-grid", "square.grid.2x2": "layout-grid",
        "questionmark": "circle-question-mark", "airplane": "plane", "iphone": "smartphone", "wifi": "wifi",
        "phone.fill": "phone", "stethoscope": "stethoscope", "scissors": "scissors", "hammer.fill": "hammer",
        "wrench.and.screwdriver.fill": "wrench", "bicycle": "bike", "scooter": "scooter",
        "ferry.fill": "ship", "bed.double.fill": "bed", "paintbrush.fill": "paintbrush",
        "camera.fill": "camera", "headphones": "headphones", "laptopcomputer": "laptop",
        "desktopcomputer": "monitor", "newspaper.fill": "newspaper", "percent": "percent",
        "arrow.down.left": "arrow-down-left", "arrow.up.right": "arrow-up-right",
        "arrow.left.arrow.right": "arrow-left-right", "lightbulb.fill": "lightbulb", "sofa.fill": "sofa",
        "washer.fill": "washing-machine", "wineglass.fill": "wine", "carrot.fill": "carrot",
        "fish.fill": "fish", "cloud.fill": "cloud", "globe": "globe", "ticket.fill": "ticket",
        "calendar": "calendar", "clock.fill": "clock", "storefront.fill": "store", "storefront": "store",
        "bitcoinsign.circle.fill": "bitcoin",
    ]
}

/// 新增／編輯分類時可以選的圖示，依用途分組（全部是 PulsoIcon 線條圖示）
enum IconCatalog {
    struct Group {
        var title: String
        var symbols: [String]
    }

    static let groups: [Group] = raw.map { g in
        Group(title: g.0, symbols: g.1.filter { LedgerIcon.pulso(for: $0) != nil })
    }

    private static let raw: [(String, [String])] = [
        ("飲食", ["fork.knife", "sunrise.fill", "moon.stars.fill", "cup.and.saucer.fill", "takeoutbag.and.cup.and.straw.fill",
                "pulso:milk", "wineglass.fill", "pulso:beer", "pulso:hamburger", "pulso:pizza", "pulso:sandwich", "pulso:soup",
                "pulso:salad", "pulso:egg-fried", "pulso:croissant", "birthday.cake.fill", "pulso:cookie", "pulso:candy",
                "pulso:ice-cream-cone", "pulso:apple", "carrot.fill", "fish.fill", "leaf.fill", "cart.fill", "basket.fill", "storefront"]),
        ("交通", ["car.fill", "pulso:car-front", "bus.fill", "tram.fill", "pulso:train-front", "airplane", "pulso:plane-takeoff",
                "fuelpump.fill", "parkingsign.circle.fill", "pulso:motorbike", "scooter", "bicycle", "ferry.fill", "pulso:truck", "pulso:map-pin"]),
        ("居家", ["house.fill", "key.fill", "bolt.fill", "drop.fill", "flame.fill", "lightbulb.fill", "pulso:plug", "wifi", "phone.fill",
                "iphone", "sofa.fill", "bed.double.fill", "washer.fill", "pulso:bath", "pulso:shower-head", "hammer.fill",
                "wrench.and.screwdriver.fill", "pulso:package"]),
        ("購物與娛樂", ["bag.fill", "tshirt.fill", "pulso:glasses", "sparkles", "scissors", "gift.fill", "pulso:party-popper",
                   "gamecontroller.fill", "film.fill", "pulso:clapperboard", "play.tv.fill", "sparkles.tv.fill", "music.note",
                   "headphones", "camera.fill", "ticket.fill", "laptopcomputer", "desktopcomputer", "book.fill", "pencil.and.ruler.fill",
                   "pulso:pencil", "graduationcap.fill", "newspaper.fill", "globe"]),
        ("健康與生活", ["cross.case.fill", "pills.fill", "stethoscope", "pulso:hospital", "pulso:heart-pulse", "dumbbell.fill",
                   "figure.run", "sportscourt.fill", "pawprint.fill", "pulso:dog", "pulso:cat", "figure.and.child.holdinghands",
                   "person.2.fill", "heart.fill", "pulso:hand-heart", "pulso:umbrella", "pulso:tree-palm", "pulso:tent", "pulso:mountain"]),
        ("金錢", ["banknote.fill", "dollarsign.circle.fill", "pulso:wallet", "pulso:piggy-bank", "pulso:coins", "pulso:hand-coins",
                "creditcard.fill", "pulso:receipt", "pulso:receipt-text", "pulso:calculator", "pulso:badge-dollar-sign",
                "pulso:banknote-arrow-down", "pulso:banknote-arrow-up", "chart.line.uptrend.xyaxis", "pulso:trending-down",
                "pulso:chart-line", "pulso:chart-column", "pulso:vault", "pulso:gem", "building.columns.fill", "percent",
                "shield.lefthalf.filled", "pulso:shield-check", "briefcase.fill", "pulso:briefcase-business", "pulso:handshake",
                "pulso:heart-handshake", "bitcoinsign.circle.fill"]),
        ("其他", ["arrow.triangle.2.circlepath", "arrow.uturn.backward", "plus.circle.fill", "star.fill", "tag.fill",
                "calendar", "clock.fill", "envelope.fill", "cloud.fill", "square.grid.2x2.fill"]),
    ]
}
