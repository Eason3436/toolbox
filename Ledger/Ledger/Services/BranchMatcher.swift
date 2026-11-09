import Foundation
import MapKit
import SwiftData
import FoundationModels

@Generable(description: "從附近店家中選出交易商家的那一家分店")
struct AIBranchPick {
    @Guide(description: "候選清單中最符合交易商家的編號（從 0 開始）；沒有任何一家是同一個商家就填 -1")
    var index: Int
}

/// 捷徑文字裡附上的位置 → 找出是哪一家連鎖店的分店
@MainActor
enum BranchMatcher {
    struct Match {
        var name: String
        var address: String?
        var coordinate: CLLocationCoordinate2D
    }

    /// 文字裡的經緯度，例如「25.0330, 121.5654」
    static func coordinate(in text: String) -> CLLocationCoordinate2D? {
        let pattern = #"(-?\d{1,2}\.\d{3,})\s*[,，]\s*(-?\d{1,3}\.\d{3,})"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r1 = Range(m.range(at: 1), in: text), let r2 = Range(m.range(at: 2), in: text),
              let lat = Double(text[r1]), let lon = Double(text[r2]),
              abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// 文字裡看起來像台灣地址的一段
    static func address(in text: String) -> String? {
        let t = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        let pattern = #"[\p{Han}]{1,4}[市縣][\p{Han}0-9]{0,8}?[區鄉鎮市]?[\p{Han}0-9]{1,10}(?:路|街|大道)[\p{Han}0-9段巷弄之\-]*號?"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
              let r = Range(m.range, in: t) else { return nil }
        return String(t[r])
    }

    /// 商家名稱去掉公司字尾，方便搜尋連鎖店
    static func searchName(_ merchant: String) -> String {
        var s = merchant
        for w in ["國際股份有限公司", "股份有限公司", "有限公司", "企業", "公司", "門市", "營業處"] {
            s = s.replacingOccurrences(of: w, with: "")
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    static func locate(text: String, aiPlace: String) async -> CLLocationCoordinate2D? {
        if let c = coordinate(in: text) { return c }
        // 依序試：「在 …」後面那段（捷徑的「目前位置」）、AI 抓到的位置、文字裡像地址的一段
        var tries: [String] = []
        if let p = leadingPlace(in: text) { tries.append(p) }
        if aiPlace.count >= 4 { tries.append(aiPlace) }
        if let a = address(in: text) { tries.append(a) }
        for q in tries {
            let req = MKLocalSearch.Request()
            req.naturalLanguageQuery = q
            req.resultTypes = [.address, .pointOfInterest]
            req.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 23.7, longitude: 120.96),
                                            latitudinalMeters: 450_000, longitudinalMeters: 450_000)
            if let c = try? await MKLocalSearch(request: req).start().mapItems.first?.location.coordinate { return c }
        }
        return nil
    }

    /// 捷徑文字「在 林森路200號 彰化市 彰化縣 台灣 交易, 商家, 金額, 卡片」裡的位置那段
    static func leadingPlace(in text: String) -> String? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("在") else { return nil }
        t.removeFirst()
        // 位置通常是多行地址，取到第一個半形／全形逗號前；地址本身的逗號（例如「彰化市, 彰化縣」）會被保留到有數字門牌的那幾段
        let lines = t.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var parts: [String] = []
        for line in lines {
            parts.append(line)
            if line.contains("台灣") || line.contains("臺灣") || line.lowercased().contains("taiwan") { break }
            if parts.count >= 3 { break }
        }
        var place = parts.joined(separator: " ")
        if let r = place.range(of: "台灣") ?? place.range(of: "臺灣") { place = String(place[..<r.upperBound]) }
        place = place.trimmingCharacters(in: .whitespaces)
        return place.count >= 4 ? place : nil
    }

    /// 在使用者位置附近找同名商家，多家時請 Apple Intelligence 判斷
    static func match(merchant: String, near center: CLLocationCoordinate2D) async -> Match? {
        let here = CLLocation(latitude: center.latitude, longitude: center.longitude)
        let name = searchName(merchant)
        var candidates: [MKMapItem] = []

        if name.count >= 2 {
            let req = MKLocalSearch.Request()
            req.naturalLanguageQuery = name
            req.resultTypes = .pointOfInterest
            req.region = MKCoordinateRegion(center: center, latitudinalMeters: 1600, longitudinalMeters: 1600)
            candidates = (try? await MKLocalSearch(request: req).start().mapItems) ?? []
        }
        // 再補上附近 150 公尺內所有店家（名稱不一樣的也讓 AI 看）
        let poi = MKLocalPointsOfInterestRequest(center: center, radius: 150)
        if let nearby = try? await MKLocalSearch(request: poi).start().mapItems {
            for item in nearby where !candidates.contains(where: { $0.name == item.name && $0.location.distance(from: item.location) < 20 }) {
                candidates.append(item)
            }
        }
        candidates = candidates
            .filter { $0.location.distance(from: here) <= 800 }
            .sorted { $0.location.distance(from: here) < $1.location.distance(from: here) }
        candidates = Array(candidates.prefix(12))
        guard !candidates.isEmpty else { return nil }

        var chosen: MKMapItem?
        if NoticeParser.aiAvailable, candidates.count > 1 {
            let list = candidates.enumerated().map { i, c in
                "\(i). \(c.name ?? "?")（距離 \(Int(c.location.distance(from: here))) 公尺）"
            }.joined(separator: "\n")
            let session = LanguageModelSession(instructions: """
            你是記帳 App 的助理。使用者在某個位置付款，付款通知上的商家名稱可能是公司全名或簡稱。
            請從附近店家清單中找出同一個商家（同一個連鎖品牌）的那一家分店；同品牌有多家時選距離最近的。
            例如「萊爾富國際」對應「萊爾富 彰化林森店」，「統一超商」對應「7-ELEVEN」，「全家便利商店」對應「全家」。
            清單裡沒有同一個商家就回答 -1。
            """)
            let prompt = "交易商家：\(merchant)\n\n附近店家：\n\(list)"
            if let r = try? await session.respond(to: prompt, generating: AIBranchPick.self).content,
               candidates.indices.contains(r.index) {
                chosen = candidates[r.index]
            }
        }
        // AI 選的店名稱跟商家對不上（例如全家選到隔壁的早餐店），就不算
        if let c = chosen, !isSameBrand(c.name ?? "", merchant: merchant) { chosen = nil }
        if chosen == nil {
            // 沒有 AI：同一個品牌、最近的那家
            chosen = candidates.first { isSameBrand($0.name ?? "", merchant: merchant) }
        }
        guard let c = chosen else { return nil }
        return Match(name: c.name ?? merchant,
                     address: c.address?.shortAddress ?? c.address?.fullAddress,
                     coordinate: c.location.coordinate)
    }

    /// 給捷徑記帳用：有位置就填上分店與座標
    static func apply(to entry: Entry, text: String, aiPlace: String) async {
        guard let here = await locate(text: text, aiPlace: aiPlace) else { return }
        entry.latitude = here.latitude
        entry.longitude = here.longitude
        if let m = await match(merchant: entry.title, near: here) {
            entry.branch = m.name
            entry.branchAddress = m.address
            entry.latitude = m.coordinate.latitude
            entry.longitude = m.coordinate.longitude
        }
        await refineBranchName(entry)
    }

    /// 發票上的店名＋地址／分店名 → 找到那一家店，存到這筆記帳。
    /// 發票上的門市地址最準：就算之前用捷徑位置猜過分店，也以發票地址為準
    static func apply(receipt: Receipt, to entry: Entry) async {
        let merchant: String = entry.title.isEmpty ? receipt.store : entry.title
        let store: String = searchName(receipt.store.isEmpty ? entry.title : receipt.store)
        let place: String = cleanAddress(receipt.address ?? "")
        guard !place.isEmpty else { return }

        // 發票上是門牌地址：先找到地址的位置，再找這個地址上的同品牌店
        if address(in: place) != nil {
            guard let spot = await geocode(place) else { return }
            let here = CLLocation(latitude: spot.latitude, longitude: spot.longitude)
            // 已經是同品牌的分店，而且就在這個地址旁邊：保留，只補地址
            if let lat = entry.latitude, let lon = entry.longitude,
               CLLocation(latitude: lat, longitude: lon).distance(from: here) <= 120,
               let b = entry.branch, !isBrandOnly(b, merchant: merchant), isSameBrand(b, merchant: merchant) {
                entry.branchAddress = place
                return
            }
            entry.latitude = spot.latitude
            entry.longitude = spot.longitude
            entry.branchAddress = place
            entry.branch = brandName(merchant)
            if let m = await nameBranch(merchant: merchant, near: spot) {
                entry.branch = m.name
            } else if let known = knownBranch(merchant: merchant, near: here, excluding: entry) {
                entry.branch = known
            }
            return
        }

        // 只有分店名（例如「信義店」）：搜尋「品牌＋分店名」，只接受同品牌的店
        guard entry.latitude == nil else { return }
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = "\(store) \(place)"
        req.resultTypes = .pointOfInterest
        req.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 23.7, longitude: 120.96),
                                        latitudinalMeters: 450_000, longitudinalMeters: 450_000)
        let items = (try? await MKLocalSearch(request: req).start().mapItems) ?? []
        guard let item = items.first(where: { isSameBrand($0.name ?? "", merchant: merchant) }) else { return }
        entry.latitude = item.location.coordinate.latitude
        entry.longitude = item.location.coordinate.longitude
        entry.branch = item.name
        entry.branchAddress = item.address?.shortAddress
        await refineBranchName(entry)
    }

    /// 地址 → 座標
    static func geocode(_ place: String) async -> CLLocationCoordinate2D? {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = place
        req.resultTypes = .address
        req.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 23.7, longitude: 120.96),
                                        latitudinalMeters: 450_000, longitudinalMeters: 450_000)
        return try? await MKLocalSearch(request: req).start().mapItems.first?.location.coordinate
    }

    /// 發票辨識出來的地址：去掉「地址：」、空白（「6 7 號」→「67號」），全形轉半形
    static func cleanAddress(_ raw: String) -> String {
        var t = raw.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? raw
        for w in ["地址:", "地址", "門市地址:", "營業地址:"] where t.hasPrefix(w) { t = String(t.dropFirst(w.count)) }
        t = t.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\u{3000}", with: "")
        // 門牌後面黏到的其他字（例如「67號營業人統編」）去掉
        if let r = t.range(of: "號") { t = String(t[..<r.upperBound]) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    /// 品牌名（沒有分店），例如「全家」
    static func brandName(_ merchant: String) -> String {
        BrandLogo.brand(for: merchant)?.name ?? searchName(merchant)
    }

    /// 店名是不是這個商家（同一個連鎖品牌）。「巨林美而美 平和店」「益利便利商店」都不是全家
    static func isSameBrand(_ name: String, merchant: String) -> Bool {
        let n = norm(name)
        guard !n.isEmpty else { return false }
        if let brand = BrandLogo.brand(for: merchant) {
            if BrandLogo.brand(for: name)?.id == brand.id { return true }
            return ([brand.name] + brand.keywords).contains { n.contains(norm($0)) }
        }
        let m = norm(searchName(merchant))
        guard m.count >= 2 else { return false }
        return n.contains(m) || m.contains(n)
    }

    /// 自己的紀錄裡，同一個品牌、就在附近（80 公尺內）已經標好的分店名
    static func knownBranch(merchant: String, near here: CLLocation, excluding: Entry? = nil) -> String? {
        let key = BrandLogo.groupKey(for: merchant)
        let all = (try? Store.context.fetch(FetchDescriptor<Entry>())) ?? []
        let hits = all.compactMap { e -> (String, Double)? in
            guard e.id != excluding?.id, BrandLogo.groupKey(for: e.title) == key,
                  let b = e.branch, !isBrandOnly(b, merchant: e.title), isSameBrand(b, merchant: e.title),
                  let lat = e.latitude, let lon = e.longitude else { return nil }
            let d = CLLocation(latitude: lat, longitude: lon).distance(from: here)
            return d <= 80 ? (b, d) : nil
        }
        return hits.min { $0.1 < $1.1 }?.0
    }

    // MARK: 只有品牌名時，找出分店名

    /// 分店欄位是空的、只寫了品牌名（例如「全家」），或是之前用門牌代替的（「全家 中華西路283號」），就還不知道是哪一家
    static func isBrandOnly(_ branch: String?, merchant: String) -> Bool {
        let b = norm(branch ?? "")
        if b.isEmpty { return true }
        var names: [String] = [merchant, searchName(merchant)]
        if let brand = BrandLogo.brand(for: merchant) ?? BrandLogo.brand(for: branch ?? "") {
            names += [brand.name] + brand.keywords
            names += ["\(brand.name)便利商店"]
        }
        if names.map(norm).contains(b) { return true }
        return isAddressName(branch ?? "", merchant: merchant)
    }

    /// 「全家 中華西路283號」這種用門牌當分店名的
    static func isAddressName(_ branch: String, merchant: String) -> Bool {
        let rest = BrandLogo.shortBranch(branch, merchant: merchant)
        guard !rest.contains("店"), !rest.contains("門市") else { return false }
        return rest.range(of: #"^[\p{Han}0-9]*(?:路|街|大道)[\p{Han}0-9段巷弄之\-]*號?$"#, options: .regularExpression) != nil
    }

    private static func norm(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "　", with: "")
    }

    /// 有位置但 Apple 地圖只給品牌名：用附近的店家、地址、行政區多試幾次，找出有分店名的那一家。
    /// 找不到就回傳 nil（不拿地址當店名）
    static func nameBranch(merchant: String, near c: CLLocationCoordinate2D) async -> Match? {
        let here = CLLocation(latitude: c.latitude, longitude: c.longitude)
        let brand = BrandLogo.brand(for: merchant)
        let brandName: String = brand?.name ?? searchName(merchant)
        guard brandName.count >= 2 else { return nil }
        // 搜尋用的名稱：品牌名＋比較完整的中文名（例如「全家便利商店」）
        var queryNames: [String] = [brandName]
        if let longest = brand?.keywords.filter({ $0.range(of: #"\p{Han}"#, options: .regularExpression) != nil })
            .max(by: { $0.count < $1.count }), longest != brandName {
            queryNames.append(longest)
        }

        func pick(_ items: [MKMapItem], within meters: Double) -> MKMapItem? {
            items.filter { item in
                guard let n = item.name, !isBrandOnly(n, merchant: merchant) else { return false }
                return isSameBrand(n, merchant: merchant) && item.location.distance(from: here) <= meters
            }
            .min { $0.location.distance(from: here) < $1.location.distance(from: here) }
        }
        func found(_ hit: MKMapItem) -> Match {
            Match(name: hit.name ?? brandName, address: hit.address?.shortAddress, coordinate: hit.location.coordinate)
        }
        func search(_ q: String, radius: Double) async -> [MKMapItem] {
            let req = MKLocalSearch.Request()
            req.naturalLanguageQuery = q
            req.resultTypes = .pointOfInterest
            req.region = MKCoordinateRegion(center: c, latitudinalMeters: radius, longitudinalMeters: radius)
            return (try? await MKLocalSearch(request: req).start().mapItems) ?? []
        }

        // 1. 這個位置附近的所有店家
        let poi = MKLocalPointsOfInterestRequest(center: c, radius: 120)
        if let hit = pick((try? await MKLocalSearch(request: poi).start().mapItems) ?? [], within: 120) { return found(hit) }
        // 2. 附近搜尋品牌名
        for name in queryNames {
            if let hit = pick(await search(name, radius: 800), within: 150) { return found(hit) }
        }
        // 3. 用這個位置的地址、行政區搜尋「品牌＋地址」
        let geo = await reverseAddress(at: here)
        var places: [String] = []
        if let street = geo.street { places.append(street) }
        if let full = geo.full { places.append(full) }
        if let area = geo.full.flatMap(area(in:)) { places.append(area.replacingOccurrences(of: " ", with: "")) }
        for place in places {
            for name in queryNames {
                if let hit = pick(await search("\(name) \(place)", radius: 3000), within: 200) { return found(hit) }
            }
        }
        return nil
    }

    /// 這個位置的地址：完整地址和門牌（例如「中華西路283號」）
    static func reverseAddress(at loc: CLLocation) async -> (full: String?, street: String?) {
        guard let req = MKReverseGeocodingRequest(location: loc),
              let item = try? await req.mapItems.first else { return (nil, nil) }
        let full = item.address?.fullAddress ?? item.address?.shortAddress
        return (full, await streetAddress(at: loc, item: item))
    }

    /// 這個位置的門牌（例如「中華西路283號」）
    static func streetAddress(at loc: CLLocation, item known: MKMapItem? = nil) async -> String? {
        var found = known
        if found == nil, let req = MKReverseGeocodingRequest(location: loc) {
            found = try? await req.mapItems.first
        }
        guard let item = found else { return nil }
        let full = item.address?.fullAddress ?? item.address?.shortAddress ?? ""
        let t = full.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? full
        if let r = t.range(of: #"[\p{Han}0-9]{1,10}(?:路|街|大道)[\p{Han}0-9段巷弄之\-]*號?"#, options: .regularExpression) {
            var s = String(t[r])
            // 去掉前面的縣市區
            if let d = s.range(of: #"^.*?[縣市區鄉鎮]"#, options: .regularExpression), s[d.upperBound...].count >= 3 {
                s = String(s[d.upperBound...])
            }
            return s
        }
        return item.address?.shortAddress
    }

    /// 縣市＋鄉鎮區，例如「彰化縣 彰化市」「臺中市 西屯區」
    static func area(in address: String) -> String? {
        var t = address.replacingOccurrences(of: "台灣", with: "").replacingOccurrences(of: "臺灣", with: "")
        t = t.replacingOccurrences(of: " ", with: "")
        if let r = t.range(of: #"[\p{Han}]{2}[縣市][\p{Han}]{1,3}?[市區鄉鎮]"#, options: .regularExpression) {
            let s = String(t[r])
            let county = String(s.prefix(3))
            return "\(county) \(s.dropFirst(3))"
        }
        if let r = t.range(of: #"[\p{Han}]{2}[縣市]"#, options: .regularExpression) { return String(t[r]) }
        return nil
    }

    /// 已經有位置、但分店只有品牌名的記帳，補上分店名
    static func refineBranchName(_ entry: Entry) async {
        guard let lat = entry.latitude, let lon = entry.longitude,
              isBrandOnly(entry.branch, merchant: entry.title) else { return }
        guard let m = await nameBranch(merchant: entry.title, near: CLLocationCoordinate2D(latitude: lat, longitude: lon)) else {
            // 查不到分店名：之前用門牌代替的改回品牌名
            if let b = entry.branch, isAddressName(b, merchant: entry.title) {
                entry.branch = BrandLogo.brand(for: entry.title)?.name ?? searchName(entry.title)
            }
            return
        }
        entry.branch = m.name
        if entry.branchAddress == nil { entry.branchAddress = m.address }
    }

    // MARK: 舊資料一次補齊

    private static var refining = false
    private static let triedKey = "branchRefineTried"

    /// 有位置、但分店只有品牌名或地址的舊記帳：同一個地點只查一次，查到就換成真正的店名，
    /// 查不到的地址改回品牌名（顯示成「未標注」）。每次最多查 25 個地點，避免一次打太多請求
    static func refineAll(context: ModelContext) async {
        guard !refining else { return }
        refining = true
        defer { refining = false }
        guard let all = try? context.fetch(FetchDescriptor<Entry>()) else { return }
        var changed = false
        if await fixWrongBrands(all) { changed = true }
        if shareKnownBranches(all) { changed = true }
        var tried: Set<String> = Set(UserDefaults.standard.stringArray(forKey: triedKey) ?? [])
        var groups: [String: [Entry]] = [:]
        for e in all {
            guard let lat = e.latitude, let lon = e.longitude, isBrandOnly(e.branch, merchant: e.title) else { continue }
            let key = BrandLogo.groupKey(for: e.title) + String(format: "|%.4f,%.4f", lat, lon)
            groups[key, default: []].append(e)
        }
        var looked = 0
        for (key, entries) in groups {
            // 地址當店名的一定要處理；只有品牌名的查過一次就不再查
            let hasAddress = entries.contains { isAddressName($0.branch ?? "", merchant: $0.title) }
            guard hasAddress || !tried.contains(key), looked < 25, let first = entries.first,
                  let lat = first.latitude, let lon = first.longitude else { continue }
            looked += 1
            tried.insert(key)
            if let m = await nameBranch(merchant: first.title, near: CLLocationCoordinate2D(latitude: lat, longitude: lon)) {
                for e in entries {
                    e.branch = m.name
                    if e.branchAddress == nil { e.branchAddress = m.address }
                }
                changed = true
            } else {
                for e in entries where isAddressName(e.branch ?? "", merchant: e.title) {
                    e.branch = BrandLogo.brand(for: e.title)?.name ?? searchName(e.title)
                    changed = true
                }
            }
        }
        UserDefaults.standard.set(Array(tried), forKey: triedKey)
        if changed { try? context.save() }
    }

    // MARK: 修正之前配錯的分店

    private static let wrongBrandFixKey = "branchWrongBrandFix1"
    static let manualKey = "branchManualEntries"

    /// 使用者自己在「修改分店」選的，不要自動改
    static func markManual(_ entries: [Entry]) {
        var set = Set(UserDefaults.standard.stringArray(forKey: manualKey) ?? [])
        for e in entries { set.insert(e.id.uuidString) }
        UserDefaults.standard.set(Array(set), forKey: manualKey)
    }

    /// 之前用附近店家猜分店時，可能把隔壁別家店（例如早餐店）當成全家的分店。
    /// 連鎖店的分店名不是同一個品牌的：有發票地址就用發票地址重找，沒有就改回品牌名再找一次
    static func fixWrongBrands(_ all: [Entry]) async -> Bool {
        guard !UserDefaults.standard.bool(forKey: wrongBrandFixKey) else { return false }
        let manual = Set(UserDefaults.standard.stringArray(forKey: manualKey) ?? [])
        var changed = false
        for e in all where !manual.contains(e.id.uuidString) && BrandLogo.brand(for: e.title) != nil {
            guard let b = e.branch, !isBrandOnly(b, merchant: e.title), !isSameBrand(b, merchant: e.title) else { continue }
            e.branch = brandName(e.title)
            e.branchAddress = nil
            changed = true
            if let r = Receipt.from(e.receiptJSON), let a = r.address, address(in: cleanAddress(a)) != nil {
                await apply(receipt: r, to: e)
            }
        }
        // 有發票地址、但分店還沒對上地址的，也用發票地址重找一次
        for e in all where !manual.contains(e.id.uuidString) && BrandLogo.brand(for: e.title) != nil {
            guard let r = Receipt.from(e.receiptJSON), let a = r.address,
                  address(in: cleanAddress(a)) != nil, e.branchAddress != cleanAddress(a) else { continue }
            await apply(receipt: r, to: e)
            changed = true
        }
        UserDefaults.standard.set(true, forKey: wrongBrandFixKey)
        return changed
    }

    /// 同一個品牌、位置在 80 公尺內的紀錄，用已經標好的分店名（不用再查網路）
    static func shareKnownBranches(_ all: [Entry]) -> Bool {
        var changed = false
        for e in all where e.kind == .expense && isBrandOnly(e.branch, merchant: e.title) {
            guard BrandLogo.brand(for: e.title) != nil, let lat = e.latitude, let lon = e.longitude,
                  let known = knownBranch(merchant: e.title, near: CLLocation(latitude: lat, longitude: lon), excluding: e)
            else { continue }
            e.branch = known
            changed = true
        }
        return changed
    }
}
