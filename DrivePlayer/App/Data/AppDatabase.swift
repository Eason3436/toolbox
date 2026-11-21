import Foundation
import SwiftData

/// 資料庫固定放在 App 自己的 Application Support，檔名 DrivePlayer.store。
///
/// 不用 SwiftData 的預設位置（default.store）：在 LiveContainer 之類的環境裡預設會放進共用的 App Group，
/// 多個 App 共用同一個檔案會互相把資料表遷移掉。
enum AppDatabase {
    static let schema = Schema([LibraryFolder.self, MediaItem.self, Show.self, PlaybackState.self])

    @MainActor static let container: ModelContainer = make()

    private static var storeURL: URL {
        URL.applicationSupportDirectory.appending(path: "DrivePlayer.store")
    }

    private static func make() -> ModelContainer {
        let fm = FileManager.default
        try? fm.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
        let url = storeURL
        let config = ModelConfiguration(schema: schema, url: url)
        if let container = try? ModelContainer(for: schema, configurations: config) {
            return container
        }
        // 打不開（例如結構改了沒辦法遷移）：舊檔改名留著，開新的。媒體庫重新掃描就回來了
        let stamp = Int(Date().timeIntervalSince1970)
        for suffix in ["", "-wal", "-shm"] {
            let from = URL(filePath: url.path(percentEncoded: false) + suffix)
            guard fm.fileExists(atPath: from.path(percentEncoded: false)) else { continue }
            try? fm.moveItem(at: from, to: URL(filePath: url.path(percentEncoded: false) + ".broken-\(stamp)" + suffix))
        }
        if let container = try? ModelContainer(for: schema, configurations: config) {
            return container
        }
        return try! ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }
}
