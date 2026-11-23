import Foundation
import PDFKit
import SwiftData
import UIKit

/// make_pdf：模型只挑字和用途，排版用 App 自己的講義／自測卷／速查表（Services/Handout，跟首頁「單字 PDF」同一套）
@MainActor
enum PDFTools {
    static func make(_ args: ToolArgs, _ ctx: ToolContext) async -> JSONValue {
        let ids = args.strings("ids")
        guard !ids.isEmpty else { return .error("ids 至少要 1 個（用 list_words 或 analyze_learning 挑字）") }
        guard ids.count <= 300 else { return .error("一次最多 300 個字") }

        var options = HandoutOptions()
        switch args.string("kind") ?? "handout" {
        case "quiz": options.kind = .test
        case "cheatsheet": options.kind = .sheet
        default: options.kind = .notes
        }
        switch args.string("density") ?? "standard" {
        case "compact": options.amount = .brief
        case "full": options.amount = .full
        default: options.amount = .standard
        }
        options.direction = args.string("direction") == "en_to_zh" ? .enToZh : .zhToEn
        options.count = ids.count
        let title = args.string("title") ?? "精選"

        var entries: [HandoutEntry] = []
        var notFound: [JSONValue] = []
        var skipped = 0
        var seen: Set<String> = []
        for id in ids where seen.insert(id).inserted {
            guard let card = WordTools.fetchCard(id, ctx.modelContext) else {
                notFound.append(.string(id))
                continue
            }
            // 自測卷不出句型（沒有單一答案）
            if options.kind == .test, card.deck?.category == .pattern || id.hasPrefix("pt:") {
                skipped += 1
                continue
            }
            let recall = Memory.recall(state: card.state, stability: card.stability, lastReview: card.lastReview, now: ctx.now)
            entries.append(HandoutEntry(card: card, detail: CardDetail.load(for: id, in: ctx.modelContext), recall: recall))
        }
        guard !entries.isEmpty else {
            return .error("這些 id 在 App 裡都找不到卡片（PDF 只能印牌組裡的字）。not_found：\(notFound.compactMap(\.string).joined(separator: ", "))")
        }

        do {
            let data = try await HandoutMaker.render(entries: entries, options: options, rangeTitle: title, now: ctx.now)
            let name = "EnRecall_\(options.kind.title)_\(title)_\(ctx.now.dayString).pdf"
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
            let folder = URL.documentsDirectory.appending(path: "PDF", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appending(path: name)
            try data.write(to: url, options: .atomic)
            let document = PDFDocument(data: data)
            let pages = document?.pageCount ?? 0
            let thumbnail = document?.page(at: 0)?.thumbnail(of: CGSize(width: 240, height: 340), for: .mediaBox).pngData()
            ctx.host.addCard(ToolCard(kind: .pdf(PDFCard(url: url, title: name, pages: pages, thumbnail: thumbnail))))
            var result: [String: JSONValue] = [
                "file": .string(name),
                "pages": .number(Double(pages)),
                "words": .number(Double(entries.count)),
                "not_found": .array(notFound),
                "message": "PDF 做好了，畫面上有預覽和分享按鈕",
            ]
            if skipped > 0 { result["skipped_patterns"] = .number(Double(skipped)) }
            return .object(result)
        } catch {
            return .error("PDF 做不出來：\(error.localizedDescription)")
        }
    }
}
