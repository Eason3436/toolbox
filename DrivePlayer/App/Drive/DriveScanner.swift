import Core
import Foundation

struct ScannedFile: Sendable {
    var file: DriveFile
    /// 上層資料夾名稱，由近到遠（含媒體庫根資料夾）
    var parentFolders: [String]
}

/// 遞迴掃描 Drive 資料夾裡的影片檔（同時最多讀 4 個資料夾）
struct DriveScanner: Sendable {
    let drive: DriveClient
    var maxConcurrent = 4

    func scan(
        rootId: String, rootName: String,
        progress: @escaping @Sendable (_ folders: Int, _ videos: Int, _ current: String) async -> Void
    ) async throws -> [ScannedFile] {
        struct Pending: Sendable {
            var id: String
            var name: String
            var parents: [String] // 由近到遠
        }
        var queue = [Pending(id: rootId, name: rootName, parents: [])]
        var results: [ScannedFile] = []
        var foldersDone = 0
        var seen: Set<String> = [rootId]

        while !queue.isEmpty {
            let batch = Array(queue.prefix(maxConcurrent))
            queue.removeFirst(batch.count)
            let listed = try await withThrowingTaskGroup(of: (Pending, [DriveFile]).self) { group in
                for folder in batch {
                    group.addTask { (folder, try await drive.list(folderId: folder.id)) }
                }
                var out: [(Pending, [DriveFile])] = []
                for try await item in group { out.append(item) }
                return out
            }
            for (folder, files) in listed {
                foldersDone += 1
                let chain = [folder.name] + folder.parents
                for f in files {
                    if f.isFolder {
                        // 捷徑或共用造成的循環
                        guard seen.insert(f.id).inserted else { continue }
                        queue.append(Pending(id: f.id, name: f.name, parents: chain))
                    } else if f.isPlayableVideo {
                        results.append(ScannedFile(file: f, parentFolders: chain))
                    }
                }
                await progress(foldersDone, results.count, folder.name)
            }
            try Task.checkCancellation()
        }
        return results
    }
}
