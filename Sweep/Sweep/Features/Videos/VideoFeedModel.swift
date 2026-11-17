import Foundation
import Observation
import SwiftData

/// 影片頁的清單：整份洗牌，只存 ID
@MainActor
@Observable
final class VideoFeedModel {
    enum Phase: Equatable {
        case loading
        case ready
        case empty
    }

    private(set) var ids: [String] = []
    private(set) var phase: Phase = .loading
    private(set) var generation = 0
    /// 標記刪除的順序（復原用）
    private(set) var marks: [String] = []

    var canUndo: Bool { !marks.isEmpty }

    func load(excludeViewed: Bool, excludeFavorites: Bool, pending: Set<String>, context: ModelContext) async {
        phase = .loading
        let all = await PhotoLibrary.identifiers(for: .videos, excludeFavorites: excludeFavorites)
        var excluded = pending
        if excludeViewed {
            excluded.formUnion(StatsRecorder.viewedIDs(context: context))
        }
        ids = Shuffler.shuffled(all, excluding: excluded)
        marks = []
        generation += 1
        phase = ids.isEmpty ? .empty : .ready
    }

    /// 直接放一份清單（單元測試、預覽用）
    func setIDs(_ newIDs: [String]) {
        ids = newIDs
        marks = []
        phase = newIDs.isEmpty ? .empty : .ready
    }

    /// 第幾支（從 1 開始）
    func position(of id: String?) -> Int {
        guard let id, let index = ids.firstIndex(of: id) else { return 0 }
        return index + 1
    }

    func id(after id: String) -> String? {
        guard let index = ids.firstIndex(of: id), index + 1 < ids.count else { return nil }
        return ids[index + 1]
    }

    /// 前一支和下一支（預載用）
    func neighbors(of id: String) -> [String] {
        guard let index = ids.firstIndex(of: id) else { return [] }
        var result: [String] = []
        if index > 0 { result.append(ids[index - 1]) }
        if index + 1 < ids.count { result.append(ids[index + 1]) }
        return result
    }

    func recordMark(_ id: String) {
        marks.append(id)
    }

    func popMark() -> String? {
        marks.popLast()
    }

    /// 刪完把影片拿掉。回傳刪完之後應該停在哪一支。
    func removeDeleted(_ deleted: Set<String>, current: String?) -> String? {
        guard ids.contains(where: deleted.contains) else { return current }
        var next = current
        if let current, deleted.contains(current), let index = ids.firstIndex(of: current) {
            // 往後找第一支沒被刪的，沒有就往前找
            next = ids[index...].first { !deleted.contains($0) }
                ?? ids[..<index].last { !deleted.contains($0) }
        }
        ids.removeAll(where: deleted.contains)
        marks.removeAll(where: deleted.contains)
        if ids.isEmpty { phase = .empty }
        return next
    }
}
