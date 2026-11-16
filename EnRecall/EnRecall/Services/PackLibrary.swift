import Foundation
import SwiftData

/// 單字庫的一個字／一條片語，轉成卡片要的欄位（規則見 EnRecall/supabase/DEPLOY.md 4.3，MCP 伺服器用同一套）
struct LibraryEntry: Equatable, Sendable {
    let id: String
    let word: String
    let pos: String?
    let zh: String
    let example: String?
    let exampleZh: String?
    let phonetic: String?
}

// MARK: - gzip

/// Storage 回傳的是 .json.gz（Content-Type: application/gzip，不會自動解壓）。
/// 去掉 gzip 標頭與結尾 8 bytes，剩下的 deflate 交給 Compression（.zlib = raw deflate）
enum Gzip {
    enum GzipError: Error {
        case truncated
    }

    static func isGzip(_ data: Data) -> Bool {
        data.count >= 2 && data[data.startIndex] == 0x1f && data[data.startIndex + 1] == 0x8b
    }

    static func decompress(_ data: Data) throws -> Data {
        guard isGzip(data) else { return data }
        let bytes = [UInt8](data)
        guard bytes.count > 18 else { throw GzipError.truncated }
        let flags = bytes[3]
        var index = 10
        if flags & 0x04 != 0 {
            guard index + 2 <= bytes.count else { throw GzipError.truncated }
            index += 2 + (Int(bytes[index]) | Int(bytes[index + 1]) << 8)
        }
        if flags & 0x08 != 0 { index = skipZeroTerminated(bytes, from: index) }
        if flags & 0x10 != 0 { index = skipZeroTerminated(bytes, from: index) }
        if flags & 0x02 != 0 { index += 2 }
        guard index < bytes.count - 8 else { throw GzipError.truncated }
        let deflate = Data(bytes[index..<(bytes.count - 8)])
        return try (deflate as NSData).decompressed(using: .zlib) as Data
    }

    private static func skipZeroTerminated(_ bytes: [UInt8], from start: Int) -> Int {
        var index = start
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        return index + 1
    }
}

// MARK: - 解析

enum PackParser {
    private struct LevelFile: Decodable {
        let words: [Word]
    }

    private struct Word: Decodable {
        let word: String
        let phonetic: String?
        let meanings: [Meaning]?
    }

    private struct Meaning: Decodable {
        let pos: String?
        let zh: String?
        let examples: [Example]?
    }

    private struct Example: Decodable {
        let en: String?
        let zh: String?
    }

    private struct PhraseFile: Decodable {
        let items: [Phrase]
    }

    private struct Phrase: Decodable {
        let p: String
        let zh: String
        let pos: String?
        let ex: String?
        let exZh: String?
    }

    /// files：檔名（level4.json、fixes-level4.json、phrasebook.json）→ 已解壓的 JSON
    static func entries(files: [(name: String, data: Data)]) throws -> [LibraryEntry] {
        // 主檔在前，補充檔接在後面（排序就是「依序」出新卡的順序）
        let ordered = files.sorted { rank($0.name) < rank($1.name) }
        var result: [LibraryEntry] = []
        let decoder = JSONDecoder()
        for file in ordered {
            if file.name == "phrasebook.json" {
                let phrases = try decoder.decode(PhraseFile.self, from: file.data).items
                result += phrases.map(entry(phrase:))
            } else {
                let words = try decoder.decode(LevelFile.self, from: file.data).words
                result += words.compactMap(entry(word:))
            }
        }
        return result
    }

    private static func rank(_ name: String) -> Int {
        name.hasPrefix("fixes-") ? 1 : 0
    }

    private static func entry(word: Word) -> LibraryEntry? {
        let trimmed = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let meanings = (word.meanings ?? []).filter { !($0.zh ?? "").isEmpty }
        var posList: [String] = []
        for meaning in meanings {
            if let pos = clean(meaning.pos), !posList.contains(pos) { posList.append(pos) }
        }
        let zh: String
        if posList.count <= 1 {
            zh = meanings.compactMap { clean($0.zh) }.joined(separator: "；")
        } else {
            zh = meanings.compactMap { meaning -> String? in
                guard let text = clean(meaning.zh) else { return nil }
                guard let pos = clean(meaning.pos) else { return text }
                return "\(pos) \(text)"
            }.joined(separator: "\n")
        }
        guard !zh.isEmpty else { return nil }
        let example = meanings.lazy.compactMap { $0.examples?.first(where: { clean($0.en) != nil }) }.first
        return LibraryEntry(
            id: Normalizer.wordID(trimmed),
            word: trimmed,
            pos: posList.isEmpty ? nil : posList.joined(separator: " / "),
            zh: zh,
            example: clean(example?.en),
            exampleZh: clean(example?.zh),
            phonetic: clean(word.phonetic)
        )
    }

    private static func entry(phrase: Phrase) -> LibraryEntry {
        let text = phrase.p.trimmingCharacters(in: .whitespacesAndNewlines)
        return LibraryEntry(
            id: Normalizer.phraseID(text),
            word: text,
            pos: clean(phrase.pos),
            zh: phrase.zh.trimmingCharacters(in: .whitespacesAndNewlines),
            example: clean(phrase.ex),
            exampleZh: clean(phrase.exZh),
            phonetic: nil
        )
    }

    private static func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}

// MARK: - 下載

enum PackDownloader {
    /// 邊下載邊回報已收到的 bytes
    static func fetch(_ url: URL, onProgress: @escaping @Sendable (Int) async -> Void) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        var data = Data()
        if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
        var reported = 0
        for try await byte in bytes {
            data.append(byte)
            if data.count - reported >= 65_536 {
                reported = data.count
                await onProgress(reported)
            }
        }
        await onProgress(data.count)
        return data
    }
}

// MARK: - 安裝

struct InstallResult: Equatable {
    var isUpdate = false
    var added = 0
    var updated = 0
    var retired = 0
}

/// 把單字包放進牌組。規則：
/// - 卡片 id 固定（w:／p:），本機已經有的卡只更新字義與例句，**FSRS 進度不動**
/// - 已經在別的牌組（例如從 Claude 匯入的）就留在原牌組，只更新內容
/// - 新版拿掉的字標成停用（保留進度，不再出現在複習）
enum PackInstaller {
    @MainActor
    @discardableResult
    static func install(_ pack: StorePack, entries: [LibraryEntry], into context: ModelContext, now: Date = Date()) throws -> InstallResult {
        var result = InstallResult()
        let decks = try context.fetch(FetchDescriptor<Deck>())
        let deck: Deck
        if let existing = decks.first(where: { $0.id == pack.id }) {
            deck = existing
            result.isUpdate = true
        } else {
            deck = Deck(
                id: pack.id,
                name: pack.title,
                kind: .storePack,
                category: pack.category,
                mode: .active,
                order: pack.category == .word ? .random : .sequential,
                dailyNewLimit: 10,
                sortIndex: (decks.map(\.sortIndex).max() ?? -1) + 1,
                level: pack.level,
                createdAt: now
            )
            context.insert(deck)
        }
        deck.name = pack.title
        deck.level = pack.level

        let existingCards = try context.fetch(FetchDescriptor<Card>())
        let cardsByID = Dictionary(existingCards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()

        for (index, entry) in entries.enumerated() {
            guard seen.insert(entry.id).inserted else { continue }
            if let card = cardsByID[entry.id] {
                card.word = entry.word
                card.wordNorm = Normalizer.normalize(entry.word)
                card.pos = entry.pos
                card.zh = entry.zh
                card.example = entry.example
                card.exampleZh = entry.exampleZh
                card.phonetic = entry.phonetic ?? card.phonetic
                card.source = .library
                if card.deck?.id == deck.id {
                    card.sortIndex = index
                    card.isRetired = false
                }
                result.updated += 1
            } else {
                let card = Card(
                    id: entry.id,
                    word: entry.word,
                    pos: entry.pos,
                    zh: entry.zh,
                    example: entry.example,
                    exampleZh: entry.exampleZh,
                    phonetic: entry.phonetic,
                    source: .library,
                    sortIndex: index,
                    addedAt: now
                )
                card.deck = deck
                context.insert(card)
                result.added += 1
            }
        }

        for card in deck.cards where !seen.contains(card.id) && !card.isRetired && card.source == .library {
            card.isRetired = true
            result.retired += 1
        }
        deck.packVersion = pack.version
        try context.save()
        return result
    }
}
