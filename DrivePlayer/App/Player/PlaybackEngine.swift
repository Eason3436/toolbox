import AVFoundation
import AVKit
import Foundation

/// 播放引擎。第一階段只有 AVPlayer；第二階段的 MKV 會用 MPVKit 實作同一個介面，
/// 兩種引擎都透過 LocalStreamProxy 讀取 Drive 的檔案。
@MainActor
protocol PlaybackEngine: AnyObject {
    var currentTime: Double { get }
    var duration: Double { get }
    var isPlaying: Bool { get }

    /// 播放狀態改變（播放／暫停）
    var onPlayingChanged: ((Bool) -> Void)? { get set }
    /// 播放中定期回報（秒）
    var onTick: ((Double) -> Void)? { get set }
    /// 播完
    var onFinished: (() -> Void)? { get set }
    /// 無法播放（含錯誤訊息）
    var onFailed: ((String) -> Void)? { get set }

    func load(url: URL, title: String, subtitle: String?, startAt: Double?)
    func play()
    func pause()
    func seek(to seconds: Double)
    func stop()

    /// 播放畫面
    func makeScreen() -> any PlayerScreen
}

/// AVPlayer 引擎：杜比視界、HDR、全景聲、子母畫面、AirPlay、內嵌字幕與音軌全部交給系統處理。
@MainActor
final class AVPlayerEngine: PlaybackEngine {
    let player = AVPlayer()

    var onPlayingChanged: ((Bool) -> Void)?
    var onTick: ((Double) -> Void)?
    var onFinished: (() -> Void)?
    var onFailed: ((String) -> Void)?

    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var pendingSeek: Double?
    private var lastPlaying = false

    init() {
        player.allowsExternalPlayback = true
        player.preventsDisplaySleepDuringVideoPlayback = true
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                self?.onTick?(time.seconds)
            }
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { @Sendable [weak self] _, _ in
            Task { @MainActor in self?.timeControlChanged() }
        }
    }

    var currentTime: Double {
        let t = player.currentTime().seconds
        return t.isFinite ? t : 0
    }

    var duration: Double {
        guard let d = player.currentItem?.duration.seconds, d.isFinite else { return 0 }
        return d
    }

    var isPlaying: Bool { player.timeControlStatus != .paused }

    func load(url: URL, title: String, subtitle: String?, startAt: Double?) {
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        item.externalMetadata = Self.metadata(title: title, subtitle: subtitle)
        // 播放器自己決定緩衝；4K 杜比視界大約 60–100 Mbps
        item.preferredForwardBufferDuration = 0

        if let observer = endObserver { NotificationCenter.default.removeObserver(observer) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onFinished?() }
        }
        itemStatusObservation = item.observe(\.status, options: [.new]) { @Sendable [weak self] _, _ in
            Task { @MainActor in self?.itemStatusChanged() }
        }

        pendingSeek = (startAt ?? 0) > 0 ? startAt : nil
        player.replaceCurrentItem(with: item)
        if let pendingSeek {
            // 還沒 readyToPlay 也可以先 seek；AVPlayer 會從那裡開始緩衝
            player.seek(to: CMTime(seconds: pendingSeek, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .positiveInfinity)
            self.pendingSeek = nil
        }
    }

    func play() {
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
    }

    func pause() { player.pause() }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let observer = endObserver { NotificationCenter.default.removeObserver(observer) }
        endObserver = nil
        itemStatusObservation = nil
    }

    func makeScreen() -> any PlayerScreen {
        let vc = DrivePlayerViewController()
        vc.player = player
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        vc.updatesNowPlayingInfoCenter = true
        return vc
    }

    private func timeControlChanged() {
        let playing = isPlaying
        guard playing != lastPlaying else { return }
        lastPlaying = playing
        onPlayingChanged?(playing)
    }

    private func itemStatusChanged() {
        guard let item = player.currentItem, item.status == .failed else { return }
        onFailed?(Self.describe(item.error))
    }

    static func describe(_ error: Error?) -> String {
        guard let error else { return "無法播放這個檔案" }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut:
                return "網路中斷，無法繼續播放"
            case NSURLErrorUserAuthenticationRequired, NSURLErrorUserCancelledAuthentication:
                return "Google 登入已失效，請到「設定」重新登入"
            default: break
            }
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSURLErrorDomain {
            return describe(underlying)
        }
        return "無法播放：\(error.localizedDescription)"
    }

    private static func metadata(title: String, subtitle: String?) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        let t = AVMutableMetadataItem()
        t.identifier = .commonIdentifierTitle
        t.value = title as NSString
        t.extendedLanguageTag = "und"
        items.append(t)
        if let subtitle {
            let s = AVMutableMetadataItem()
            s.identifier = .iTunesMetadataTrackSubTitle
            s.value = subtitle as NSString
            s.extendedLanguageTag = "und"
            items.append(s)
        }
        return items
    }
}
