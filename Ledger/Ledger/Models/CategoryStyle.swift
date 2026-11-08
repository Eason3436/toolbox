import Foundation
import SwiftData

/// 依分類名稱建議比較合適的 SF Symbol 與顏色（同一類用相近色系）
enum CategoryStyle {
    /// 比對順序：越具體的放越前面
    static let table: [(keys: [String], symbol: String, hex: String)] = [
        // 收入（綠色系）
        (["零用錢", "零花錢", "生活費"], "dollarsign.circle.fill", "#2E9E5B"),
        (["薪水", "薪資", "工資", "salary"], "banknote.fill", "#2F7D32"),
        (["獎金", "年終", "bonus"], "star.circle.fill", "#C9A227"),
        (["股利", "股息", "配息", "投資", "股票", "invest"], "chart.line.uptrend.xyaxis", "#1B8A5A"),
        (["利息"], "percent", "#0F9D7A"),
        (["紅包", "禮金"], "envelope.fill", "#D93838"),
        (["兼職", "打工", "接案"], "briefcase.fill", "#0D9488"),
        (["退款", "退費", "退貨", "refund"], "arrow.uturn.backward.circle.fill", "#607D8B"),
        (["其他收入", "收入"], "plus.circle.fill", "#34A853"),
        // 吃（橘黃色系）
        (["早餐", "早午餐"], "sunrise.fill", "#F5A623"),
        (["午餐"], "fork.knife", "#F08C2E"),
        (["晚餐"], "moon.stars.fill", "#E0703A"),
        (["宵夜"], "moon.fill", "#8E6CEF"),
        (["咖啡"], "cup.and.saucer.fill", "#9C6B3F"),
        (["飲料", "手搖", "茶"], "takeoutbag.and.cup.and.straw.fill", "#E8964A"),
        (["零食", "點心", "甜點", "下午茶"], "birthday.cake.fill", "#F2B705"),
        (["水果"], "leaf.fill", "#5DB85C"),
        (["外送", "外帶"], "takeoutbag.and.cup.and.straw.fill", "#EF6C3A"),
        (["超市", "超商", "便利商店", "雜貨", "生鮮", "grocer"], "cart.fill", "#13A88A"),
        (["餐", "吃", "食", "food"], "fork.knife", "#F2A93B"),
        // 交通（綠／藍色系）
        (["加油", "油錢"], "fuelpump.fill", "#E5533C"),
        (["停車"], "parkingsign.circle.fill", "#3B82F6"),
        (["機票", "旅遊", "旅行", "住宿", "飯店", "travel"], "airplane", "#0EA5E9"),
        (["捷運", "公車", "火車", "高鐵", "台鐵", "大眾運輸"], "tram.fill", "#2E9E6A"),
        (["計程車", "uber", "taxi"], "car.side.fill", "#E2B714"),
        (["機車", "摩托車"], "scooter", "#4CAF50"),
        (["交通", "車"], "car.fill", "#34A853"),
        // 住（藍色系）
        (["房租", "租金", "房貸"], "key.fill", "#2563EB"),
        (["電費", "水電"], "bolt.fill", "#F5A000"),
        (["水費"], "drop.fill", "#06A5D4"),
        (["瓦斯"], "flame.fill", "#F97316"),
        (["網路", "電信", "手機", "話費"], "wifi", "#5E4BD8"),
        (["居家", "家具", "家用", "家"], "house.fill", "#3478F6"),
        // 訂閱與娛樂（紅紫色系）
        (["音樂", "spotify", "music"], "music.note", "#FA2D48"),
        (["影音", "netflix", "youtube", "串流", "影片"], "play.tv.fill", "#E50914"),
        (["電影"], "film.fill", "#7C3AED"),
        (["遊戲", "game"], "gamecontroller.fill", "#C2185B"),
        (["訂閱", "subscription"], "arrow.triangle.2.circlepath", "#D9653B"),
        (["娛樂", "休閒"], "sparkles.tv.fill", "#B83280"),
        (["運動", "健身", "gym"], "figure.run", "#22B455"),
        // 購物（藍紫色系）
        (["衣服", "服飾", "鞋", "穿"], "tshirt.fill", "#8B5CF6"),
        (["3c", "電子", "電腦", "數位"], "desktopcomputer", "#475569"),
        (["美妝", "保養", "化妝", "美容"], "sparkles", "#EC4899"),
        (["美髮", "剪髮", "理髮"], "scissors", "#DB2777"),
        (["日用品", "生活用品"], "basket.fill", "#8D6E63"),
        (["購物", "網購", "shopping"], "bag.fill", "#4C7BF4"),
        // 其他
        (["醫療", "醫院", "看診", "藥", "牙"], "cross.case.fill", "#E5484D"),
        (["保險"], "shield.lefthalf.filled", "#0EA5E9"),
        (["學費", "教育", "課程", "補習", "書"], "book.fill", "#6366F1"),
        (["文具"], "pencil.and.ruler.fill", "#A855F7"),
        (["禮物", "送禮", "gift"], "gift.fill", "#F43F5E"),
        (["聚餐", "社交", "約會", "朋友"], "person.2.fill", "#FB7185"),
        (["寵物", "貓", "狗"], "pawprint.fill", "#B45309"),
        (["小孩", "育兒", "孩子"], "figure.and.child.holdinghands", "#F472B6"),
        (["捐款", "公益"], "heart.fill", "#E11D48"),
        (["稅", "罰"], "building.columns.fill", "#64748B"),
        (["手續費", "費用", "利率"], "percent", "#94A3B8"),
        (["還款", "借貸", "貸款", "卡費"], "creditcard.fill", "#5B6B7F"),
        (["其他", "雜項", "未分類"], "square.grid.2x2.fill", "#8E8E93"),
    ]

    static func suggestion(for name: String) -> (symbol: String, hex: String)? {
        let n = name.lowercased()
        for row in table where row.keys.contains(where: { n.contains($0.lowercased()) }) {
            return (row.symbol, row.hex)
        }
        return nil
    }

    /// 套用到所有分類；沒對到關鍵字的子分類沿用主分類的顏色
    @MainActor
    @discardableResult
    static func applyAll(context: ModelContext) -> Int {
        let all = (try? context.fetch(FetchDescriptor<Category>())) ?? []
        var changed = 0
        for c in all.sorted(by: { !$0.isSub && $1.isSub }) {
            if let s = suggestion(for: c.name) {
                c.symbol = s.symbol
                c.colorHex = s.hex
                c.emoji = nil
                changed += 1
            } else if let parent = c.parent {
                c.colorHex = parent.colorHex
                if c.symbol == "tag.fill" { c.symbol = parent.symbol }
                c.emoji = nil
                changed += 1
            } else if c.symbol == "tag.fill" {
                c.symbol = c.isIncome ? "plus.circle.fill" : "square.grid.2x2.fill"
                changed += 1
            }
        }
        try? context.save()
        return changed
    }

    /// 這個版本第一次開啟時自動套用一次（之後使用者自己改的不會被蓋掉）
    @MainActor
    static func migrateIfNeeded() {
        let key = "categoryStyleV2"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        applyAll(context: Store.context)
        UserDefaults.standard.set(true, forKey: key)
    }
}
