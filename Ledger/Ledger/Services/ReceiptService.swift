import Foundation
import Vision
import UIKit
import FoundationModels

/// 付款方式：從捷徑送來的文字判斷（使用者會在文字裡標註）
enum PayMethod {
    static func detect(in text: String) -> String? {
        let t = text.lowercased().replacingOccurrences(of: " ", with: "")
        if t.contains("linepay") { return "LINE Pay" }
        if t.contains("applepay") { return "Apple Pay" }
        if t.contains("googlepay") { return "Google Pay" }
        if t.contains("街口") { return "街口支付" }
        // 錢包「感應卡片時」的自動化：文字以「在 位置 …」開頭並帶有卡片名稱，就是 Apple Pay 感應
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("在"),
           ["visa", "mastercard", "jcb", "金融卡", "信用卡", "簽帳卡", "debit", "credit"].contains(where: { t.contains($0) }) {
            return "Apple Pay"
        }
        return nil
    }
}

/// 發票內容（只存文字）
struct Receipt: Codable, Equatable {
    struct Item: Codable, Equatable, Identifiable {
        var name: String
        var quantity: Double
        var price: Double
        var id: String { name + "\(price)" }
    }
    var store: String
    var invoiceNumber: String
    var date: String
    var items: [Item]
    var total: Double
    var address: String?
    var importedAt: Date = .now

    var json: String? {
        guard let d = try? JSONEncoder().encode(self) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func from(_ json: String?) -> Receipt? {
        guard let json, let d = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Receipt.self, from: d)
    }
}

@Generable(description: "從發票照片的文字中整理出的內容")
struct AIReceipt {
    @Guide(description: "賣方店名或公司名稱，盡量用一般人熟悉的店名，例如「萊爾富」而不是完整公司名")
    var store: String
    @Guide(description: "發票號碼，例如 GT12710092，沒有就填空字串")
    var invoiceNumber: String
    @Guide(description: "消費日期時間，照抄發票上的格式，沒有就填空字串")
    var date: String
    @Guide(description: "購買的品項，不含小計、合計、找零、載具等行；折扣也列為一項，價格用負數")
    var items: [AIReceiptItem]
    @Guide(description: "發票總金額")
    var total: Double
    @Guide(description: "賣方門市地址或分店名稱（例如「台北信義店」），沒有就填空字串")
    var address: String
    @Guide(description: "依照購買的品項，從分類清單選一個最適合的分類，必須照抄清單中的名稱")
    var category: String
}

@Generable
struct AIReceiptItem {
    @Guide(description: "商品名稱，照抄發票上的品名，例如「重乳黑烏龍奶茶4C」；折扣就填「促銷折扣」等原文。不可以是「小計」「品名」「數量」")
    var name: String
    @Guide(description: "數量，沒寫就是 1")
    var quantity: Double
    @Guide(description: "這一項的小計金額")
    var price: Double
}

enum ReceiptService {
    enum ReceiptError: LocalizedError {
        case noText, aiUnavailable(String), failed(String)
        var errorDescription: String? {
            switch self {
            case .noText: "照片裡讀不到文字，換一張清楚一點的試試。"
            case .aiUnavailable(let s): "Apple Intelligence \(s)"
            case .failed(let s): "辨識失敗：\(s)"
            }
        }
    }

    /// 用 Vision 在 iPhone 上辨識文字（照片用完就丟，不會存）
    static func recognizeText(_ data: Data) async throws -> String {
        guard let image = UIImage(data: data)?.cgImage else { throw ReceiptError.noText }
        return try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hant", "en-US"]
            request.usesLanguageCorrection = true
            try VNImageRequestHandler(cgImage: image).perform([request])
            // 把同一列（高度相近）的文字接成一行，品名、數量、金額才不會被拆開
            let obs = (request.results ?? []).compactMap { o -> (box: CGRect, text: String)? in
                guard let t = o.topCandidates(1).first?.string else { return nil }
                return (o.boundingBox, t)
            }
            .sorted { $0.box.midY > $1.box.midY }
            var rows: [[(box: CGRect, text: String)]] = []
            for o in obs {
                if let last = rows.last?.first,
                   abs(last.box.midY - o.box.midY) < max(last.box.height, o.box.height) * 0.55 {
                    rows[rows.count - 1].append(o)
                } else {
                    rows.append([o])
                }
            }
            let lines = rows.map { row in
                row.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: "   ")
            }
            return lines.joined(separator: "\n")
        }.value
    }

    /// 照片 → 文字 → Apple Intelligence 整理成發票＋建議分類
    @MainActor
    static func analyze(imageData: Data, income: Bool) async throws -> (Receipt, categoryName: String) {
        let text = try await recognizeText(imageData)
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count > 3 else { throw ReceiptError.noText }
        guard NoticeParser.aiAvailable else { throw ReceiptError.aiUnavailable(NoticeParser.aiStatusText) }
        let pool = Store.categories(income: income)
        let names = pool.map(\.name)
        let session = LanguageModelSession(instructions: """
        你是記帳 App 的發票整理助理。使用者會給你一張台灣電子發票或收據照片辨識出來的文字（可能有錯字或順序亂掉），
        請整理出店名、發票號碼、日期、購買品項與總金額，並依照「買了什麼東西」選出最適合的分類。
        例如奶茶、咖啡是飲料或下午茶；便當是午餐或晚餐；洗衣精是日用品。只能使用文字裡出現的資訊，不要編造品項。
        每一行通常是「品名   數量   金額」。品名要用商品的名字（例如「重乳黑烏龍奶茶4C」），
        絕對不要把表頭或統計字樣（品名、數量、單價、小計、合計、總計、應稅、找零、載具）當成品名。
        """)
        let prompt = "分類清單：\(names.joined(separator: "、"))\n\n發票文字：\n\(text.prefix(2500))"
        do {
            let r = try await session.respond(to: prompt, generating: AIReceipt.self).content
            let receipt = Receipt(store: r.store, invoiceNumber: r.invoiceNumber, date: r.date,
                                  items: r.items.map { .init(name: $0.name, quantity: $0.quantity, price: $0.price) },
                                  total: r.total,
                                  address: r.address.trimmingCharacters(in: .whitespaces).isEmpty ? nil : r.address)
            return (receipt, r.category)
        } catch {
            throw ReceiptError.failed(error.localizedDescription)
        }
    }
}
