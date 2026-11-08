import SwiftUI
import SwiftData
import UIKit

/// 有名的連鎖店：用商家名稱認出是哪一家，顯示它的 logo（Assets 裡的 brand-<id>）
enum BrandLogo {
    struct Brand {
        var id: String
        var name: String
        /// 名稱裡出現這些字就算（不分大小寫、忽略空白）
        var keywords: [String]
        /// 整個名稱剛好是這些字才算（太短、容易誤判的，例如 LINE、Max）
        var exact: [String] = []
    }

    /// 順序有差：比較長、比較特定的放前面（Uber Eats 要比 Uber 先比對）
    static let brands: [Brand] = [
        // 訂閱服務與應用商店：比較特定的放前面（YouTube Music 在 YouTube 前、Xbox 在 Microsoft 前）
        Brand(id: "applemusic", name: "Apple Music", keywords: ["apple music", "applemusic"]),
        Brand(id: "appletv", name: "Apple TV", keywords: ["apple tv", "appletv"]),
        Brand(id: "icloud", name: "iCloud", keywords: ["icloud"]),
        Brand(id: "appstore", name: "App Store", keywords: ["app store", "appstore", "apple.com/bill", "itunes", "apple services", "應用商店", "app內購", "app 內購"]),
        Brand(id: "youtubemusic", name: "YouTube Music", keywords: ["youtube music", "youtubemusic"]),
        Brand(id: "youtube", name: "YouTube", keywords: ["youtube"]),
        Brand(id: "googleone", name: "Google One", keywords: ["google one", "googleone", "google storage"]),
        Brand(id: "googleplay", name: "Google Play", keywords: ["google play", "googleplay"]),
        Brand(id: "disneyplus", name: "Disney+", keywords: ["disney+", "disneyplus", "disney plus"]),
        Brand(id: "primevideo", name: "Prime Video", keywords: ["prime video", "primevideo", "amazon prime", "amzn digital"]),
        Brand(id: "max", name: "HBO Max", keywords: ["hbo max", "hbomax", "max.com", "hbo go"], exact: ["max", "hbo"]),
        Brand(id: "catchplay", name: "CATCHPLAY+", keywords: ["catchplay"]),
        Brand(id: "friday", name: "friDay影音", keywords: ["friday影音", "fridayvideo", "friday video", "遠傳friday"]),
        Brand(id: "kkbox", name: "KKBOX", keywords: ["kkbox", "kkcompany"]),
        Brand(id: "linemusic", name: "LINE MUSIC", keywords: ["line music", "linemusic"]),
        Brand(id: "line", name: "LINE", keywords: ["line貼圖", "line store", "line禮物", "ly corporation", "line premium"], exact: ["line"]),
        Brand(id: "chatgpt", name: "ChatGPT", keywords: ["chatgpt", "openai"]),
        Brand(id: "claude", name: "Claude", keywords: ["claude", "anthropic"]),
        Brand(id: "xbox", name: "Xbox", keywords: ["xbox"]),
        Brand(id: "microsoft365", name: "Microsoft 365", keywords: ["microsoft 365", "microsoft365", "microsoft*365", "office 365", "office365"]),
        Brand(id: "adobe", name: "Adobe", keywords: ["adobe", "creative cloud"]),
        Brand(id: "notion", name: "Notion", keywords: ["notion"]),
        Brand(id: "dropbox", name: "Dropbox", keywords: ["dropbox"]),
        Brand(id: "canva", name: "Canva", keywords: ["canva"]),
        Brand(id: "duolingo", name: "Duolingo", keywords: ["duolingo", "多鄰國"]),
        Brand(id: "nintendo", name: "Nintendo", keywords: ["nintendo", "任天堂"]),
        Brand(id: "playstation", name: "PlayStation", keywords: ["playstation", "sony interactive"]),
        Brand(id: "github", name: "GitHub", keywords: ["github"]),
        Brand(id: "crunchyroll", name: "Crunchyroll", keywords: ["crunchyroll"]),
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
        Brand(id: "apple", name: "Apple", keywords: ["apple.com", "apple store", "蘋果"]),
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
            b.exact.contains { n == $0 }
                || b.keywords.contains { n.contains($0.lowercased().replacingOccurrences(of: " ", with: "")) }
        }
    }

    /// 訂閱用的 logo：先看服務本身（Apple Music），沒有就用平台（App Store）
    static func subscriptionLogoName(name: String, platform: String) -> String? {
        if image(for: name) != nil { return name }
        if !platform.isEmpty, image(for: platform) != nil { return platform }
        return nil
    }

    /// 有 logo 圖才回傳
    static func image(for name: String) -> UIImage? {
        guard let b = brand(for: name) else { return nil }
        return UIImage(named: "brand-\(b.id)")
    }

    /// 分店名稱去掉品牌名：「萊爾富 彰化精誠店」→「彰化精誠店」
    static func shortBranch(_ branch: String, merchant: String) -> String {
        var stripped = merchant
        for w in ["國際股份有限公司", "股份有限公司", "有限公司", "企業", "公司"] {
            stripped = stripped.replacingOccurrences(of: w, with: "")
        }
        var candidates: [String] = [merchant, stripped]
        if let b = brand(for: merchant) ?? brand(for: branch) {
            candidates += [b.name] + b.keywords
        }
        candidates = candidates.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        let original = branch.trimmingCharacters(in: .whitespaces)
        var s = original
        for c in candidates where s.lowercased().hasPrefix(c.lowercased()) {
            s = String(s.dropFirst(c.count))
            break
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " 　-－・·_/|"))
        return s.count >= 2 ? s : original
    }

    /// 連鎖店的各種寫法（FamilyMart、全家便利商店、Hi-Life…）統一成同一個店名，例如「全家」「萊爾富」。
    /// 帳單產生的記帳保留帳單名稱。回傳改了幾筆。
    @MainActor
    @discardableResult
    static func normalizeTitles(in context: ModelContext) -> Int {
        guard let all = try? context.fetch(FetchDescriptor<Entry>()) else { return 0 }
        var n = 0
        for e in all where e.bill == nil && e.kind != .transfer {
            guard let b = brand(for: e.title), e.title != b.name else { continue }
            e.title = b.name
            n += 1
        }
        if n > 0 { try? context.save() }
        return n
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

// MARK: - 單色線條 logo（跟分類圖示同風格）

extension BrandLogo {
    /// 每個服務的代表色；灰白的那幾個在淺色模式改深灰
    static let glyphColors: [String: String] = [
        "applemusic": "#FA2D48", "appletv": "", "icloud": "#3E9BF7", "appstore": "#1C8EF9",
        "googleplay": "#34A853", "youtube": "#FF0033", "youtubemusic": "#FF0033", "disneyplus": "#4A8CFF",
        "primevideo": "#1A98FF", "max": "", "catchplay": "#F26F21", "friday": "#13B5EC",
        "kkbox": "#09CEF6", "linemusic": "#10DC6E", "line": "#06C755", "chatgpt": "",
        "claude": "#D97757", "googleone": "#4285F4", "microsoft365": "#5B8DEF", "adobe": "#FF4A3D",
        "notion": "", "dropbox": "#3D8BFF", "canva": "#00C4CC", "duolingo": "#58CC02",
        "nintendo": "#FF4554", "playstation": "#3A8DFF", "xbox": "#48B648", "github": "",
        "crunchyroll": "#FF7A1A", "netflix": "#E50914", "spotify": "#1ED760", "apple": "",
        // 連鎖店
        "50lan": "#2F6FD6", "85c": "#E0294E", "bafang": "#D99A1E", "burgerking": "#F07A22",
        "cama": "#E0A100", "carrefour": "#2E6FD8", "chingshin": "#E2333D", "coco": "#F08A1C",
        "cosmed": "#F57A00", "costco": "#E31837", "cpc": "#2E7BD6", "decathlon": "#4A5BE0",
        "dintaifung": "#D8262E", "dominos": "#1E88C8", "eslite": "#8E8E93", "familymart": "#22A74A",
        "foodpanda": "#E8197A", "hilife": "#E3141F", "ikea": "#1F6FC5", "kebuke": "#B39A72",
        "kfc": "#E4002B", "louisa": "#8E8E93", "mcdonalds": "#F5A800", "milksha": "#0F86B0",
        "misterdonut": "#E05A28", "momo": "#E5139E", "mos": "#D6401E", "muji": "#A4262C",
        "okmart": "#E5202E", "pchome": "#E5221E", "pizzahut": "#E3262F", "poya": "#DD006F",
        "pxmart": "#1F5FBF", "rtmart": "#E3242B", "seven": "#0A9A6A", "shopee": "#EE4D2D",
        "simplemart": "#B53A8B", "starbucks": "#00A862", "sukiya": "#E0141E", "thsr": "#E86A1F",
        "tkk": "#E9312A", "uber": "#8E8E93", "ubereats": "#06C167", "uniqlo": "#E60012",
        "watsons": "#00A0A0",
    ]

    struct Glyph {
        let id: String
        let color: Color
    }

    static func glyph(for name: String) -> Glyph? {
        guard let b = brand(for: name), let hex = glyphColors[b.id],
              UIImage(named: "brandmono-\(b.id)") != nil else { return nil }
        let color: Color = hex.isEmpty ? Theme.dynamic(light: "#3A3A3C", dark: "#D1D1D6") : Color(hex: hex)
        return Glyph(id: b.id, color: color)
    }

    /// 訂閱：先看服務本身，沒有再看平台（App Store、Google Play…）
    static func subscriptionGlyph(name: String, platform: String?) -> Glyph? {
        if let g = glyph(for: name) { return g }
        if let p = platform, !p.isEmpty { return glyph(for: p) }
        return nil
    }
}

struct BrandGlyphIcon: View {
    var glyph: BrandLogo.Glyph
    var size: CGFloat = 44
    var onDark: Bool = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(glyph.color.opacity(onDark ? 0.28 : 0.16))
            Image("brandmono-\(glyph.id)")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size * 0.56, height: size * 0.56)
                .foregroundStyle(glyph.color)
        }
        .frame(width: size, height: size)
    }
}

extension Entry {
    /// 訂閱（帳單產生、或分類是訂閱）
    var isSubscriptionEntry: Bool {
        bill != nil || source == .bill || (category?.fullName.contains("訂閱") ?? false)
    }

    /// 帳單上的平台，或備註裡「平台：…」那一行
    var subscriptionPlatform: String? {
        if let p = bill?.platform, !p.isEmpty { return p }
        for line in note.components(separatedBy: .newlines) where line.hasPrefix("平台：") {
            let p = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
            if !p.isEmpty { return p }
        }
        return nil
    }

    var subscriptionGlyph: BrandLogo.Glyph? {
        guard kind != .transfer, isSubscriptionEntry else { return nil }
        return BrandLogo.subscriptionGlyph(name: title, platform: subscriptionPlatform)
    }

    /// 列表圖示：訂閱用服務／平台，連鎖店用店家的單色 logo
    var listGlyph: BrandLogo.Glyph? {
        guard kind != .transfer else { return nil }
        if let g = subscriptionGlyph { return g }
        return BrandLogo.glyph(for: title)
    }
}
