import Foundation

/// 存到使用者選的資料夾（通常是 iCloud 雲碟）：
/// - 每台裝置打開 App 時先合併資料夾裡的「記帳同步.json」，再把自己的資料寫回去 → 不同裝置互相同步新增的資料
/// - 每天另外留一份備份，保留最近 14 份
@MainActor
enum CloudSync {
    static let bookmarkKey = "syncFolderBookmark"
    static let lastSyncKey = "syncLastDate"
    static let lastResultKey = "syncLastResult"
    static let syncFileName = "記帳同步.json"

    static var isOn: Bool { UserDefaults.standard.data(forKey: bookmarkKey) != nil }

    static var lastSync: Date? { UserDefaults.standard.object(forKey: lastSyncKey) as? Date }

    static func setFolder(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: bookmarkKey)
    }

    static func turnOff() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        UserDefaults.standard.removeObject(forKey: lastSyncKey)
    }

    static func folder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }
        return url
    }

    static var folderName: String? { folder()?.lastPathComponent }

    /// 打開 App、回到 App、離開 App 時呼叫；force 為 false 時 3 分鐘內不重複
    @discardableResult
    static func run(force: Bool = false) -> String? {
        guard let dir = folder() else { return nil }
        if !force, let last = lastSync, Date.now.timeIntervalSince(last) < 180 { return nil }
        let scoped = dir.startAccessingSecurityScopedResource()
        defer { if scoped { dir.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        let syncURL = dir.appendingPathComponent(syncFileName)
        var merged = 0
        do {
            // 1. 先把其他裝置寫進去的資料合併進來
            if fm.fileExists(atPath: syncURL.path) || fm.isUbiquitousItem(at: syncURL) {
                try? fm.startDownloadingUbiquitousItem(at: syncURL)
                var readError: NSError?
                var inner: Error?
                NSFileCoordinator().coordinate(readingItemAt: syncURL, options: [], error: &readError) { url in
                    do { merged = try Backup.restore(from: url) } catch { inner = error }
                }
                if let e = readError ?? inner as NSError? { throw e }
            }
            // 2. 再把完整資料寫回去
            let tmp = try Backup.export()
            let data = try Data(contentsOf: tmp)
            var writeError: NSError?
            var inner: Error?
            NSFileCoordinator().coordinate(writingItemAt: syncURL, options: .forReplacing, error: &writeError) { url in
                do { try data.write(to: url, options: .atomic) } catch { inner = error }
            }
            if let e = writeError ?? inner as NSError? { throw e }
            dailyCopy(data, in: dir)
            UserDefaults.standard.set(Date.now, forKey: lastSyncKey)
            let msg = merged > 0 ? "已同步，從其他裝置加入 \(merged) 筆" : "已同步"
            UserDefaults.standard.set(msg, forKey: lastResultKey)
            return msg
        } catch {
            let msg = "同步失敗：\(error.localizedDescription)"
            UserDefaults.standard.set(msg, forKey: lastResultKey)
            return msg
        }
    }

    /// 每天一份「備份/記帳備份-20261108.json」，保留最近 14 份
    private static func dailyCopy(_ data: Data, in dir: URL) {
        let fm = FileManager.default
        let backups = dir.appendingPathComponent("備份", isDirectory: true)
        try? fm.createDirectory(at: backups, withIntermediateDirectories: true)
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd"
        let today = backups.appendingPathComponent("記帳備份-\(df.string(from: .now)).json")
        try? data.write(to: today, options: .atomic)
        let files = ((try? fm.contentsOfDirectory(atPath: backups.path)) ?? [])
            .filter { $0.hasPrefix("記帳備份-") && $0.hasSuffix(".json") }
            .sorted()
        for name in files.dropLast(14) {
            try? fm.removeItem(at: backups.appendingPathComponent(name))
        }
    }
}
