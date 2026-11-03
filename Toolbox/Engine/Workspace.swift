import Foundation

/// 管理暫存與輸出資料夾。
enum Workspace {
    static let root: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("Toolbox", isDirectory: true)

    /// 「檔案」App 裡看得到的輸出資料夾：我的 iPhone › 工具箱 › 輸出
    static var outputFolder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("輸出", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func newDirectory(_ name: String) throws -> URL {
        let url = root
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 把外部檔案（檔案 App、分享、拖放）複製進 App 的暫存區。
    static func importCopy(of url: URL) throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dir = try newDirectory("Inputs")
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
    }

    /// 把只會短暫存在的檔案（例如照片挑選器給的）搬進暫存區。
    static func adopt(_ url: URL) throws -> URL {
        let dir = try newDirectory("Inputs")
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
    }

    static func uniqueURL(in dir: URL, base: String, ext: String) -> URL {
        let cleanBase = base.isEmpty ? "output" : base
        var candidate = dir.appendingPathComponent(cleanBase).appendingPathExtension(ext)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(cleanBase)-\(index)").appendingPathExtension(ext)
            index += 1
        }
        return candidate
    }

    /// 複製到「檔案」App 的輸出資料夾，回傳複製後的位置。
    @discardableResult
    static func saveToDocuments(_ urls: [URL]) throws -> [URL] {
        let folder = outputFolder
        return try urls.map { url in
            let ext = url.pathExtension
            let dest = uniqueURL(in: folder, base: url.deletingPathExtension().lastPathComponent, ext: ext)
            try FileManager.default.copyItem(at: url, to: dest)
            return dest
        }
    }

    static func fileSize(_ url: URL) -> Int64 {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return Int64(size)
    }

    static func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// 清掉超過一天的暫存檔。
    static func cleanUp() {
        let fm = FileManager.default
        guard let groups = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        let limit = Date().addingTimeInterval(-86_400)
        for group in groups {
            guard let runs = try? fm.contentsOfDirectory(at: group, includingPropertiesForKeys: [.creationDateKey]) else { continue }
            for run in runs {
                let created = (try? run.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
                if created < limit { try? fm.removeItem(at: run) }
            }
        }
    }
}
