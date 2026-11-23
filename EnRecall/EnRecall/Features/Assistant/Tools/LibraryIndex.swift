import Foundation
import SwiftData

/// 單字庫的查詢索引（lookup_words、add_words、get_words 用）。比對規則跟 MCP 伺服器一樣（supabase/DEPLOY.md 4.1–4.4）：
/// 單字 key → 片語完整 key → 片語核心 key（核心 key 可能對到好幾條片語）。
///
/// 資料來源：
/// 1. App 裡已經有的單字庫卡（下載過的單字包、從 Claude 匯入的單字庫字）
/// 2. 還沒下載的單字包：經過 enrecall-packs（要下載密碼）抓主檔、補充檔、片語檔，壓縮檔存在 Caches，不放進牌組
@MainActor
final class LibraryIndex {
    struct Entry: Equatable {
        let id: String
        let word: String
        let pos: String?
        let zh: String
        let example: String?
        let exampleZh: String?
        /// 從哪個單字包來（還沒下載的包才有，get_words 要從這裡讀完整內容）
        var pack: String?
    }

    static let shared = LibraryIndex()

    private var remote: [Entry] = []
    private var remotePacks: [String: StorePack] = [:]
    private var remoteLoadedAt: Date?
    /// 抓不到的單字包（沒密碼、沒網路）：結果裡提醒模型可能查不到
    private(set) var missingPacks: [String] = []

    private var byID: [String: Entry] = [:]
    private var byWord: [String: String] = [:]
    private var byPhrase: [String: String] = [:]
    private var byPhraseCore: [String: [String]] = [:]

    // MARK: 建立

    /// 每次用之前呼叫：App 裡的卡每次重讀（剛下載的包、剛加的字要查得到），還沒下載的包 30 分鐘內不重抓
    func prepare(context: ModelContext) async {
        var local: [Entry] = []
        let cards = (try? context.fetch(FetchDescriptor<Card>(predicate: #Predicate { $0.sourceRaw == "library" }))) ?? []
        for card in cards where card.id.hasPrefix("w:") || card.id.hasPrefix("p:") {
            local.append(Entry(id: card.id, word: card.word, pos: card.pos, zh: card.zh,
                               example: card.example, exampleZh: card.exampleZh, pack: nil))
        }
        let installed = Set(((try? context.fetch(FetchDescriptor<Deck>())) ?? []).filter { $0.kind == .storePack }.map(\.id))
        await loadRemote(skipping: installed)
        rebuild(local: local, remote: remote.filter { !installed.contains($0.pack ?? "") })
    }

    /// 測試用：直接給資料
    func load(entries: [Entry]) {
        remote = []
        missingPacks = []
        rebuild(local: entries, remote: [])
    }

    private func rebuild(local: [Entry], remote: [Entry]) {
        byID = [:]
        byWord = [:]
        byPhrase = [:]
        byPhraseCore = [:]
        // App 裡的卡優先（內容可能比較新）
        for entry in local + remote where byID[entry.id] == nil {
            byID[entry.id] = entry
            if entry.id.hasPrefix("w:") {
                byWord[Normalizer.normalize(entry.word)] = entry.id
            } else {
                byPhrase[Normalizer.normalize(entry.word)] = entry.id
                let core = PhraseKey.core(entry.word)
                if !core.isEmpty, !(byPhraseCore[core]?.contains(entry.id) ?? false) {
                    byPhraseCore[core, default: []].append(entry.id)
                }
            }
        }
    }

    private func loadRemote(skipping installed: Set<String>) async {
        if let remoteLoadedAt, Date().timeIntervalSince(remoteLoadedAt) < 1800 { return }
        guard let request = StoreAccess.request(path: "store/catalog.json"),
              let fetched = try? await URLSession.shared.data(for: request),
              (fetched.1 as? HTTPURLResponse)?.statusCode == 200,
              let catalog = try? JSONDecoder().decode(StoreCatalog.self, from: fetched.0) else {
            // 抓不到清單：只用 App 裡的卡，提醒還沒下載的等級可能查不到
            missingPacks = installed.count >= 7 ? [] : ["還沒下載的單字包"]
            return
        }
        let packs = catalog.packs.filter(\.isSupported)
        var entries: [Entry] = []
        var missing: [String] = []
        for pack in packs where !installed.contains(pack.id) {
            remotePacks[pack.id] = pack
            do {
                let files = try await Self.files(of: pack)
                let parsed = try await Task.detached(priority: .userInitiated) {
                    try PackParser.entries(files: files)
                }.value
                entries += parsed.map {
                    Entry(id: $0.id, word: $0.word, pos: $0.pos, zh: $0.zh, example: $0.example, exampleZh: $0.exampleZh, pack: pack.id)
                }
            } catch {
                missing.append(pack.title)
            }
        }
        remote = entries
        missingPacks = missing
        remoteLoadedAt = missing.isEmpty ? Date() : nil
    }

    /// 單字包的主檔、補充檔、片語檔（不含 similar／quiz，查詢用不到），已解壓。壓縮檔快取在 Caches
    private static func files(of pack: StorePack, includeExtras: Bool = false) async throws -> [(name: String, data: Data)] {
        let needed = pack.neededFiles.filter { file in
            includeExtras || !(file.name.hasPrefix("similar-") || file.name.hasPrefix("quiz-"))
        }
        let folder = URL.cachesDirectory.appending(path: "library-index", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var result: [(name: String, data: Data)] = []
        for file in needed {
            let cached = folder.appending(path: file.path.replacingOccurrences(of: "/", with: "_"))
            let compressed: Data
            if let data = try? Data(contentsOf: cached) {
                compressed = data
            } else {
                guard let request = StoreAccess.request(path: file.path) else { throw StoreDeniedError() }
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                try? data.write(to: cached, options: .atomic)
                compressed = data
            }
            result.append((file.name, try Gzip.decompress(compressed)))
        }
        return result
    }

    // MARK: 查詢

    func entry(id: String) -> Entry? { byID[id] }

    /// 4.4 的比對順序。單字通常 1 筆，片語核心 key 可能好幾筆
    func match(_ query: String) -> [Entry] {
        let key = Normalizer.normalize(query)
        guard !key.isEmpty else { return [] }
        if let id = byWord[key], let entry = byID[id] { return [entry] }
        if let id = byPhrase[key], let entry = byID[id] { return [entry] }
        for core in [key, PhraseKey.core(query)] where !core.isEmpty {
            if let ids = byPhraseCore[core], !ids.isEmpty { return ids.compactMap { byID[$0] } }
        }
        return []
    }

    /// 還沒下載的包裡的字：讀那一包的完整內容（get_words 用）
    func detail(for entry: Entry) async -> CardDetail? {
        guard let packID = entry.pack, let pack = remotePacks[packID],
              let files = try? await Self.files(of: pack, includeExtras: true) else { return nil }
        let id = entry.id
        return await Task.detached(priority: .userInitiated) {
            guard let match = (try? PackParser.entries(files: files))?.first(where: { $0.id == id }),
                  let data = match.detail else { return nil }
            return try? JSONDecoder().decode(CardDetail.self, from: data)
        }.value
    }
}

/// 片語的核心 key（supabase/DEPLOY.md 4.4）：拿掉括號、sb/sth 這些佔位詞、刪節號
enum PhraseKey {
    private static let parens = try! NSRegularExpression(pattern: "\\([^)]*\\)|（[^）]*）")
    private static let placeholders = try! NSRegularExpression(pattern: "\\b(sb/sth|sb|sth|one's|oneself|v-ing|v)\\b")
    private static let ellipsis = try! NSRegularExpression(pattern: "…|\\.\\.\\.")

    static func core(_ phrase: String) -> String {
        var text = Normalizer.normalize(phrase)
        for regex in [parens, placeholders, ellipsis] {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        }
        return text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
