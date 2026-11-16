import Foundation
import Observation
import SwiftData

/// store/catalog.json
struct StoreCatalog: Decodable {
    let v: Int
    let packs: [StorePack]
}

struct StorePack: Decodable, Identifiable, Hashable {
    struct PreviewWord: Decodable, Hashable {
        let w: String
        let zh: String
        let pos: String?
    }

    struct PackFile: Decodable, Hashable {
        let name: String
        let path: String
        let size: Int?
        let rawSize: Int?
    }

    let id: String
    let kind: String
    let level: Int?
    let title: String
    let subtitle: String?
    let desc: String?
    let author: String?
    let official: Bool?
    let version: Int
    let words: Int?
    let updated: String?
    let preview: [PreviewWord]?
    let files: [PackFile]

    /// iOS 版只用學測 Level 1–6 和片語總表
    var isSupported: Bool { id.hasPrefix("gsat-") || id == "phrasebook" }

    var category: DeckCategory { kind == "phrase" ? .phrase : .word }

    var tileLabel: String { level.map { "L\($0)" } ?? "Ph" }

    /// 實際要下載的檔案（單字檔、補充檔、片語檔）
    var neededFiles: [PackFile] {
        files.filter { file in
            file.name.hasPrefix("level") || file.name.hasPrefix("fixes-") || file.name.hasPrefix("similar-")
                || file.name.hasPrefix("quiz-")
                || file.name == "phrasebook.json"
        }
    }

    var downloadBytes: Int { neededFiles.compactMap(\.size).reduce(0, +) }
    var installedBytes: Int { neededFiles.compactMap(\.rawSize).reduce(0, +) }
    var downloadSizeText: String { Int64(downloadBytes).formatted(.byteCount(style: .file)) }
    var installedSizeText: String { Int64(installedBytes).formatted(.byteCount(style: .file)) }

    var countLabel: String {
        let n = (words ?? 0).formatted()
        return category == .phrase ? "\(n) 條" : "\(n) 字"
    }
}

enum PackStatus: Equatable {
    case notDownloaded
    case downloading(Double)
    case downloaded
    case updateAvailable
}

/// 單字商店：讀公開的 catalog.json，下載單字包放進牌組
@MainActor
@Observable
final class StoreModel {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed
    }

    private(set) var packs: [StorePack]
    private(set) var phase: Phase
    /// 下載中的包：id → 0...1
    var progress: [String: Double] = [:]

    init(packs: [StorePack] = []) {
        self.packs = packs
        self.phase = packs.isEmpty ? .idle : .loaded
    }

    var wordPacks: [StorePack] { packs.filter { $0.category == .word }.sorted { ($0.level ?? 0) < ($1.level ?? 0) } }
    var phrasePacks: [StorePack] { packs.filter { $0.category == .phrase } }

    func load(force: Bool = false) async {
        guard phase != .loading else { return }
        if phase == .loaded && !force { return }
        phase = .loading
        do {
            let url = AppConfig.storeBaseURL.appending(path: "store/catalog.json")
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let catalog = try JSONDecoder().decode(StoreCatalog.self, from: data)
            packs = catalog.packs.filter(\.isSupported)
            phase = .loaded
        } catch {
            // 斷網不擋 App：有舊資料就繼續用
            phase = packs.isEmpty ? .failed : .loaded
        }
    }

    func status(of pack: StorePack, decks: [Deck]) -> PackStatus {
        if let p = progress[pack.id] { return .downloading(p) }
        guard let deck = decks.first(where: { $0.id == pack.id }) else { return .notDownloaded }
        if let installed = deck.packVersion, installed < pack.version { return .updateAvailable }
        if deck.contentFormat < PackInstaller.contentFormat { return .updateAvailable }
        return .downloaded
    }

    func updatesAvailable(decks: [Deck]) -> [StorePack] {
        packs.filter { status(of: $0, decks: decks) == .updateAvailable }
    }

    // MARK: 下載

    /// 下載 → 解壓 → 解析 → 寫進牌組。進度：下載佔 90%，安裝佔最後 10%
    @discardableResult
    func install(_ pack: StorePack, context: ModelContext) async throws -> InstallResult {
        guard progress[pack.id] == nil else { throw CancellationError() }
        progress[pack.id] = 0
        defer { progress[pack.id] = nil }

        let total = Double(max(pack.downloadBytes, 1))
        var received = 0
        var files: [(name: String, data: Data)] = []
        for file in pack.neededFiles {
            let url = AppConfig.storeBaseURL.appending(path: file.path)
            let base = received
            let packID = pack.id
            let compressed = try await Task.detached(priority: .userInitiated) {
                try await PackDownloader.fetch(url) { bytes in
                    await MainActor.run {
                        guard self.progress[packID] != nil else { return }
                        self.progress[packID] = min(0.9, 0.9 * Double(base + bytes) / total)
                    }
                }
            }.value
            received += compressed.count
            files.append((name: file.name, data: compressed))
        }

        let parsed = files
        let entries = try await Task.detached(priority: .userInitiated) {
            let decompressed = try parsed.map { (name: $0.name, data: try Gzip.decompress($0.data)) }
            return try PackParser.entries(files: decompressed)
        }.value
        guard !entries.isEmpty else { throw URLError(.cannotParseResponse) }
        progress[pack.id] = 0.95
        return try PackInstaller.install(pack, entries: entries, into: context)
    }

    /// 舊格式安裝的單字包（例如還沒有搭配、近義字那些內容）：背景重新安裝，進度不動。
    /// 回傳補好的包數；失敗的下次打開 App 再試
    func upgradeOutdated(context: ModelContext) async -> Int {
        guard phase == .loaded, let decks = try? context.fetch(FetchDescriptor<Deck>()) else { return 0 }
        let outdated = packs.filter { pack in
            progress[pack.id] == nil
                && decks.contains { $0.id == pack.id && $0.contentFormat < PackInstaller.contentFormat }
        }
        var upgraded = 0
        for pack in outdated {
            if (try? await install(pack, context: context)) != nil { upgraded += 1 }
        }
        return upgraded
    }

    /// 一次下載好幾包，回傳給 toast 用的訊息
    func installAll(_ packs: [StorePack], context: ModelContext) async -> String? {
        var done: [(StorePack, InstallResult)] = []
        var failed = 0
        for pack in packs where progress[pack.id] == nil {
            do {
                done.append((pack, try await install(pack, context: context)))
            } catch {
                failed += 1
            }
        }
        if failed > 0 {
            return done.isEmpty ? "下載失敗，請稍後再試" : "下載了 \(done.count) 包，\(failed) 包失敗"
        }
        guard let first = done.first else { return nil }
        if done.count == 1 {
            return first.1.isUpdate ? "已更新\(first.0.title)" : "已下載\(first.0.title)"
        }
        return "已下載 \(done.count) 包"
    }
}
