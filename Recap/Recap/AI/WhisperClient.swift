import AVFoundation
import Foundation

enum WhisperError: LocalizedError {
    case badKey
    case quota
    case tooLarge
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .badKey: "Groq API Key 無效，請到設定重新貼上。"
        case .quota: "Groq 今天的免費額度用完了，明天再補強。"
        case .tooLarge: "音檔太大（超過 25 MB），已略過。"
        case .server(let code, let message): "Groq 錯誤 \(code)：\(message)"
        }
    }
}

/// Groq 的 Whisper 語音轉文字（OpenAI 相容 API）。只拿來補強 AI 判斷辨識得不好的段落。
enum GroqWhisper {
    static let models: [(id: String, title: String, detail: String)] = [
        ("whisper-large-v3", "Whisper Large v3（推薦）", "最準，中英夾雜與專有名詞最好。"),
        ("whisper-large-v3-turbo", "Whisper Large v3 Turbo", "比較快，準確度略低。"),
    ]
    static let defaultModel = "whisper-large-v3"

    private static let endpoint = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!

    /// 回傳（音檔內的秒數, 文字）
    static func transcribe(url: URL, language: String?, prompt: String, model: String, apiKey: String) async throws -> [(TimeInterval, String)] {
        let audio = try Data(contentsOf: url)
        guard audio.count < 25_000_000 else { throw WhisperError.tooLarge }
        let boundary = "Recap-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", model)
        field("response_format", "verbose_json")
        field("temperature", "0")
        if let language { field("language", language) }
        if !prompt.isEmpty { field("prompt", prompt) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(url.lastPathComponent)\"\r\nContent-Type: audio/mp4\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        var attempt = 0
        while true {
            try Task.checkCancellation()
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 { return parse(data) }
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? String(data: data.prefix(300), encoding: .utf8) ?? ""
            if status >= 500, attempt < 2 {
                attempt += 1
                try await Task.sleep(for: .seconds(5 * attempt))
                continue
            }
            switch status {
            case 401, 403: throw WhisperError.badKey
            case 413: throw WhisperError.tooLarge
            case 429: throw WhisperError.quota
            default: throw WhisperError.server(status, message)
            }
        }
    }

    private static func parse(_ data: Data) -> [(TimeInterval, String)] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        if let segments = json["segments"] as? [[String: Any]], !segments.isEmpty {
            return segments.compactMap { seg in
                guard let text = (seg["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
                let start = (seg["start"] as? Double) ?? (seg["start"] as? NSNumber)?.doubleValue ?? 0
                return (start, traditional(text))
            }
        }
        let text = (json["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? [] : [(0, traditional(text))]
    }

    /// Whisper 的中文常輸出簡體，轉成繁體
    static func traditional(_ text: String) -> String {
        text.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? text
    }

    /// 用一小段靜音測 Key（Groq 最少算 10 秒）
    static func testKey(_ apiKey: String, model: String) async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "recap-key-test.m4a")
        try await AudioClipper.writeSilence(to: url, seconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try await transcribe(url: url, language: "zh", prompt: "", model: model, apiKey: apiKey)
    }
}

/// 每天的 Groq 用量（秒）。Groq 每個請求最少算 10 秒。
enum WhisperBudget {
    private static let defaults = UserDefaults.standard

    static var usedToday: TimeInterval {
        defaults.string(forKey: "whisperUsageDay") == DayKey.today ? defaults.double(forKey: "whisperUsageSeconds") : 0
    }

    static func remaining(limitMinutes: Int) -> TimeInterval {
        max(0, TimeInterval(limitMinutes * 60) - usedToday)
    }

    static func cost(of seconds: TimeInterval) -> TimeInterval { max(10, seconds.rounded(.up)) }

    static func spend(_ seconds: TimeInterval) {
        let used = usedToday + cost(of: seconds)
        defaults.set(DayKey.today, forKey: "whisperUsageDay")
        defaults.set(used, forKey: "whisperUsageSeconds")
    }

    /// Groq 回 429：今天就當用完
    static func exhaust(limitMinutes: Int) {
        defaults.set(DayKey.today, forKey: "whisperUsageDay")
        defaults.set(TimeInterval(limitMinutes * 60), forKey: "whisperUsageSeconds")
    }
}

/// 從音檔切出一段，送去重新辨識。
enum AudioClipper {
    static func clip(_ url: URL, from start: TimeInterval, duration: TimeInterval) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw WhisperError.server(0, "無法切割音檔")
        }
        let out = FileManager.default.temporaryDirectory.appending(path: "recap-clip-\(UUID().uuidString).m4a")
        session.timeRange = CMTimeRange(start: CMTime(seconds: max(0, start), preferredTimescale: 600), duration: CMTime(seconds: duration, preferredTimescale: 600))
        try await session.export(to: out, as: .m4a)
        return out
    }

    static func duration(of url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        guard let time = try? await asset.load(.duration) else { return 0 }
        return time.seconds.isFinite ? time.seconds : 0
    }

    static func writeSilence(to url: URL, seconds: Double) async throws {
        try? FileManager.default.removeItem(at: url)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000,
        ])
        let frames = AVAudioFrameCount(16_000 * seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        try file.write(from: buffer)
    }
}
