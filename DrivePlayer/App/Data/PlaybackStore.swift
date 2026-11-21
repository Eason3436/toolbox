import Core
import Foundation
import SwiftData

/// 播放進度的讀寫（§5：每 10 秒存一次；暫停、離開、退到背景立刻存；看完 90% 標記已看並清除續播位置）
@MainActor
final class PlaybackStore {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func state(for fileId: String) -> PlaybackState? {
        try? context.fetch(FetchDescriptor<PlaybackState>(predicate: #Predicate { $0.fileId == fileId })).first
    }

    private func stateOrCreate(_ fileId: String) -> PlaybackState {
        if let s = state(for: fileId) { return s }
        let s = PlaybackState(fileId: fileId)
        context.insert(s)
        return s
    }

    func resumePosition(for fileId: String) -> Double? {
        state(for: fileId)?.resumePosition
    }

    /// 播放器回報的進度
    func record(fileId: String, position: Double, duration: Double) {
        let s = stateOrCreate(fileId)
        if duration > 0 { s.duration = duration }
        s.lastPlayed = .now
        if PlaybackRules.isWatched(position: position, duration: s.duration) {
            s.watched = true
            s.position = 0
        } else {
            s.position = position
            if position >= PlaybackRules.minimumResumeSeconds { s.watched = false }
        }
        try? context.save()
    }

    func setWatched(_ fileIds: [String], watched: Bool) {
        for id in fileIds {
            let s = stateOrCreate(id)
            s.watched = watched
            s.position = 0
            if watched { s.lastPlayed = .now }
        }
        try? context.save()
    }

    func isWatched(_ fileId: String) -> Bool {
        state(for: fileId)?.watched ?? false
    }
}
