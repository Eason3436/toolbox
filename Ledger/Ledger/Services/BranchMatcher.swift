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
    }
}
