import AVFoundation

/// 麥克風錄音引擎：AVAudioSession + AVAudioEngine，把音訊分給各個 AudioSink。
/// 有 Background Modes 的 Audio 權限，App 退到背景也會繼續收音。
final class AudioEngineRecorder: @unchecked Sendable {
    enum Event: Sendable {
        /// 被來電、Siri 等打斷
        case interruptionBegan
        /// 打斷結束（shouldResume 為系統建議是否恢復）
        case interruptionEnded(shouldResume: Bool)
        /// 輸入裝置變了（耳機插拔等），引擎已停止
        case configurationChanged
        /// 系統音訊服務重置
        case mediaServicesReset
    }

    private var engine = AVAudioEngine()
    private let lock = NSLock()
    private var sinks: [AudioSink] = []
    private var observers: [NSObjectProtocol] = []
    private var lastLevelTime: CFAbsoluteTime = 0

    /// 事件（主執行緒）
    var onEvent: (@Sendable (Event) -> Void)?
    /// 音量 0～1（約每 0.1 秒一次，任意執行緒）
    var onLevel: (@Sendable (Float) -> Void)?

    private(set) var isRunning = false
    /// 錄音時開啟系統的人聲處理（降噪、自動增益）
    var voiceProcessing = true
    /// 關掉自動增益，讓音量能反映聲音的遠近（自動省電要用）
    var keepNaturalLevels = false
    /// 自己切換人聲處理時引擎也會發出設定變更通知，這段時間內忽略
    private var ignoreConfigChangeUntil: CFAbsoluteTime = 0

    init() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began:
                self?.isRunning = false
                self?.onEvent?(.interruptionBegan)
            case .ended:
                let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                self?.onEvent?(.interruptionEnded(shouldResume: options.contains(.shouldResume)))
            @unknown default: break
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.isRunning = false
            self.engine = AVAudioEngine()
            self.observeEngine()
            self.onEvent?(.mediaServicesReset)
        })
        observeEngine()
    }

    private var engineObserver: NSObjectProtocol?

    private func observeEngine() {
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        engineObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self, self.isRunning, CFAbsoluteTimeGetCurrent() > self.ignoreConfigChangeUntil else { return }
            self.isRunning = false
            self.onEvent?(.configurationChanged)
        }
    }

    func setSinks(_ sinks: [AudioSink]) {
        lock.lock()
        self.sinks = sinks
        lock.unlock()
    }

    /// 開始收音。必須已有麥克風權限。
    func start() throws {
        let session = AVAudioSession.sharedInstance()
        // mixWithOthers：不會把正在播的音樂停掉，也比較不容易被其他 App 打斷
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
        try session.setActive(true)
        try startEngine()
    }

    /// 錄音中切換人聲處理：只重啟引擎，不關閉音訊工作階段（關掉的話在背景就開不回來了）。
    func reconfigure(voiceProcessing: Bool) throws {
        guard isRunning else {
            self.voiceProcessing = voiceProcessing
            return
        }
        guard engine.inputNode.isVoiceProcessingEnabled != voiceProcessing else { return }
        self.voiceProcessing = voiceProcessing
        ignoreConfigChangeUntil = CFAbsoluteTimeGetCurrent() + 2
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        try startEngine()
        ignoreConfigChangeUntil = CFAbsoluteTimeGetCurrent() + 2
    }

    private func startEngine() throws {
        let input = engine.inputNode
        if input.isVoiceProcessingEnabled != voiceProcessing {
            do {
                try input.setVoiceProcessingEnabled(voiceProcessing)
            } catch {
                appLog.info("人聲處理設定失敗：\(error.localizedDescription)")
            }
        }
        if voiceProcessing {
            // 不要把正在播的音樂壓得太小聲
            input.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            input.isVoiceProcessingAGCEnabled = !keepNaturalLevels
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecapError.noInput }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format, block: Self.makeTap(self))
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 在非隔離的地方建立 tap，避免被推斷成主執行緒閉包。
    private static func makeTap(_ recorder: AudioEngineRecorder) -> AVAudioNodeTapBlock {
        { [weak recorder] buffer, _ in
            recorder?.dispatch(buffer)
        }
    }

    private func dispatch(_ buffer: AVAudioPCMBuffer) {
        let rms = AudioLevel.rms(buffer)
        lock.lock()
        let current = sinks
        lock.unlock()
        for sink in current { sink.receive(buffer, rms: rms) }
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastLevelTime > 0.1 {
            lastLevelTime = now
            onLevel?(AudioLevel.normalized(rms))
        }
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
    }
}
