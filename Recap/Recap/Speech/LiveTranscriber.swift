import AVFoundation
import Speech

/// 課堂模式：邊錄邊轉文字（會先給暫時結果，再給確定結果）。
final class LiveTranscriber: AudioSink, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzer: SpeechAnalyzer?
    private var format: AVAudioFormat?
    private let converter = BufferConverter()
    private var resultsTask: Task<Void, Never>?

    /// (文字, 是否為確定結果)；主執行緒呼叫
    var onResult: (@MainActor (String, Bool) -> Void)?

    func start(localeID: String, vocabulary: [String] = []) async throws {
        guard let locale = await SpeechSupport.resolve(localeID) else { throw RecapError.localeUnsupported(localeID) }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
        try await SpeechSupport.ensureAssets(for: [transcriber])
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        await SpeechSupport.applyVocabulary(vocabulary, to: analyzer)
        let handler = onResult
        resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    let isFinal = result.isFinal
                    await MainActor.run { handler?(text, isFinal) }
                }
            } catch {
                appLog.error("即時轉文字中止：\(error.localizedDescription)")
            }
        }
        try await analyzer.start(inputSequence: stream)
        install(format: format, continuation: continuation, analyzer: analyzer)
    }

    private func install(format: AVAudioFormat?, continuation: AsyncStream<AnalyzerInput>.Continuation, analyzer: SpeechAnalyzer) {
        lock.lock()
        self.format = format
        self.continuation = continuation
        self.analyzer = analyzer
        lock.unlock()
    }

    private func takeContinuation() -> (AsyncStream<AnalyzerInput>.Continuation?, SpeechAnalyzer?) {
        lock.lock()
        defer { lock.unlock() }
        let result = (continuation, analyzer)
        continuation = nil
        return result
    }

    func receive(_ buffer: AVAudioPCMBuffer, rms: Float) {
        lock.lock()
        let format = self.format
        let continuation = self.continuation
        lock.unlock()
        guard let continuation else { return }
        do {
            let converted = try format.map { try converter.convert(buffer, to: $0) } ?? buffer
            continuation.yield(AnalyzerInput(buffer: converted))
        } catch {
            appLog.error("轉換音訊失敗：\(error.localizedDescription)")
        }
    }

    /// 停止並等最後的結果出來。
    func finish() async {
        let (continuation, analyzer) = takeContinuation()
        continuation?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
    }
}
