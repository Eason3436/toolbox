import AVFoundation
import AVKit
import Core
import Foundation
import UIKit

/// 播放引擎。第一階段只有 AVPlayer；第二階段的 MKV 會用 MPVKit 實作同一個介面，
/// 兩種引擎都透過 LocalStreamProxy 讀取 Drive 的檔案。
@MainActor
protocol PlaybackEngine: AnyObject {
    var currentTime: Double { get }
    var duration: Double { get }
    var isPlaying: Bool { get }
    /// 目前播放速度（暫停時是 0）
    var rate: Float { get }

    /// 播放狀態改變（播放／暫停）
    var onPlayingChanged: ((Bool) -> Void)? { get set }
    /// 播放中定期回報（秒）
    var onTick: ((Double) -> Void)? { get set }
    /// 播完
    var onFinished: (() -> Void)? { get set }
    /// 無法播放（含錯誤訊息）
    var onFailed: ((String) -> Void)? { get set }
    /// 播放速度改變（使用者在播放器選單換速度）
    var onRateChanged: ((Float) -> Void)? { get set }

    func load(url: URL, title: String, subtitle: String?, startAt: Double?, options: PlaybackOptions)
    func play()
    func pause()
    func seek(to seconds: Double)
    func skip(by seconds: Double)
    func setRate(_ rate: Float)
    func stop()
    /// 有外掛字幕時關掉內嵌字幕，避免兩份疊在一起
    func disableEmbeddedSubtitles()

    /// 播放畫面
    func makeScreen() -> any PlayerScreen
}

/// 從設定讀出來的播放選項
struct PlaybackOptions: Sendable {
    var forwardBuffer: Double
    var defaultRate: Float?
    var autoEmbeddedSubtitles: Bool
    var subtitleLanguage: MediaLanguage?
    var audioLanguage: MediaLanguage?
    var subtitleStyle: SubtitleStyle
    var autoPiP: Bool

    static func current() -> PlaybackOptions {
        PlaybackOptions(
            forwardBuffer: Prefs.double(Prefs.forwardBuffer),
            defaultRate: Prefs.bool(Prefs.rememberSpeed) ? Float(Prefs.double(Prefs.lastSpeed)) : nil,
            autoEmbeddedSubtitles: Prefs.bool(Prefs.autoEmbeddedSubtitles),
            subtitleLanguage: Prefs.subtitleLanguagePreference,
            audioLanguage: Prefs.audioLanguagePreference,
            subtitleStyle: .current(),
            autoPiP: Prefs.bool(Prefs.autoPiP)
        )
    }
}

/// 字幕樣式（內嵌字幕用 AVTextStyleRule，外掛字幕自己畫）
struct SubtitleStyle: Sendable {
    var colorHex: String
    var edgeHex: String
    var bold: Bool
    var italic: Bool
    var scale: Double

    static func current() -> SubtitleStyle {
        SubtitleStyle(
            colorHex: Prefs.string(Prefs.subtitleColor),
            edgeHex: Prefs.string(Prefs.subtitleEdgeColor),
            bold: Prefs.bool(Prefs.subtitleBold),
            italic: Prefs.bool(Prefs.subtitleItalic),
            scale: max(Prefs.double(Prefs.subtitleScale), 0.5)
        )
    }

    var color: UIColor { HexColor.uiColor(colorHex) }
    var edgeColor: UIColor { HexColor.uiColor(edgeHex) }

    /// 內嵌文字字幕（tx3g、WebVTT）的樣式
    var textStyleRules: [AVTextStyleRule] {
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        var attributes: [String: Any] = [
            kCMTextMarkupAttribute_ForegroundColorARGB as String: [1, Double(r), Double(g), Double(b)],
            kCMTextMarkupAttribute_CharacterEdgeStyle as String: kCMTextMarkupCharacterEdgeStyle_Uniform as String,
            kCMTextMarkupAttribute_RelativeFontSize as String: scale * 100,
        ]
        if bold { attributes[kCMTextMarkupAttribute_BoldStyle as String] = true }
        if italic { attributes[kCMTextMarkupAttribute_ItalicStyle as String] = true }
        return AVTextStyleRule(textMarkupAttributes: attributes).map { [$0] } ?? []
    }
}

/// AVPlayer 引擎：杜比視界、HDR、全景聲、子母畫面、AirPlay、內嵌字幕與音軌全部交給系統處理。
@MainActor
final class AVPlayerEngine: PlaybackEngine {
    let player = AVPlayer()

    var onPlayingChanged: ((Bool) -> Void)?
    var onTick: ((Double) -> Void)?
    var onFinished: (() -> Void)?
    var onFailed: ((String) -> Void)?
    var onRateChanged: ((Float) -> Void)?

    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var lastPlaying = false
    private var options: PlaybackOptions?
    private var selectionApplied = false

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
        rateObservation = player.observe(\.rate, options: [.new]) { @Sendable [weak self] player, _ in
            let rate = player.rate
            Task { @MainActor in
                if rate > 0 { self?.onRateChanged?(rate) }
            }
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
    var rate: Float { player.rate }

    func load(url: URL, title: String, subtitle: String?, startAt: Double?, options: PlaybackOptions) {
        self.options = options
        selectionApplied = false
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        item.externalMetadata = Self.metadata(title: title, subtitle: subtitle)
        // 0 是讓播放器自己決定；4K 杜比視界大約 60–100 Mbps
        item.preferredForwardBufferDuration = options.forwardBuffer
        item.textStyleRules = options.subtitleStyle.textStyleRules

        if let observer = endObserver { NotificationCenter.default.removeObserver(observer) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onFinished?() }
        }
        itemStatusObservation = item.observe(\.status, options: [.new]) { @Sendable [weak self] _, _ in
            Task { @MainActor in self?.itemStatusChanged() }
        }

        if let rate = options.defaultRate, rate > 0 { player.defaultRate = rate } else { player.defaultRate = 1 }
        player.replaceCurrentItem(with: item)
        if let startAt, startAt > 0 {
            // 還沒 readyToPlay 也可以先 seek；AVPlayer 會從那裡開始緩衝
            player.seek(to: CMTime(seconds: startAt, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .positiveInfinity)
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

    func skip(by seconds: Double) {
        var target = currentTime + seconds
        if duration > 0 { target = min(target, duration - 1) }
        seek(to: max(0, target))
    }

    func setRate(_ rate: Float) {
        player.rate = rate
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let observer = endObserver { NotificationCenter.default.removeObserver(observer) }
        endObserver = nil
        itemStatusObservation = nil
    }

    func disableEmbeddedSubtitles() {
        guard let item = player.currentItem,
              let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible),
              group.allowsEmptySelection else { return }
        item.select(nil, in: group)
    }

    func makeScreen() -> any PlayerScreen {
        let vc = DrivePlayerViewController()
        vc.player = player
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = options?.autoPiP ?? true
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
        guard let item = player.currentItem else { return }
        switch item.status {
        case .failed:
            onFailed?(Self.describe(item.error))
        case .readyToPlay:
            if !selectionApplied {
                selectionApplied = true
                applyMediaSelection(item)
            }
        default:
            break
        }
    }

    /// 照設定挑字幕與音軌的語言
    private func applyMediaSelection(_ item: AVPlayerItem) {
        guard let options else { return }
        let asset = item.asset
        if let group = asset.mediaSelectionGroup(forMediaCharacteristic: .legible) {
            let choices = group.options.filter { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) }
            if options.autoEmbeddedSubtitles, let language = options.subtitleLanguage,
               let index = language.bestIndex(choices.map { (languageTag: $0.extendedLanguageTag ?? $0.locale?.identifier, name: $0.displayName) }) {
                item.select(choices[index], in: group)
            } else if !options.autoEmbeddedSubtitles, group.allowsEmptySelection {
                item.select(nil, in: group)
            }
        }
        if let group = asset.mediaSelectionGroup(forMediaCharacteristic: .audible) {
            // 只挑能播的音軌（DTS、TrueHD 系統解不了，選到就沒有聲音）
            let choices = group.options.filter(\.isPlayable)
            let current = item.currentMediaSelection.selectedMediaOption(in: group)
            if let language = options.audioLanguage,
               let index = language.bestIndex(choices.map { (languageTag: $0.extendedLanguageTag ?? $0.locale?.identifier, name: $0.displayName) }) {
                item.select(choices[index], in: group)
            } else if let current, !current.isPlayable, let first = choices.first {
                item.select(first, in: group)
            }
        }
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
