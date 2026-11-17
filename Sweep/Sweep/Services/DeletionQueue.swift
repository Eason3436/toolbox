import Foundation
import Observation
import Photos
import SwiftData

/// 待刪除清單。往上甩只是放進來，按下「刪除」才一次呼叫系統刪除（確認視窗只跳一次）。
@MainActor
@Observable
final class DeletionQueue {
    struct Item: Identifiable, Hashable {
        let id: String
        let kind: StatsKind
        let isVideo: Bool
    }

    struct Banner: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let systemImage: String
    }

    private(set) var items: [Item] = []
    var banner: Banner?
    private(set) var isDeleting = false

    var count: Int { items.count }
    var ids: Set<String> { Set(items.map(\.id)) }

    func contains(_ id: String) -> Bool {
        items.contains { $0.id == id }
    }

    func add(_ id: String, kind: StatsKind, isVideo: Bool) {
        guard !contains(id) else { return }
        items.append(Item(id: id, kind: kind, isVideo: isVideo))
    }

    func remove(_ id: String) {
        items.removeAll { $0.id == id }
    }

    func remove(_ ids: Set<String>) {
        items.removeAll { ids.contains($0.id) }
    }

    /// 真的刪掉。`keep` 是確認頁裡取消勾選的，會從清單拿掉、不刪。
    @discardableResult
    func commit(_ selected: [Item], keep: Set<String> = [], context: ModelContext) async -> Bool {
        guard !selected.isEmpty, !isDeleting else { return false }
        isDeleting = true
        defer { isDeleting = false }

        // 刪之前先量大小（刪掉就讀不到了）
        let ids = selected.map(\.id)
        let sizes = await Self.sizes(of: ids)

        do {
            let deleted = try await PhotoLibrary.delete(ids: ids)
            let deletedSet = Set(deleted)
            let records = selected.filter { deletedSet.contains($0.id) }
            StatsRecorder.recordDeleted(records.map { (id: $0.id, kind: $0.kind, bytes: sizes[$0.id] ?? 0) }, context: context)
            // 相簿裡本來就不見的也一起拿掉
            remove(Set(ids).union(keep))
            let bytes = records.reduce(Int64(0)) { $0 + (sizes[$1.id] ?? 0) }
            let size = bytes.formatted(.byteCount(style: .file))
            banner = Banner(text: "刪掉 \(records.count) 項，騰出 \(size)", systemImage: "checkmark.circle.fill")
            NotificationCenter.default.post(name: .sweepAssetsDeleted, object: nil, userInfo: ["ids": deletedSet])
            return true
        } catch DeleteError.cancelled {
            return false
        } catch {
            banner = Banner(text: "沒有刪除：\(error.localizedDescription)", systemImage: "exclamationmark.triangle.fill")
            return false
        }
    }

    private static func sizes(of ids: [String]) async -> [String: Int64] {
        await Task.detached(priority: .userInitiated) {
            let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            var sizes: [String: Int64] = [:]
            result.enumerateObjects { asset, _, _ in
                sizes[asset.localIdentifier] = PhotoLibrary.fileSize(of: asset)
            }
            return sizes
        }.value
    }
}

extension Notification.Name {
    /// userInfo["ids"]: Set<String>
    static let sweepAssetsDeleted = Notification.Name("SweepAssetsDeleted")
}
