import Foundation
import MapKit
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
        if chosen == nil {
            // 沒有 AI：名稱有包含就選最近的那家
            chosen = candidates.first { c in
                guard let n = c.name else { return false }
                return n.localizedCaseInsensitiveContains(name) || name.localizedCaseInsensitiveContains(n)
            }
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

    /// 發票上的店名＋地址／分店名 → 找到那一家店，存到這筆記帳（已經有位置就不動）
    static func apply(receipt: Receipt, to entry: Entry) async {
        guard entry.latitude == nil else { return }
        let store: String = searchName(receipt.store.isEmpty ? entry.title : receipt.store)
        let place: String = receipt.address?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !place.isEmpty else { return }
        var tries: [String] = ["\(store) \(place)"]
        if place.count >= 6 { tries.append(place) }
        for q in tries {
            let req = MKLocalSearch.Request()
            req.naturalLanguageQuery = q
            req.resultTypes = [.pointOfInterest, .address]
            req.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 23.7, longitude: 120.96),
                                            latitudinalMeters: 450_000, longitudinalMeters: 450_000)
            guard let item = try? await MKLocalSearch(request: req).start().mapItems.first else { continue }
            let c = item.location.coordinate
            entry.latitude = c.latitude
            entry.longitude = c.longitude
            // 只有地址的話，再找附近同名的店當分店
            if let m = await match(merchant: store, near: c) {
                entry.branch = m.name
                entry.branchAddress = m.address
                entry.latitude = m.coordinate.latitude
                entry.longitude = m.coordinate.longitude
            } else if let name = item.name, item.pointOfInterestCategory != nil {
                entry.branch = name
                entry.branchAddress = item.address?.shortAddress
            }
            await refineBranchName(entry)
            return
        }
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
                let sameBrand = BrandLogo.groupKey(for: n) == BrandLogo.groupKey(for: merchant)
                    || n.localizedCaseInsensitiveContains(brandName)
                return sameBrand && item.location.distance(from: here) <= meters
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
}
