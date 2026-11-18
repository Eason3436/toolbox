import Foundation
import SwiftData

/// App 的資料庫：固定放在 App 自己的 Application Support，檔名 EnRecall.store。
///
/// 不能用 SwiftData 的預設位置（default.store）：預設會放進 App Group，
/// 在 LiveContainer 裡就是 LiveContainer 自己的 App Group，裡面每個用預設資料庫的 App（EnRecall、Sweep）
/// 共用同一個檔案，輪流打開時會互相把對方的資料表遷移掉，看起來就像更新後牌組和進度全部不見。
enum AppDatabase {
    static let schema = Schema([Deck.self, Card.self, ReviewLog.self, CardContent.self, DeckLink.self])

    static let container: ModelContainer = make()

    private static var storeURL: URL {
        URL.applicationSupportDirectory.appending(path: "EnRecall.store")
    }

    private static func make() -> ModelContainer {
        let fm = FileManager.default
        try? fm.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
        let url = storeURL
        if !fm.fileExists(atPath: url.path(percentEncoded: false)) {
            copyLegacyStore(to: url)
        }

        let config = ModelConfiguration(schema: schema, url: url)
        if let container = try? ModelContainer(for: schema, configurations: config) {
            return container
        }
        // 打不開：舊檔改名留著（之後還救得回來），開一個新的讓 App 能用
        moveAside(url)
        if let container = try? ModelContainer(for: schema, configurations: config) {
            return container
        }
        return try! ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    /// 第一次用新位置：把舊的 default.store 複製過來（只複製，不動原本那份，別的 App 可能還在用）。
    /// 如果裡面現在是別的 App 的資料表，遷移後就是空的，跟重新開始一樣
    private static func copyLegacyStore(to url: URL) {
        let legacy = ModelConfiguration(schema: schema).url
        guard legacy.standardizedFileURL != url.standardizedFileURL else { return }
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacy.path(percentEncoded: false)) else { return }
        for suffix in ["", "-wal", "-shm"] {
            let from = URL(filePath: legacy.path(percentEncoded: false) + suffix)
            let to = URL(filePath: url.path(percentEncoded: false) + suffix)
            guard fm.fileExists(atPath: from.path(percentEncoded: false)) else { continue }
            try? fm.copyItem(at: from, to: to)
        }
    }

    private static func moveAside(_ url: URL) {
        let fm = FileManager.default
        let stamp = Int(Date().timeIntervalSince1970)
        let base = url.deletingPathExtension().path(percentEncoded: false)
        for suffix in ["", "-wal", "-shm"] {
            let from = URL(filePath: url.path(percentEncoded: false) + suffix)
            guard fm.fileExists(atPath: from.path(percentEncoded: false)) else { continue }
            try? fm.moveItem(at: from, to: URL(filePath: "\(base)-broken-\(stamp).store\(suffix)"))
        }
    }
}
