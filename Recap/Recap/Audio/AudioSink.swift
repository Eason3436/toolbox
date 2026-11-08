import AVFoundation

/// 收到麥克風音訊的對象。`receive` 在音訊執行緒呼叫，不要做太久的事。
protocol AudioSink: AnyObject {
    func receive(_ buffer: AVAudioPCMBuffer, rms: Float)
}

/// 把音訊轉成指定格式（例如語音辨識要的取樣率）。
final class BufferConverter {
    private var converter: AVAudioConverter?

    func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let input = buffer.format
        if input == format { return buffer }
        if converter == nil || converter?.inputFormat != input || converter?.outputFormat != format {
            converter = AVAudioConverter(from: input, to: format)
            converter?.primeMethod = .none
        }
        guard let converter else { throw RecapError.conversionFailed }
        let ratio = format.sampleRate / input.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw RecapError.conversionFailed }
        var error: NSError?
        var consumed = false
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error { throw error ?? RecapError.conversionFailed }
        return output
    }
}

enum AudioLevel {
    /// 一個 buffer 的 RMS（0～1）。
    static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let frames = Int(buffer.frameLength)
        let samples = data[0]
        var sum: Float = 0
        for i in 0..<frames { sum += samples[i] * samples[i] }
        return (sum / Float(frames)).squareRoot()
    }

    /// 給介面用的 0～1（-60 dB ～ 0 dB）
    static func normalized(_ rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return max(0, min(1, (db + 60) / 60))
    }
}
