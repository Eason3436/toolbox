import Foundation
import SwiftData

/// lookup_words、add_words、get_words：跟 MCP 的同名工具一樣（supabase/DEPLOY.md 5.5–5.6、DEPLOY-3.md 3.5），
/// 差別是 add_words 直接寫進 App 的牌組（先給使用者看確認卡），不經過收件匣
@MainActor
enum WordTools {
    // MARK: lookup_words

    static func lookup(_ args: ToolArgs, _ ctx: ToolContext) async -> JSONValue {
        let words = args.strings("words")
        guard !words.isEmpty else { return .error("words 至少要有 1 個字") }
        guard words.count <= 200 else { return .error("一次最多查 200 個字，請分批") }
        let index = LibraryIndex.shared
        await index.prepare(context: ctx.modelContext)

        var found: [JSONValue] = []
        var notFound: [JSONValue] = []
        var seen: Set<String> = []
        for word in words where seen.insert(Normalizer.normalize(word)).inserted {
            let entries = index.match(word)
            if entries.isEmpty {
                notFound.append(.string(word))
            } else {
                found.append(["query": .string(word), "entries": .array(entries.map(json))])
            }
        }
        var result: [String: JSONValue] = ["found": .array(found), "not_found": .array(notFound)]
        if !index.missingPacks.isEmpty {
            result["note"] = .string("單字庫沒有讀完整（\(index.missingPacks.joined(separator: "、"))），not_found 的字可能其實在單字庫裡")
        }
        return .object(result)
    }

    static func json(_ entry: LibraryIndex.Entry) -> JSONValue {
        var dict: [String: JSONValue] = [
            "library_word_id": .string(entry.id),
            "word": .string(entry.word),
            "zh": .string(entry.zh),
        ]
        dict["pos"] = entry.pos.map(JSONValue.string) ?? .null
        dict["example"] = entry.example.map(JSONValue.string) ?? .null
        dict["example_zh"] = entry.exampleZh.map(JSONValue.string) ?? .null
        return .object(dict)
    }

    // MARK: add_words

    struct Resolution {
        var items: [WordProposal.Item] = []
        var rejected: [(word: String, reason: String)] = []
    }

    /// DEPLOY.md 5.6 的伺服器端規則：有 library_word_id 或比對得到 → 一律用單字庫的內容；都沒有才用模型寫的（要有中文）
    static func resolve(_ words: [JSONValue], index: LibraryIndex) -> Resolution {
        var result = Resolution()
        var keys: Set<String> = []
        func append(_ item: WordProposal.Item) {
            let key = item.libraryWordID ?? (Normalizer.normalize(item.word) + "|" + Normalizer.normalize(item.pos ?? ""))
            guard keys.insert(key).inserted else { return }
            result.items.append(item)
        }
        func library(_ entry: LibraryIndex.Entry) -> WordProposal.Item {
            WordProposal.Item(word: entry.word, pos: entry.pos, zh: entry.zh, example: entry.example,
                              exampleZh: entry.exampleZh, libraryWordID: entry.id)
        }

        for raw in words {
            let args = ToolArgs(raw)
            let word = (raw["word"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, word.count <= 120 else {
                result.rejected.append((word, "單字格式不正確"))
                continue
            }
            if let id = args.string("library_word_id"), let entry = index.entry(id: id) {
                append(library(entry))
                continue
            }
            let matches = index.match(word)
            if !matches.isEmpty {
                matches.forEach { append(library($0)) }
                continue
            }
            guard let zh = args.string("zh") else {
                result.rejected.append((word, "缺少中文解釋"))
                continue
            }
            append(WordProposal.Item(word: word, pos: args.string("pos"), zh: zh, example: args.string("example"),
                                     exampleZh: args.string("example_zh"), libraryWordID: nil))
        }
        return result
    }

    static func add(_ args: ToolArgs, _ ctx: ToolContext) async -> JSONValue {
        guard let deck = args.string("deck"), deck.count <= 60 else { return .error("牌組名稱要 1–60 個字。") }
        let words = args.array("words")
        guard !words.isEmpty else { return .error("words 至少要有 1 個字") }
        guard words.count <= 200 else { return .error("一次最多加 200 個字，請分批") }
        let index = LibraryIndex.shared
        await index.prepare(context: ctx.modelContext)
        let resolved = resolve(words, index: index)
        let rejectedJSON = JSONValue.array(resolved.rejected.map { ["word": .string($0.word), "reason": .string($0.reason)] })
        guard !resolved.items.isEmpty else {
            return ["deck": .string(deck), "added": 0, "rejected": rejectedJSON,
                    "message": "沒有可以加入的字，請看 rejected 的原因修正後再送"]
        }

        let proposal = WordProposal(deck: deck, items: resolved.items, rejected: resolved.rejected)
        let (decision, card) = await ctx.host.confirm(ToolCard(kind: .words(proposal)))
        guard decision == .confirm, case .words(let edited) = card.kind else {
            return ["cancelled": true, "message": "使用者取消了，沒有加入任何字"]
        }
        let chosen = edited.items.filter(\.included)
        guard !chosen.isEmpty else { return ["cancelled": true, "message": "使用者把字都拿掉了，沒有加入任何字"] }

        let items = chosen.map { item in
            InboxItem(id: UUID().uuidString, deckName: edited.deck, word: item.word, pos: item.pos, zh: item.zh,
                      example: item.example, exampleZh: item.exampleZh,
                      source: item.isLibrary ? "library" : "claude", libraryWordId: item.libraryWordID)
        }
        do {
            let imported = try InboxImporter.importItems(items, into: ctx.modelContext, now: ctx.now)
            let library = chosen.filter(\.isLibrary).count
            var message = "已加入 \(imported.added) 個字到〈\(edited.deck)〉"
            if imported.linked > 0 { message += "，其中 \(imported.linked) 個本來就在背，進度照舊" }
            if imported.skipped > 0 { message += "，\(imported.skipped) 個已經在這個牌組" }
            var done = edited
            done.state = .added(message)
            ctx.host.updateCard(ToolCard(id: card.id, kind: .words(done)))
            return [
                "deck": .string(edited.deck),
                "added": .number(Double(imported.added)),
                "from_library": .number(Double(library)),
                "from_claude": .number(Double(chosen.count - library)),
                "already_in_app": .number(Double(imported.linked)),
                "skipped": .number(Double(imported.skipped)),
                "removed_by_user": .number(Double(edited.items.count - chosen.count)),
                "rejected": rejectedJSON,
                "message": .string(message),
            ]
        } catch {
            return .error("寫入牌組失敗：\(error.localizedDescription)")
        }
    }

    // MARK: get_words

    static func get(_ args: ToolArgs, _ ctx: ToolContext) async -> JSONValue {
        var ids = args.strings("ids")
        let words = args.strings("words")
        guard !ids.isEmpty || !words.isEmpty else { return .error("要給 ids 或 words") }
        guard ids.count + words.count <= 120 else { return .error("一次最多 120 個") }
        let index = LibraryIndex.shared
        await index.prepare(context: ctx.modelContext)
        var notFound: [JSONValue] = []
        for word in words {
            let matches = index.match(word)
            if matches.isEmpty { notFound.append(.string(word)) } else { ids += matches.map(\.id) }
        }

        var seen: Set<String> = []
        var result: [JSONValue] = []
        for id in ids where seen.insert(id).inserted {
            let card = fetchCard(id, ctx.modelContext)
            var item: [String: JSONValue] = ["id": .string(id)]
            var detail = CardDetail.load(for: id, in: ctx.modelContext)
            if detail == nil, card == nil, let entry = index.entry(id: id) {
                detail = await index.detail(for: entry)
                item["word"] = .string(entry.word)
                item["pos"] = entry.pos.map(JSONValue.string) ?? .null
                item["zh"] = .string(entry.zh)
            }
            if let card {
                item["word"] = .string(card.word)
                item["pos"] = card.pos.map(JSONValue.string) ?? .null
                item["zh"] = .string(card.zh)
                item["source"] = .string(card.source.rawValue)
                if detail == nil {
                    item["example"] = card.example.map(JSONValue.string) ?? .null
                    item["example_zh"] = card.exampleZh.map(JSONValue.string) ?? .null
                }
                let recall = Memory.recall(state: card.state, stability: card.stability, lastReview: card.lastReview, now: ctx.now)
                var progress: [String: JSONValue] = ["memory": .string(Memory.dots(recall)), "lapses": .number(Double(card.lapses)),
                                                     "state": .string(card.state.name)]
                if let recall { progress["recall"] = .number(Memory.round(recall)) }
                item["progress"] = .object(progress)
            }
            guard item["word"] != nil else {
                notFound.append(.string(id))
                continue
            }
            if let detail {
                // 跟 App 卡片背面同一份資料（單字包的原樣欄位）
                if let word = detail.word { item["detail"] = JSONValue.encode(word, snakeCase: false) }
                if let phrase = detail.phrase { item["detail"] = JSONValue.encode(phrase, snakeCase: false) }
                if let pattern = detail.pattern { item["detail"] = JSONValue.encode(pattern, snakeCase: false) }
                if let similar = detail.similar, !similar.isEmpty { item["similar"] = JSONValue.encode(similar, snakeCase: false) }
            } else if item["progress"] == nil {
                item["progress"] = ["memory": "新字"]
            }
            result.append(.object(item))
        }
        return ["words": .array(result), "not_found": .array(notFound)]
    }

    static func fetchCard(_ id: String, _ context: ModelContext) -> Card? {
        var descriptor = FetchDescriptor<Card>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
