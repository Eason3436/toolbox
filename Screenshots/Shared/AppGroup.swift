import Foundation

/// App Group 共用容器：主 App 與 Share Extension 共用資料庫、待處理佇列、縮圖快取。
///
/// SideStore／AltStore 重新簽署時會把 App Group 名稱加上你的 Team ID，
/// 並把實際名稱寫進 Info.plist 的 `ALTAppGroups`，所以這裡優先讀它。
enum AppGroup {
    static let defaultIdentifier = "group.com.eason3436.screenshots"

    /// 實際可用的共用容器；拿不到時回傳 nil（例如簽署沒有帶 App Group）。
    static let containerURL: URL? = {
        for identifier in candidateIdentifiers() {
            if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) {
                return url
            }
        }
        return nil
    }()

    /// 共用容器可用就用它，不行就退回 App 自己的 Application Support。
    static var baseURL: URL {
        if let containerURL { return containerURL }
        let url = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func directory(_ name: String) -> URL {
        let url = baseURL.appending(path: name, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func candidateIdentifiers() -> [String] {
        var result: [String] = []
        // 自己的 Info.plist
        if let groups = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] {
            result += groups
        }
        // Extension 位於 主App.app/PlugIns/xxx.appex，往上兩層讀主 App 的 Info.plist
        let mainAppURL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        if mainAppURL.pathExtension == "app",
           let info = NSDictionary(contentsOf: mainAppURL.appending(path: "Info.plist")),
           let groups = info["ALTAppGroups"] as? [String] {
            result += groups
        }
        result.append(defaultIdentifier)
        return result
    }
}

/// Share Extension 寫入、主 App 讀取的待處理圖片收件匣。
enum SharedInbox {
    static var directory: URL { AppGroup.directory("Inbox") }

    /// 共用容器是否真的可用（Extension 需要它才能把圖片交給主 App）。
    static var isAvailable: Bool { AppGroup.containerURL != nil }

    /// 存入一張圖片，回傳檔案位置。
    @discardableResult
    static func add(imageData: Data, fileExtension: String) throws -> URL {
        let ext = fileExtension.isEmpty ? "img" : fileExtension
        let url = directory.appending(path: "\(Date.now.timeIntervalSince1970)-\(UUID().uuidString).\(ext)")
        try imageData.write(to: url, options: .atomic)
        return url
    }

    static func pendingFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
