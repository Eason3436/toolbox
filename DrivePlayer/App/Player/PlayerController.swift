import AVFoundation
import AVKit
import Observation
import UIKit

/// 要播放的東西
struct PlaybackRequest: Sendable {
    var fileId: String
    var fileName: String
    var title: String
    var subtitle: String?
    var startAt: Double?
}

/// 播放器：用 UIKit 全螢幕呈現 AVPlayerViewController（原生的關閉鍵、子母畫面、AirPlay、字幕與音軌選單）。
@MainActor
@Observable
final class PlayerController: NSObject {
    private(set) var current: PlaybackRequest?
    private(set) var isPresented = false
    var errorMessage: String?

    @ObservationIgnored private let proxy: LocalStreamProxy
    @ObservationIgnored private(set) var engine: PlaybackEngine = AVPlayerEngine()
    @ObservationIgnored private weak var viewController: (any PlayerScreen)?
    @ObservationIgnored private var pipActive = false

    /// 播放中、暫停、離開時呼叫（M5 的進度記錄掛在這裡）
    @ObservationIgnored var onProgress: ((PlaybackRequest, _ position: Double, _ duration: Double, _ reason: ProgressReason) -> Void)?
    /// 播完時呼叫；回傳下一集就自動倒數播放
    @ObservationIgnored var nextProvider: ((PlaybackRequest) -> PlaybackRequest?)?
    @ObservationIgnored var autoPlayNext: () -> Bool = { true }

    enum ProgressReason: Sendable { case tick, paused, closed, finished, background }

    init(proxy: LocalStreamProxy) {
        self.proxy = proxy
        super.init()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
        wireEngine()
    }

    // MARK: - 播放

    func play(_ request: PlaybackRequest) async {
        errorMessage = nil
        do {
            let url = try await proxy.streamURL(fileId: request.fileId, filename: request.fileName)
            if let current, current.fileId != request.fileId { report(.closed) }
            current = request
            engine.load(url: url, title: request.title, subtitle: request.subtitle, startAt: request.startAt)
            presentIfNeeded()
            engine.play()
        } catch {
            errorMessage = "無法啟動串流：\(error.localizedDescription)"
        }
    }

    func close() {
        report(.closed)
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
        }
        engine.onPlayingChanged = { [weak self] playing in
            if !playing { self?.report(.paused) }
        }
        engine.onFinished = { [weak self] in self?.finished() }
        engine.onFailed = { [weak self] message in
            self?.errorMessage = message
            self?.viewController?.showError(message)
        }
    }

    private func report(_ reason: ProgressReason) {
        guard let current else { return }
        let duration = engine.duration
        let position = reason == .finished ? duration : engine.currentTime
        guard duration > 0 || position > 0 else { return }
        onProgress?(current, position, duration, reason)
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
        (vc as? AVPlayerViewController)?.delegate = self
        viewController = vc
        isPresented = true
        presenter.present(vc, animated: true)
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
