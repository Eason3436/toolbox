import Foundation

/// 整個 App 的備份：一個 .recapbackup 檔，裡面是每天的紀錄、學習記憶、設定（可選擇加上錄音檔）。
/// 格式很單純：開頭 8 個字元「RECAPBK1」，接著一筆一筆的「路徑長度、路徑、資料長度、資料」。
/// API Key 存在鑰匙圈，不會放進備份。
enum BackupManager {
    enum BackupError: LocalizedError {
        case notBackup
        case damaged
        var errorDescription: String? {
            switch self {
            case .notBackup: "這不是 Recap 的備份檔。"
            case .damaged: "備份檔不完整或已損壞。"
            }
        }
    }

    struct Summary: Sendable {
        var days = 0
        var audioFiles = 0
        var restoredSettings = false
    }

    private static let magic = Data("RECAPBK1".utf8)
    private static let settingsPath = "__settings.plist"

    private static var docs: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    /// 做一份備份，回傳暫存檔位置。
    static func export(includeAudio: Bool) async throws -> URL {
        let settings = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        let settingsData = try PropertyListSerialization.data(fromPropertyList: settings, format: .binary, options: 0)
        let root = docs
        return try await Task.detached(priority: .userInitiated) {
            let stamp = Date().formatted(.iso8601.year().month().day())
            let out = FileManager.default.temporaryDirectory.appending(path: "Recap 備份 \(stamp).recapbackup")
            try? FileManager.default.removeItem(at: out)
            FileManager.default.createFile(atPath: out.path, contents: nil)
            let handle = try FileHandle(forWritingTo: out)
            defer { try? handle.close() }
            try handle.write(contentsOf: magic)
            try write(path: settingsPath, data: settingsData, to: handle)

            var folders = ["Days"]
            if includeAudio { folders.append("Recordings") }
            for folder in folders {
                let base = root.appending(path: folder)
                guard let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
                for case let url as URL in e {
                    guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                    try Task.checkCancellation()
                    let rel = folder + "/" + relative(url, to: base)
                    try write(path: rel, data: Data(contentsOf: url, options: .mappedIfSafe), to: handle)
                }
            }
            let memory = root.appending(path: "learned-terms.json")
            if let data = try? Data(contentsOf: memory) {
                try write(path: "learned-terms.json", data: data, to: handle)
            }
            return out
        }.value
    }

    /// 從備份還原。同一天的紀錄會被備份裡的版本取代，其他資料保留。
    static func restore(from url: URL) async throws -> Summary {
        let root = docs
        let (summary, settingsData) = try await Task.detached(priority: .userInitiated) { () throws -> (Summary, Data?) in
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            guard try handle.read(upToCount: magic.count) == magic else { throw BackupError.notBackup }
            var summary = Summary()
            var settingsData: Data?
            while let lenData = try handle.read(upToCount: 4), lenData.count == 4 {
                let pathLen = Int(lenData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian })
                guard pathLen > 0, pathLen < 4096,
                      let pathData = try handle.read(upToCount: pathLen), pathData.count == pathLen,
                      let path = String(data: pathData, encoding: .utf8),
                      let sizeData = try handle.read(upToCount: 8), sizeData.count == 8 else { throw BackupError.damaged }
                let size = Int(sizeData.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian })
                let data = size == 0 ? Data() : (try handle.read(upToCount: size) ?? Data())
                guard data.count == size else { throw BackupError.damaged }

                if path == settingsPath { settingsData = data; continue }
                // 只接受 App 自己的資料夾，避免寫到別的地方
                guard !path.contains(".."), path == "learned-terms.json" || path.hasPrefix("Days/") || path.hasPrefix("Recordings/") else { continue }
                let target = root.appending(path: path)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
                if path.hasPrefix("Days/") { summary.days += 1 }
                if path.hasPrefix("Recordings/") { summary.audioFiles += 1 }
            }
            return (summary, settingsData)
        }.value

        var result = summary
        if let settingsData,
           let dict = try? PropertyListSerialization.propertyList(from: settingsData, format: nil) as? [String: Any],
           let id = Bundle.main.bundleIdentifier {
            var merged = UserDefaults.standard.persistentDomain(forName: id) ?? [:]
            for (key, value) in dict { merged[key] = value }
            UserDefaults.standard.setPersistentDomain(merged, forName: id)
            result.restoredSettings = true
        }
        await MainActor.run {
            RecapStore.shared.reloadFromDisk()
            LearningMemory.shared.reload()
        }
        return result
    }

    private static func write(path: String, data: Data, to handle: FileHandle) throws {
        let pathData = Data(path.utf8)
        var pathLen = UInt32(pathData.count).littleEndian
        var size = UInt64(data.count).littleEndian
        try handle.write(contentsOf: Data(bytes: &pathLen, count: 4))
        try handle.write(contentsOf: pathData)
        try handle.write(contentsOf: Data(bytes: &size, count: 8))
        try handle.write(contentsOf: data)
    }

    private static func relative(_ url: URL, to base: URL) -> String {
        let basePath = base.standardizedFileURL.path
        var path = url.standardizedFileURL.path
        if path.hasPrefix(basePath) { path.removeFirst(basePath.count) }
        while path.hasPrefix("/") { path.removeFirst() }
        return path
    }
}
