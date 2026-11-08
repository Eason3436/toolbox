import SwiftUI
import UIKit

/// 有名的連鎖店：用商家名稱認出是哪一家，顯示它的 logo（Assets 裡的 brand-<id>）
enum BrandLogo {
    struct Brand {
        var id: String
        var name: String
        /// 名稱裡出現這些字就算（不分大小寫、忽略空白）
        var keywords: [String]
    }

    /// 順序有差：比較長、比較特定的放前面（Uber Eats 要比 Uber 先比對）
    static let brands: [Brand] = [
        Brand(id: "seven", name: "7-ELEVEN", keywords: ["7-eleven", "7-11", "seven-eleven", "統一超商", "小七"]),
        Brand(id: "familymart", name: "全家", keywords: ["全家便利", "familymart", "family mart", "全家"]),
        Brand(id: "hilife", name: "萊爾富", keywords: ["萊爾富", "hi-life", "hilife"]),
        Brand(id: "okmart", name: "OK超商", keywords: ["ok超商", "okmart", "ok mart", "來來超商", "ok便利"]),
        Brand(id: "mcdonalds", name: "麥當勞", keywords: ["麥當勞", "mcdonald", "和德昌"]),
        Brand(id: "kfc", name: "肯德基", keywords: ["肯德基", "kfc", "富利食品", "富利餐飲"]),
        Brand(id: "mos", name: "摩斯漢堡", keywords: ["摩斯", "mos burger", "安心食品"]),
        Brand(id: "burgerking", name: "漢堡王", keywords: ["漢堡王", "burger king", "burgerking"]),
        Brand(id: "starbucks", name: "星巴克", keywords: ["星巴克", "starbucks", "統一星巴克"]),
        Brand(id: "louisa", name: "路易莎", keywords: ["路易莎", "louisa"]),
        Brand(id: "cama", name: "cama café", keywords: ["cama"]),
        Brand(id: "85c", name: "85度C", keywords: ["85度c", "85°c", "美食達人"]),
        Brand(id: "pxmart", name: "全聯", keywords: ["全聯", "pxmart", "px mart"]),
        Brand(id: "carrefour", name: "家樂福", keywords: ["家樂福", "carrefour", "家福股份", "萬家福"]),
        Brand(id: "costco", name: "Costco", keywords: ["好市多", "costco", "好事多"]),
        Brand(id: "rtmart", name: "大潤發", keywords: ["大潤發", "rt-mart", "rtmart"]),
        Brand(id: "simplemart", name: "美廉社", keywords: ["美廉社", "simple mart", "simplemart", "三商家購"]),
        Brand(id: "watsons", name: "屈臣氏", keywords: ["屈臣氏", "watsons"]),
        Brand(id: "cosmed", name: "康是美", keywords: ["康是美", "cosmed", "統一生活"]),
        Brand(id: "poya", name: "寶雅", keywords: ["寶雅", "poya"]),
        Brand(id: "ikea", name: "IKEA", keywords: ["ikea", "宜家"]),
        Brand(id: "muji", name: "無印良品", keywords: ["無印良品", "muji"]),
        Brand(id: "uniqlo", name: "UNIQLO", keywords: ["uniqlo", "優衣庫"]),
        Brand(id: "50lan", name: "50嵐", keywords: ["50嵐", "五十嵐"]),
        Brand(id: "chingshin", name: "清心福全", keywords: ["清心福全", "清心"]),
        Brand(id: "coco", name: "CoCo都可", keywords: ["coco都可", "都可", "coco fresh"]),
        Brand(id: "milksha", name: "迷客夏", keywords: ["迷客夏", "milksha"]),
        Brand(id: "kebuke", name: "可不可", keywords: ["可不可", "kebuke"]),
        Brand(id: "bafang", name: "八方雲集", keywords: ["八方雲集"]),
        Brand(id: "pizzahut", name: "必勝客", keywords: ["必勝客", "pizza hut", "pizzahut"]),
        Brand(id: "dominos", name: "達美樂", keywords: ["達美樂", "domino"]),
        Brand(id: "napoli", name: "拿坡里", keywords: ["拿坡里", "napoli"]),
        Brand(id: "ubereats", name: "Uber Eats", keywords: ["uber eats", "ubereats"]),
        Brand(id: "uber", name: "Uber", keywords: ["uber", "優步"]),
        Brand(id: "foodpanda", name: "foodpanda", keywords: ["foodpanda", "富胖達", "熊貓外送"]),
        Brand(id: "thsr", name: "台灣高鐵", keywords: ["台灣高鐵", "臺灣高鐵", "高鐵", "thsr"]),
        Brand(id: "cpc", name: "台灣中油", keywords: ["台灣中油", "臺灣中油", "中油"]),
        Brand(id: "shopee", name: "蝦皮", keywords: ["蝦皮", "shopee", "樂購蝦皮"]),
        Brand(id: "momo", name: "momo購物", keywords: ["momo", "富邦媒體"]),
        Brand(id: "pchome", name: "PChome", keywords: ["pchome", "網路家庭", "網家"]),
        Brand(id: "netflix", name: "Netflix", keywords: ["netflix", "網飛"]),
        Brand(id: "spotify", name: "Spotify", keywords: ["spotify"]),
        Brand(id: "apple", name: "Apple", keywords: ["apple.com", "apple store", "app store", "itunes", "icloud", "蘋果"]),
        Brand(id: "eslite", name: "誠品", keywords: ["誠品", "eslite"]),
        Brand(id: "decathlon", name: "迪卡儂", keywords: ["迪卡儂", "decathlon"]),
        Brand(id: "tkk", name: "頂呱呱", keywords: ["頂呱呱", "tkk"]),
        Brand(id: "misterdonut", name: "Mister Donut", keywords: ["mister donut", "misterdonut", "多拿滋", "統一多拿滋"]),
        Brand(id: "sukiya", name: "すき家", keywords: ["すき家", "sukiya", "食其家"]),
        Brand(id: "dintaifung", name: "鼎泰豐", keywords: ["鼎泰豐", "din tai fung"]),
    ]


    /// 這個商家名稱是哪個連鎖店
    static func brand(for name: String) -> Brand? {
        let n = name.lowercased().replacingOccurrences(of: " ", with: "")
        guard !n.isEmpty else { return nil }
        return brands.first { b in
            b.keywords.contains { n.contains($0.lowercased().replacingOccurrences(of: " ", with: "")) }
        }
    }

    /// 有 logo 圖才回傳
    static func image(for name: String) -> UIImage? {
        guard let b = brand(for: name) else { return nil }
        return UIImage(named: "brand-\(b.id)")
    }

    /// 同一家連鎖店（不同寫法、不同分店）算同一個商家
    static func groupKey(for title: String) -> String {
        if let b = brand(for: title) { return "brand:\(b.id)" }
        return title
    }
}

/// 連鎖店 logo；不是連鎖店就顯示 fallback（例如店面圖示）
struct MerchantLogo<Fallback: View>: View {
    var name: String
    var size: CGFloat
    var fallback: Fallback

    init(name: String, size: CGFloat, @ViewBuilder fallback: () -> Fallback) {
        self.name = name
        self.size = size
        self.fallback = fallback()
    }

    var body: some View {
        if let img = BrandLogo.image(for: name) {
            Image(uiImage: img)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(.rect(cornerRadius: size * 0.26, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                .accessibilityLabel(BrandLogo.brand(for: name)?.name ?? name)
        } else {
            fallback
        }
    }
}

extension MerchantLogo where Fallback == EmptyView {
    init(name: String, size: CGFloat) {
        self.init(name: name, size: size) { EmptyView() }
    }
}
