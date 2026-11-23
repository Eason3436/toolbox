import Foundation
import SwiftData

/// lookup_patterns、add_patterns、list_patterns：規則跟 MCP 一樣（supabase/DEPLOY-4.md）。
/// 句型庫就是 App 裡的句型卡（CardContent 的 pt: 內容），不經過伺服器
@MainActor
enum PatternTools {
    // MARK: key

    private static let baseForms: [String: String] = [
        "am": "is", "are": "is", "was": "is", "were": "is", "been": "is",
        "does": "do", "did": "do", "has": "have", "had": "have",
    ]

    /// 小寫、彎引號換直引號、合併空白；be／do／have 換成原形
    static func normalizeAnchor(_ anchor: String) -> String {
        Normalizer.normalize(anchor)
            .split(separator: " ")
            .map { baseForms[String($0)] ?? String($0) }
            .joined(separator: " ")
    }

    /// 1–6 個、每個 1–60 字、只能有英文字母、空白、' 和 -
    static func validAnchors(_ anchors: [String]) -> String? {
        guard (1...6).contains(anchors.count) else { return "anchors 要 1–6 個" }
        for anchor in anchors {
            guard (1...60).contains(anchor.count) else { return "anchor「\(anchor)」要 1–60 字" }
            guard anchor.allSatisfy({ ($0.isASCII && $0.isLetter) || $0 == " " || $0 == "'" || $0 == "-" }) else {
                return "anchor「\(anchor)」只能有英文字母、空白、' 和 -"
            }
        }
        return nil
    }

    static func key(_ anchors: [String]) -> String {
        anchors.map(normalizeAnchor).joined(separator: "|")
    }

    static func id(_ anchors: [String]) -> String { "pt:" + key(anchors) }

    // MARK: detail 驗證（DEPLOY-4.md 第 3 節）

    static func validate(_ raw: JSONValue?) -> Result<PatternDetail, ToolFailure> {
        guard let raw, case .object(let dict) = raw else { return .failure(ToolFailure("detail 要是物件")) }
        if raw.jsonData.count > 32 * 1024 { return .failure(ToolFailure("detail 超過 32 KB")) }
        guard let pattern = dict["pattern"]?.string?.trimmingCharacters(in: .whitespaces), !pattern.isEmpty, pattern.count <= 120 else {
            return .failure(ToolFailure("pattern 必填、≤ 120 字"))
        }
        guard let zh = dict["zh"]?.string?.trimmingCharacters(in: .whitespaces), !zh.isEmpty, zh.count <= 120 else {
            return .failure(ToolFailure("zh 必填、≤ 120 字"))
        }
        guard let anchors = dict["anchors"]?.array, anchors.allSatisfy({ $0.string != nil }) else {
            return .failure(ToolFailure("anchors 要是字串陣列"))
        }
        if let problem = validAnchors(anchors.compactMap(\.string)) { return .failure(ToolFailure(problem)) }
        guard let slots = dict["slots"]?.array, !slots.isEmpty else { return .failure(ToolFailure("slots 至少要 1 個")) }
        for slot in slots where slot["slot"]?.string?.isEmpty ?? true {
            return .failure(ToolFailure("slots 每一個都要有 slot"))
        }
        guard let examples = dict["examples"]?.array, (2...5).contains(examples.count) else {
            return .failure(ToolFailure("examples 要 2–5 句"))
        }
        for example in examples where example["en"]?.string?.isEmpty ?? true {
            return .failure(ToolFailure("examples 每一句都要有 en"))
        }
        for key in ["level", "register", "explanation", "tips"] {
            if let value = dict[key], value != .null, value.string == nil { return .failure(ToolFailure("\(key) 要是字串")) }
        }
        for key in ["slots", "examples", "variations", "collocations", "similar", "errors"] {
            guard let value = dict[key], value != .null else { continue }
            guard let list = value.array else { return .failure(ToolFailure("\(key) 要是陣列")) }
            if list.count > 10 { return .failure(ToolFailure("\(key) 最多 10 筆")) }
        }
        // 多出來的欄位：解成 PatternDetail 再存，就只留認得的欄位
        guard let detail = raw.decode(PatternDetail.self) else { return .failure(ToolFailure("detail 格式不對")) }
        return .success(detail)
    }

    // MARK: 句型庫（App 裡的句型卡）

    struct LibraryPattern {
        let id: String
        let detail: PatternDetail
        let card: Card?

        var uses: Int { max(card?.allDecks.count ?? 1, 1) }
    }

    static func library(_ context: ModelContext) -> [LibraryPattern] {
        let contents = (try? context.fetch(FetchDescriptor<CardContent>(predicate: #Predicate { $0.id.starts(with: "pt:") }))) ?? []
        let cards = (try? context.fetch(FetchDescriptor<Card>(predicate: #Predicate { $0.id.starts(with: "pt:") }))) ?? []
        let byID = Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return contents.compactMap { content in
            guard let detail = (try? JSONDecoder().decode(CardDetail.self, from: content.data))?.pattern else { return nil }
            return LibraryPattern(id: content.id, detail: detail, card: byID[content.id])
        }
    }

    // MARK: lookup_patterns

    static func lookup(_ args: ToolArgs, _ ctx: ToolContext) -> JSONValue {
        let queries = args.array("patterns")
        guard (1...50).contains(queries.count) else { return .error("patterns 要 1–50 個") }
        let library = Self.library(ctx.modelContext)
        let byID = Dictionary(library.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var found: [JSONValue] = []
        var similar: [JSONValue] = []
        var notFound: [JSONValue] = []
        for query in queries {
            let anchors = query["anchors"]?.strings ?? []
            guard !anchors.isEmpty else { return .error("每個句型都要有 anchors") }
            let id = Self.id(anchors)
            let queryJSON = JSONValue.array(anchors.map(JSONValue.string))
            if let hit = byID[id] {
                found.append(["query": queryJSON, "id": .string(id), "pattern": .string(hit.detail.pattern),
                              "zh": hit.detail.zh.map(JSONValue.string) ?? .null,
                              "detail": JSONValue.encode(hit.detail, snakeCase: false), "uses": .number(Double(hit.uses))])
                continue
            }
            let mine = anchors.map(normalizeAnchor)
            let candidates = library.filter { item in
                let theirs = item.detail.anchors.map(normalizeAnchor)
                return mine.contains { a in theirs.contains { b in a.contains(b) || b.contains(a) } }
            }.prefix(5)
            if candidates.isEmpty {
                notFound.append(queryJSON)
            } else {
                similar.append(["query": queryJSON, "candidates": .array(candidates.map {
                    ["id": .string($0.id), "pattern": .string($0.detail.pattern), "zh": $0.detail.zh.map(JSONValue.string) ?? .null]
                })])
            }
        }
        return ["found": .array(found), "similar": .array(similar), "not_found": .array(notFound)]
    }

    // MARK: add_patterns

    static func add(_ args: ToolArgs, _ ctx: ToolContext) async -> JSONValue {
        guard let deck = args.string("deck"), deck.count <= 60 else { return .error("牌組名稱要 1–60 個字。") }
        let inputs = args.array("patterns")
        guard (1...50).contains(inputs.count) else { return .error("patterns 要 1–50 個") }
        let updateLibrary = args.bool("update_library")
        let library = Self.library(ctx.modelContext)
        let byID = Dictionary(library.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var items: [PatternProposal.Item] = []
        var rejected: [(pattern: String, reason: String)] = []
        var seen: Set<String> = []
        for input in inputs {
            // 1. 只給 id、庫裡有：用庫裡的
            if let id = input["id"]?.string, let hit = byID[id], input["detail"] == nil || input["detail"] == .null {
                if seen.insert(id).inserted { items.append(.init(id: id, detail: hit.detail, fromLibrary: true, replacesLibrary: false)) }
                continue
            }
            // 2. 驗證 detail、算 key
            switch validate(input["detail"]) {
            case .failure(let failure):
                let name = input["detail"]?["pattern"]?.string ?? input["id"]?.string ?? "（沒有 pattern）"
                rejected.append((name, failure.message))
            case .success(let detail):
                let id = Self.id(detail.anchors)
                guard seen.insert(id).inserted else { continue }
                if let hit = byID[id] {
                    items.append(.init(id: id, detail: updateLibrary ? detail : hit.detail, fromLibrary: true, replacesLibrary: updateLibrary))
                } else {
                    items.append(.init(id: id, detail: detail, fromLibrary: false, replacesLibrary: false))
                }
            }
        }
        let rejectedJSON = JSONValue.array(rejected.map { ["pattern": .string($0.pattern), "reason": .string($0.reason)] })
        guard !items.isEmpty else {
            return ["deck": .string(deck), "added": 0, "rejected": rejectedJSON, "message": "沒有可以加入的句型，請看 rejected 修正後再送"]
        }

        let proposal = PatternProposal(deck: deck, items: items, rejected: rejected, updateLibrary: updateLibrary)
        let (decision, card) = await ctx.host.confirm(ToolCard(kind: .patterns(proposal)))
        guard decision == .confirm, case .patterns(let edited) = card.kind else {
            return ["cancelled": true, "message": "使用者取消了，沒有加入任何句型"]
        }
        let chosen = edited.items.filter(\.included)
        guard !chosen.isEmpty else { return ["cancelled": true, "message": "使用者把句型都拿掉了"] }

        let inbox = chosen.map { item -> InboxItem in
            let example = item.detail.examples.first
            return InboxItem(id: UUID().uuidString, deckName: edited.deck, word: item.detail.pattern,
                             pos: item.detail.level, zh: item.detail.zh ?? item.detail.pattern,
                             example: example?.en, exampleZh: example?.zh, source: "library",
                             libraryWordId: item.id, kind: "pattern", detail: item.detail)
        }
        do {
            let imported = try InboxImporter.importItems(inbox, into: ctx.modelContext, now: ctx.now)
            let fromLibrary = chosen.filter(\.fromLibrary).count
            let updated = chosen.filter(\.replacesLibrary).count
            var message = "已加入 \(imported.added) 個句型到〈\(edited.deck)〉"
            if imported.skipped > 0 { message += "，\(imported.skipped) 個已經在這個牌組" }
            var done = edited
            done.state = .added(message)
            ctx.host.updateCard(ToolCard(id: card.id, kind: .patterns(done)))
            return [
                "deck": .string(edited.deck),
                "added": .number(Double(imported.added)),
                "from_library": .number(Double(fromLibrary - updated)),
                "saved_new": .number(Double(chosen.count - fromLibrary)),
                "updated": .number(Double(updated)),
                "skipped": .number(Double(imported.skipped)),
                "rejected": rejectedJSON,
                "message": .string(message),
            ]
        } catch {
            return .error("寫入牌組失敗：\(error.localizedDescription)")
        }
    }

    // MARK: list_patterns

    static func list(_ args: ToolArgs, _ ctx: ToolContext) -> JSONValue {
        let limit = args.int("limit", default: 30, range: 1...100)
        var items = Self.library(ctx.modelContext)
        if let query = args.string("query")?.lowercased() {
            items = items.filter {
                $0.detail.pattern.lowercased().contains(query) || ($0.detail.zh ?? "").contains(query) || $0.id.contains(query)
            }
        }
        items.sort { ($0.card?.addedAt ?? .distantPast) > ($1.card?.addedAt ?? .distantPast) }
        return [
            "total": .number(Double(items.count)),
            "patterns": .array(items.prefix(limit).map { item -> JSONValue in
                [
                    "id": .string(item.id), "pattern": .string(item.detail.pattern),
                    "zh": item.detail.zh.map(JSONValue.string) ?? .null,
                    "level": item.detail.level.map(JSONValue.string) ?? .null,
                    "uses": .number(Double(item.uses)),
                    "updated_at": item.card.map { JSONValue.string($0.addedAt.dayString) } ?? .null,
                ]
            }),
        ]
    }
}
