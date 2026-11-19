import Foundation
import Observation
import Photos
import SwiftData

/// 照片頁的一組卡片
@MainActor
@Observable
final class PhotoDeckModel {
    enum Phase: Equatable {
        case loading
        case ready
        /// 這組看完了
        case finished
        /// 這個分類沒有照片
        case empty
        /// 都看過了（設定排除已看過）
        case allViewed
    }

    /// 可以復原的動作
    enum Step: Equatable {
        case advanced(from: Int)
        case marked(from: Int, id: String)
    }

    private(set) var filter: MediaFilter = .photos
    private(set) var assets: [PHAsset] = []
    private(set) var index = 0
    private(set) var phase: Phase = .loading
    private(set) var history: [Step] = []
    /// 換組時加 1，讓畫面知道要重新排版
    private(set) var generation = 0

    var current: PHAsset? { assets.indices.contains(index) ? assets[index] : nil }
    var remaining: Int { max(assets.count - index, 0) }
    var canUndo: Bool { !history.isEmpty }
    /// 第幾張（從 1 開始）
    var position: Int { min(index + 1, assets.count) }
    /// 這組看到哪（0–1），給上方進度條
    var progress: Double { assets.isEmpty ? 0 : Double(position) / Double(assets.count) }
    var canGoBack: Bool { index > 0 }

    /// 目前這張和後面兩張（卡片堆疊用）
    var visible: [DeckCard] {
        guard index < assets.count else { return [] }
        let end = min(index + 3, assets.count)
        return (index..<end).map { DeckCard(depth: $0 - index, asset: assets[$0]) }
    }

    /// 首頁扇子要畫的卡：前三張，加上排在最後面那張。
    /// 最後一張就是剛被送到後面的那張，留著它才看得到它退到後面的過程（之後淡掉）。
    var fanCards: [DeckCard] {
        guard index < assets.count else { return [] }
        var cards = visible
        let last = assets.count - 1
        if last - index >= cards.count {
            cards.append(DeckCard(depth: last - index, asset: assets[last]))
        }
        return cards
    }

    /// 首頁滑動：目前這張排到這組最後面，後面的往前一格。
    /// 不算看過、不記進復原紀錄；前面已經整理過的不動，所以復原紀錄的位置還是對的。
    func sendToBack() {
        guard phase == .ready, assets.count - index > 1 else { return }
        let front = assets.remove(at: index)
        assets.append(front)
    }

    // MARK: - 抽組

    func load(filter: MediaFilter, size: Int, excludeViewed: Bool, excludeFavorites: Bool,
              pending: Set<String>, context: ModelContext) async {
        self.filter = filter
        phase = .loading
        let all = await PhotoLibrary.identifiers(for: filter, excludeFavorites: excludeFavorites)
        guard !all.isEmpty else {
            reset(with: [])
            phase = .empty
            return
        }
        var excluded = pending
        if excludeViewed {
            excluded.formUnion(StatsRecorder.viewedIDs(context: context))
        }
        let ids = Shuffler.group(from: all, excluding: excluded, size: size)
        guard !ids.isEmpty else {
            reset(with: [])
            phase = .allViewed
            return
        }
        reset(with: PhotoLibrary.assets(for: ids))
        phase = assets.isEmpty ? .empty : .ready
    }

    private func reset(with assets: [PHAsset]) {
        self.assets = assets
        index = 0
        history = []
        generation += 1
    }

    // MARK: - 手勢

    /// 往左滑：下一張
    func next() {
        guard index < assets.count else { return }
        history.append(.advanced(from: index))
        move(to: index + 1)
    }

    /// 往右滑：上一張
    func previous() {
        guard index > 0 else { return }
        move(to: index - 1)
    }

    /// 往上甩：放進待刪除，換下一張
    func markForDeletion(queue: DeletionQueue) {
        guard let asset = current else { return }
        queue.add(asset.localIdentifier, kind: filter.statsKind, isVideo: false)
        history.append(.marked(from: index, id: asset.localIdentifier))
        move(to: index + 1)
    }

    func undo(queue: DeletionQueue) {
        guard let step = history.popLast() else { return }
        switch step {
        case .advanced(let from):
            move(to: from)
        case .marked(let from, let id):
            queue.remove(id)
            move(to: from)
        }
    }

    private func move(to newIndex: Int) {
        index = min(max(newIndex, 0), assets.count)
        phase = index >= assets.count ? .finished : .ready
    }

    /// 刪完之後，把已經不在相簿的卡片拿掉
    func removeDeleted(_ ids: Set<String>) {
        guard assets.contains(where: { ids.contains($0.localIdentifier) }) else { return }
        let before = assets[..<min(index, assets.count)].filter { ids.contains($0.localIdentifier) }.count
        assets.removeAll { ids.contains($0.localIdentifier) }
        index = max(index - before, 0)
        history = []
        if phase == .ready || phase == .finished {
            phase = index >= assets.count ? .finished : .ready
        }
    }

    /// 前後各 2 張先載
    var neighbors: [PHAsset] {
        guard !assets.isEmpty else { return [] }
        let lower = max(index - 2, 0)
        let upper = min(index + 2, assets.count - 1)
        guard lower <= upper else { return [] }
        return Array(assets[lower...upper])
    }
}

/// 堆疊裡的一張卡；depth 0 是最上面那張
struct DeckCard: Identifiable {
    let depth: Int
    let asset: PHAsset
    var id: String { asset.localIdentifier }
}

/// sheet(item:) 用
struct AssetRef: Identifiable {
    let asset: PHAsset
    var id: String { asset.localIdentifier }
}
