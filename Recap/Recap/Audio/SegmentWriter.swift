import AVFoundation

/// 把音訊寫成一段一段的 m4a（AAC）。每滿 `segmentSeconds` 秒就換一個新檔。
final class SegmentWriter: AudioSink, @unchecked Sendable {
    struct Closed: Sendable {
        var relativePath: String
        var start: Date
        var end: Date
        var voicedSeconds: Double
    }

    /// 超過這個 RMS 視為有聲音（約 -40 dBFS）
    static let voiceThreshold: Float = 0.01

    private let lock = NSLock()
    private let segmentSeconds: Double
    private let tag: String
    private let root: URL
    private var file: AVAudioFile?
    private var relativePath = ""
    private var start = Date()
    private var frames: AVAudioFramePosition = 0
    private var sampleRate: Double = 48_000
    private var voiced: Double = 0
    private var low = false

    /// 省電時用較低的位元率（下一個檔案開始生效）
    var lowBitrate: Bool {
        get { lock.lock(); defer { lock.unlock() }; return low }
        set { lock.lock(); low = newValue; lock.unlock() }
    }

    /// 每段寫完時呼叫（任意執行緒）
    var onClosed: (@Sendable (Closed) -> Void)?

    init(root: URL, segmentSeconds: Double, tag: String) {
        self.root = root
        self.segmentSeconds = segmentSeconds
        self.tag = tag
    }

    func receive(_ buffer: AVAudioPCMBuffer, rms: Float) {
        var closed: [Closed] = []
        lock.lock()
        // 輸入格式變了（例如接上耳機）就換新檔
        if let file, file.processingFormat != buffer.format, let c = closeLocked() {
            closed.append(c)
        }
        if file == nil { openLocked(format: buffer.format) }
        if let file {
            do {
                try file.write(from: buffer)
                frames += AVAudioFramePosition(buffer.frameLength)
                if rms > Self.voiceThreshold { voiced += Double(buffer.frameLength) / sampleRate }
                if Double(frames) / sampleRate >= segmentSeconds, let c = closeLocked() {
                    closed.append(c)
                }
            } catch {
                appLog.error("寫入音檔失敗：\(error.localizedDescription)")
                self.file = nil
            }
        }
        lock.unlock()
        for c in closed { onClosed?(c) }
    }

    /// 結束目前這段（停止或中斷時呼叫）。
    func flush() {
        lock.lock()
        let closed = closeLocked()
        lock.unlock()
        if let closed { onClosed?(closed) }
    }

    var currentSegmentStart: Date? {
        lock.lock(); defer { lock.unlock() }
        return file == nil ? nil : start
    }

    private func openLocked(format: AVAudioFormat) {
        start = Date()
        frames = 0
        voiced = 0
        sampleRate = format.sampleRate
        relativePath = RecapStore.newAudioRelativePath(start: start, tag: tag)
        let url = root.appending(path: relativePath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let channels = format.channelCount
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: low ? (channels > 1 ? 48_000 : 32_000) : (channels > 1 ? 96_000 : 64_000),
        ]
        do {
            file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        } catch {
            appLog.error("建立音檔失敗：\(error.localizedDescription)")
            file = nil
        }
    }

    private func closeLocked() -> Closed? {
        guard file != nil else { return nil }
        file = nil // 釋放即關檔
        let seconds = Double(frames) / sampleRate
        frames = 0
        // 太短（< 2 秒）的段落直接丟掉
        if seconds < 2 {
            try? FileManager.default.removeItem(at: root.appending(path: relativePath))
            return nil
        }
        return Closed(relativePath: relativePath, start: start, end: start.addingTimeInterval(seconds), voicedSeconds: voiced)
    }
}
