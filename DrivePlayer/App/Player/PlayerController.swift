import AVFoundation
import AVKit
import Core
import Observation
import UIKit

/// 要播放的東西
struct PlaybackRequest: Sendable {
    var fileId: String
    var fileName: String
    var title: String
    var subtitle: String?
    var startAt: Double?
    /// 所在資料夾（找外掛字幕）
    var parentId: String?
    /// 片頭結束的位置（秒），0 是不跳
    var introEnd: Double = 0
    /// 片尾長度（秒），0 是不跳
    var outroLength: Double = 0
    /// 載入畫面：片名 logo、背景
    var logoURL: URL?
    var backdropURL: URL?
    /// 電影：選的音軌（第幾條）
    var audioChoice: Int?
    /// 劇集：記住的音軌
    var audioKey: AudioTrackKey?
}

/// 播放器：用 UIKit 全螢幕呈現 AVPlayerViewController（原生的關閉鍵、子母畫面、AirPlay、字幕與音軌選單）。
@MainActor
@Observable
final class PlayerController: NSObject {
    private(set) var current: PlaybackRequest?
    private(set) var isPresented = false
    var errorMessage: String?

    @ObservationIgnored private let proxy: LocalStreamProxy
    @ObservationIgnored private let drive: DriveClient
    @ObservationIgnored private(set) var engine: PlaybackEngine = AVPlayerEngine()
    @ObservationIgnored private weak var viewController: (any PlayerScreen)?
    @ObservationIgnored private var pipActive = false
    /// 已經因為片尾當成播完
    @ObservationIgnored private var outroHandled = false
    /// 長按加速前的速度
    @ObservationIgnored private var rateBeforeLongPress: Float?
    @ObservationIgnored private var subtitleTask: Task<Void, Never>?
    /// 這次載入已經開始播（載入畫面收起來了）
    @ObservationIgnored private var loadingStarted = false

    /// 播放中、暫停、離開時呼叫（M5 的進度記錄掛在這裡）
    @ObservationIgnored var onProgress: ((PlaybackRequest, _ position: Double, _ duration: Double, _ reason: ProgressReason) -> Void)?
    /// 播完時呼叫；回傳下一集就自動倒數播放
    @ObservationIgnored var nextProvider: ((PlaybackRequest) -> PlaybackRequest?)?
    @ObservationIgnored var autoPlayNext: () -> Bool = { true }

    enum ProgressReason: Sendable { case tick, paused, closed, finished, background }

    init(proxy: LocalStreamProxy, drive: DriveClient) {
        self.proxy = proxy
        self.drive = drive
        super.init()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
        wireEngine()
    }

    // MARK: - 播放

    func play(_ request: PlaybackRequest) async {
        errorMessage = nil
        if let current, current.fileId != request.fileId { report(.closed) }
        // 先開播放畫面顯示載入中（片名 logo 裡跑進度），代理讀檔頭、TrueHD 準備好再載入
        let wasPresented = viewController?.presentingViewController != nil
        if wasPresented { engine.stop() }
        current = request
        outroHandled = false
        loadingStarted = false
        presentIfNeeded()
        viewController?.showSubtitles(nil, style: .current())
        viewController?.showLoading(PlayerLoading(title: request.title, subtitle: request.subtitle,
                                                  logoURL: request.logoURL, backdropURL: request.backdropURL))
        viewController?.setLoadingStage(.connecting)
        do {
            let url = try await proxy.streamURL(fileId: request.fileId, filename: request.fileName)
            guard current?.fileId == request.fileId, viewController != nil else { return }
            viewController?.setLoadingStage(.buffering)
            var start = request.startAt
            // 自動跳過片頭：從頭播（或續播點還在片頭裡）就從片頭結束的地方開始
            if request.introEnd > 0, (start ?? 0) < request.introEnd { start = request.introEnd }
            var options = PlaybackOptions.current()
            options.audioChoice = request.audioChoice
            options.audioKey = request.audioKey
            options.truehd = await proxy.remuxedAudio(fileId: request.fileId)
            engine.load(url: url, title: request.title, subtitle: request.subtitle, startAt: start, options: options)
            engine.play()
            loadExternalSubtitles(for: request)
        } catch {
            let message = "無法啟動串流：\(error.localizedDescription)"
            errorMessage = message
            viewController?.showLoading(nil)
            viewController?.showError(message)
        }
    }

    func close() {
        report(.closed)
        subtitleTask?.cancel()
        engine.stop()
        current = nil
        // 播放畫面裡已經顯示過錯誤，關掉後不要在首頁再跳一次
        errorMessage = nil
        isPresented = false
        if let vc = viewController, vc.presentingViewController != nil {
            vc.dismiss(animated: true)
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// App 退到背景
    func appDidEnterBackground() {
        guard current != nil else { return }
        report(.background)
    }

    // MARK: - 內部

    private var lastTickSave = Date.distantPast

    private func wireEngine() {
        engine.onTick = { [weak self] _ in
            guard let self, self.engine.isPlaying else { return }
            if Date().timeIntervalSince(self.lastTickSave) >= 10 {
                self.lastTickSave = Date()
                self.report(.tick)
            }
            self.checkOutro()
        }
        engine.onRateChanged = { [weak self] rate in
            // 長按加速不算；使用者在選單換的速度才記住
            guard let self, self.rateBeforeLongPress == nil, Prefs.bool(Prefs.rememberSpeed) else { return }
            Prefs.defaults.set(Double(rate), forKey: Prefs.lastSpeed)
        }
        engine.onPlayingChanged = { [weak self] playing in
            if !playing { self?.report(.paused) }
        }
        engine.onFinished = { [weak self] in self?.finished() }
        engine.onFailed = { [weak self] message in
            self?.errorMessage = message
            self?.viewController?.showLoading(nil)
            self?.viewController?.showError(message)
        }
        engine.onReady = { [weak self] in
            guard let self, !self.loadingStarted else { return }
            self.viewController?.setLoadingStage(.ready)
        }
        engine.onStartedPlaying = { [weak self] in
            guard let self, !self.loadingStarted else { return }
            self.loadingStarted = true
            self.viewController?.setLoadingStage(.playing)
        }
    }

    private func report(_ reason: ProgressReason) {
        guard let current else { return }
        let duration = engine.duration
        let position = reason == .finished ? duration : engine.currentTime
        guard duration > 0 || position > 0 else { return }
        onProgress?(current, position, duration, reason)
    }

    /// 自動跳過片尾：剩下片尾長度時就當成播完（標記已看、倒數下一集）
    private func checkOutro() {
        guard let current, current.outroLength > 0, !outroHandled else { return }
        let duration = engine.duration
        guard duration > current.outroLength * 2, engine.currentTime >= duration - current.outroLength else { return }
        outroHandled = true
        finished()
    }

    private func finished() {
        report(.finished)
        guard let current, autoPlayNext(), let next = nextProvider?(current) else { return }
        viewController?.showNextUp(title: next.subtitle ?? next.title, seconds: 10) { [weak self] accepted in
            guard let self else { return }
            if accepted {
                Task { await self.play(next) }
            }
        }
    }

    private func presentIfNeeded() {
        if let vc = viewController, vc.presentingViewController != nil { return }
        guard let presenter = UIApplication.shared.topViewController else { return }
        let vc = engine.makeScreen()
        vc.onDismiss = { [weak self] in self?.hostDismissed() }
        vc.onLongPress = { [weak self] began in self?.longPress(began) }
        vc.onDoubleTap = { [weak self] forward in self?.doubleTap(forward) }
        (vc as? AVPlayerViewController)?.delegate = self
        viewController = vc
        isPresented = true
        presenter.present(vc, animated: true)
    }

    // MARK: - 手勢

    /// 長按加速，放開恢復
    private func longPress(_ began: Bool) {
        let rate = Float(Prefs.double(Prefs.longPressRate))
        guard rate > 0 else { return }
        if began {
            guard engine.isPlaying, rateBeforeLongPress == nil else { return }
            rateBeforeLongPress = engine.rate
            engine.setRate(rate)
            viewController?.showSpeedIndicator(rate)
        } else if let previous = rateBeforeLongPress {
            engine.setRate(previous > 0 ? previous : 1)
            rateBeforeLongPress = nil
            viewController?.showSpeedIndicator(nil)
        }
    }

    /// 點兩下左邊倒轉、右邊快轉
    private func doubleTap(_ forward: Bool) {
        let seconds = Prefs.double(forward ? Prefs.skipForward : Prefs.skipBackward)
        guard seconds > 0 else { return }
        engine.skip(by: forward ? seconds : -seconds)
        viewController?.showSkipIndicator(forward: forward, seconds: Int(seconds))
    }

    // MARK: - 外掛字幕

    /// 同資料夾、同檔名的 .srt／.vtt／.ass
    private func loadExternalSubtitles(for request: PlaybackRequest) {
        subtitleTask?.cancel()
        guard Prefs.bool(Prefs.externalSubtitles), let folder = request.parentId else { return }
        let drive = drive
        let language = Prefs.subtitleLanguagePreference
        subtitleTask = Task { [weak self] in
            guard let files = try? await drive.list(folderId: folder) else { return }
            let candidates = files.filter {
                SubtitleParser.extensions.contains($0.fileExtension)
                    && SubtitleParser.matches(subtitleName: $0.name, videoName: request.fileName)
            }
            guard !candidates.isEmpty else { return }
            let index = language?.bestIndex(candidates.map { (languageTag: nil, name: $0.name) }) ?? 0
            let file = candidates[index]
            guard let data = try? await drive.download(fileId: file.id),
                  let text = TextDecoding.decode(data) else { return }
            let track = SubtitleParser.parse(text, fileExtension: file.fileExtension)
            guard !Task.isCancelled, !track.cues.isEmpty, let self, self.current?.fileId == request.fileId else { return }
            self.engine.disableEmbeddedSubtitles()
            self.viewController?.showSubtitles(track, style: .current())
        }
    }

    private func hostDismissed() {
        // 子母畫面開始時 AVKit 會自己把全螢幕收起來，這時不能停止播放
        guard !pipActive else { return }
        close()
    }
}

extension PlayerController: AVPlayerViewControllerDelegate {
    nonisolated func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        MainActor.assumeIsolated { pipActive = true }
    }

    nonisolated func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        MainActor.assumeIsolated {
            pipActive = false
            // 從子母畫面關掉（沒有回到全螢幕）
            if viewController?.presentingViewController == nil { close() }
        }
    }

    nonisolated func playerViewController(
        _ playerViewController: AVPlayerViewController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping @Sendable (Bool) -> Void
    ) {
        MainActor.assumeIsolated {
            guard let vc = viewController else {
                completionHandler(false)
                return
            }
            if vc.presentingViewController != nil {
                completionHandler(true)
                return
            }
            guard let presenter = UIApplication.shared.topViewController else {
                completionHandler(false)
                return
            }
            presenter.present(vc, animated: true) { completionHandler(true) }
        }
    }
}
