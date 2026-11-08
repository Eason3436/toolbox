import AVFoundation
import SoundAnalysis

/// 判斷「有沒有人在近距離說話」：音量要夠大，而且聲音分類器認得出是人聲。
/// 只有音量過門檻的聲音才送去分類，平常幾乎不耗電；遠處的背景人聲音量小，不會被算進去。
final class SpeechPresenceDetector: NSObject, AudioSink, SNResultsObserving, @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "recap.speech-detector", qos: .utility)
    private var thresholdRMS: Float
    private var analyzer: SNAudioStreamAnalyzer?
    private var request: SNClassifySoundRequest?
    private var format: AVAudioFormat?
    private var framePosition: AVAudioFramePosition = 0
    private var classifierFailed = false
    /// 最近幾次判定為近距離人聲的時間
    private var hits: [CFAbsoluteTime] = []
    private var lastLoudTime: CFAbsoluteTime = 0
    private(set) var lastNearSpeech: Date = .now

    /// 偵測到持續的近距離說話（主執行緒外呼叫，已節流）
    var onNearSpeech: (@Sendable () -> Void)?

    init(thresholdDB: Float) {
        thresholdRMS = pow(10, thresholdDB / 20)
        super.init()
    }

    func setThreshold(db: Float) {
        lock.lock(); thresholdRMS = pow(10, db / 20); lock.unlock()
    }

    /// 重新開始計時（例如剛開始錄音）
    func reset() {
        lock.lock()
        lastNearSpeech = .now
        hits.removeAll()
        lock.unlock()
    }

    var secondsSinceNearSpeech: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(lastNearSpeech)
    }

    func receive(_ buffer: AVAudioPCMBuffer, rms: Float) {
        lock.lock()
        let threshold = thresholdRMS
        let failed = classifierFailed
        lock.unlock()
        guard rms >= threshold else { return }
        if failed {
            // 沒有分類器：只看音量
            registerHit()
            return
        }
        guard let copy = Self.copy(buffer) else { return }
        queue.async { [weak self] in self?.analyze(copy) }
    }

    private func analyze(_ buffer: AVAudioPCMBuffer) {
        if analyzer == nil || format != buffer.format {
            let analyzer = SNAudioStreamAnalyzer(format: buffer.format)
            do {
                let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
                request.windowDuration = CMTime(seconds: 1, preferredTimescale: 48_000)
                request.overlapFactor = 0.5
                try analyzer.add(request, withObserver: self)
                self.analyzer = analyzer
                self.request = request
                self.format = buffer.format
                framePosition = 0
            } catch {
                appLog.info("聲音分類器無法使用，改用音量判斷：\(error.localizedDescription)")
                lock.lock(); classifierFailed = true; lock.unlock()
                return
            }
        }
        analyzer?.analyze(buffer, atAudioFramePosition: framePosition)
        framePosition += AVAudioFramePosition(buffer.frameLength)
    }

    // MARK: SNResultsObserving

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let speech = ["speech", "conversation", "narration_monologue", "whispering", "shout", "yell", "children_shouting", "laughter"]
            .compactMap { result.classification(forIdentifier: $0)?.confidence }
            .max() ?? 0
        if speech >= 0.5 { registerHit() }
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        appLog.info("聲音分類失敗：\(error.localizedDescription)")
        lock.lock(); classifierFailed = true; lock.unlock()
    }

    // MARK: -

    /// 5 秒內累積兩次判定才算真的有人在近處說話，避免一聲咳嗽或關門就切換。
    private func registerHit() {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        hits.append(now)
        hits.removeAll { now - $0 > 5 }
        let confirmed = hits.count >= 2
        if confirmed { lastNearSpeech = .now }
        let shouldNotify = confirmed && now - lastLoudTime > 2
        if shouldNotify { lastLoudTime = now }
        lock.unlock()
        if shouldNotify { onNearSpeech?() }
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        out.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        if let src = buffer.floatChannelData, let dst = out.floatChannelData {
            let perChannel = buffer.format.isInterleaved ? frames * channels : frames
            let count = buffer.format.isInterleaved ? 1 : channels
            for c in 0..<count { dst[c].update(from: src[c], count: perChannel) }
            return out
        }
        return nil
    }
}
