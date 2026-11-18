import AVFoundation
import Observation
import Photos
import UIKit

/// 影片頁的播放器。最多同時留 3 個：上一支、目前這支、下一支。
@MainActor
@Observable
final class PlayerPool {
    private final class Entry {
        let player: AVQueuePlayer
        let looper: AVPlayerLooper

        init(player: AVQueuePlayer, looper: AVPlayerLooper) {
            self.player = player
            self.looper = looper
        }
    }

    private var entries: [String: Entry] = [:]
    @ObservationIgnored private var loading: Set<String> = []
    @ObservationIgnored private var wanted: Set<String> = []
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private weak var observedPlayer: AVQueuePlayer?

    private(set) var currentID: String?
    /// 目前這支播到哪（0–1）
    private(set) var progress: Double = 0
    private(set) var isPaused = false
    /// 分頁在畫面上才播放
    private var isActive = false

    func player(for id: String) -> AVQueuePlayer? {
        entries[id]?.player
    }

    /// 換到這支：只留前後各一支，其他釋放
    func focus(on id: String, neighbors: [String]) {
        if currentID != id {
            currentID = id
            progress = 0
            isPaused = false
        }
        wanted = Set(neighbors + [id])
        for (key, entry) in entries where !wanted.contains(key) {
            entry.player.pause()
            entries[key] = nil
        }
        for key in [id] + neighbors where entries[key] == nil && !loading.contains(key) {
            load(key)
        }
        applyPlayback()
    }

    func setActive(_ active: Bool) {
        isActive = active
        if active {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
        }
        applyPlayback()
    }

    func togglePause() {
        isPaused.toggle()
        applyPlayback()
    }

    func releaseAll() {
        stopObserving()
        for entry in entries.values { entry.player.pause() }
        entries = [:]
        wanted = []
        currentID = nil
    }

    // MARK: - 內部

    private func load(_ id: String) {
        guard let asset = PhotoLibrary.asset(for: id) else { return }
        loading.insert(id)
        Task {
            let item = await Self.playerItem(for: asset)
            loading.remove(id)
            // 載好的時候已經滑走了就不用
            guard let item, wanted.contains(id), entries[id] == nil else { return }
            let player = AVQueuePlayer()
            player.preventsDisplaySleepDuringVideoPlayback = true
            let looper = AVPlayerLooper(player: player, templateItem: item)
            entries[id] = Entry(player: player, looper: looper)
            applyPlayback()
        }
    }

    private func applyPlayback() {
        for (key, entry) in entries {
            if key == currentID, isActive, !isPaused {
                entry.player.play()
            } else {
                entry.player.pause()
            }
        }
        if let currentID, let player = entries[currentID]?.player {
            observe(player)
        } else {
            stopObserving()
        }
    }

    private func observe(_ player: AVQueuePlayer) {
        guard observedPlayer !== player else { return }
        stopObserving()
        observedPlayer = player
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self, weak player] time in
            MainActor.assumeIsolated {
                guard let self, let player, let duration = player.currentItem?.duration.seconds,
                      duration.isFinite, duration > 0 else { return }
                self.progress = min(max(time.seconds / duration, 0), 1)
            }
        }
    }

    private func stopObserving() {
        if let timeObserver, let observedPlayer {
            observedPlayer.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        observedPlayer = nil
        progress = 0
    }

    nonisolated private static func playerItem(for asset: PHAsset) async -> AVPlayerItem? {
        await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            // iCloud 上的影片邊下載邊播
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .automatic
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
                continuation.resume(returning: item)
            }
        }
    }
}
