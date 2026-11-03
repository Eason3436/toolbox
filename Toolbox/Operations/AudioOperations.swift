import Foundation
import AVFoundation
import CoreMedia

enum AudioFormat: String, CaseIterable, Sendable {
    case m4a, alac, wav, aiff, caf

    var ext: String {
        switch self {
        case .m4a, .alac: return "m4a"
        case .wav: return "wav"
        case .aiff: return "aiff"
        case .caf: return "caf"
        }
    }

    var fileType: AVFileType {
        switch self {
        case .m4a, .alac: return .m4a
        case .wav: return .wav
        case .aiff: return .aiff
        case .caf: return .caf
        }
    }

    static let options: [(String, String)] = [
        ("m4a", "M4A（AAC）"), ("alac", "M4A（Apple 無損）"), ("wav", "WAV"), ("aiff", "AIFF"), ("caf", "CAF"),
    ]

    /// 切割時盡量沿用原格式；無法輸出的格式（例如 MP3）改成 M4A。
    static func sameAs(_ url: URL) -> AudioFormat {
        switch url.pathExtension.lowercased() {
        case "wav": return .wav
        case "aif", "aiff": return .aiff
        case "caf": return .caf
        default: return .m4a
        }
    }
}

private final class FinishFlag: @unchecked Sendable {
    var done = false
}

enum AudioEngine {
    /// 用 AVAssetReader／AVAssetWriter 轉成指定格式，可選取時間範圍。
    static func transcode(_ input: URL, to output: URL, format: AudioFormat, bitrate: Int = 192_000,
                          sampleRate: Double? = nil, channels: Int? = nil,
                          timeRange: CMTimeRange? = nil) async throws {
        let asset = AVURLAsset(url: input)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ToolError("這個檔案沒有音訊：\(input.lastPathComponent)")
        }

        var sourceRate = 44_100.0
        var sourceChannels = 2
        let descriptions = try await track.load(.formatDescriptions)
        if let first = descriptions.first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(first)?.pointee {
            if asbd.mSampleRate > 0 { sourceRate = asbd.mSampleRate }
            if asbd.mChannelsPerFrame > 0 { sourceChannels = Int(asbd.mChannelsPerFrame) }
        }

        var rate = sampleRate ?? sourceRate
        let channelCount = Swift.min(Swift.max(channels ?? sourceChannels, 1), 2)
        if format == .m4a { rate = Swift.min(rate, 48_000) }

        let reader = try AVAssetReader(asset: asset)
        if let timeRange { reader.timeRange = timeRange }
        let readerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: readerSettings)
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else { throw ToolError("無法讀取音訊") }
        reader.add(readerOutput)

        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: format.fileType)
        let writerSettings: [String: Any]
        switch format {
        case .m4a:
            var safeBitrate = bitrate
            if channelCount == 1 { safeBitrate = Swift.min(safeBitrate, 160_000) }
            if rate < 32_000 { safeBitrate = Swift.min(safeBitrate, 64_000 * channelCount) }
            writerSettings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: channelCount,
                AVEncoderBitRateKey: safeBitrate,
            ]
        case .alac:
            writerSettings = [
                AVFormatIDKey: kAudioFormatAppleLossless,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: channelCount,
                AVEncoderBitDepthHintKey: 16,
            ]
        case .wav, .aiff, .caf:
            writerSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: format == .aiff,
                AVLinearPCMIsNonInterleaved: false,
            ]
        }
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: writerSettings)
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else { throw ToolError("不支援這個輸出設定") }
        writer.add(writerInput)

        guard reader.startReading() else {
            throw ToolError("讀取失敗：\(reader.error?.localizedDescription ?? "")")
        }
        guard writer.startWriting() else {
            throw ToolError("寫入失敗：\(writer.error?.localizedDescription ?? "")")
        }
        writer.startSession(atSourceTime: timeRange?.start ?? .zero)

        let queue = DispatchQueue(label: "toolbox.audio.transcode")
        let flag = FinishFlag()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writerInput.requestMediaDataWhenReady(on: queue) {
                guard !flag.done else { return }
                while writerInput.isReadyForMoreMediaData {
                    if let buffer = readerOutput.copyNextSampleBuffer() {
                        if !writerInput.append(buffer) {
                            reader.cancelReading()
                            break
                        }
                    } else {
                        writerInput.markAsFinished()
                        flag.done = true
                        continuation.resume()
                        return
                    }
                }
                if writer.status == .failed && !flag.done {
                    flag.done = true
                    continuation.resume()
                }
            }
        }
        if writer.status == .writing {
            await writer.finishWriting()
        }
        if writer.status != .completed {
            throw ToolError("音訊轉檔失敗：\(writer.error?.localizedDescription ?? "未知錯誤")")
        }
        if reader.status == .failed {
            throw ToolError("音訊讀取失敗：\(reader.error?.localizedDescription ?? "未知錯誤")")
        }
    }

    /// 剪下一段。M4A／MP4 音訊直接複製不重新編碼，其他格式轉成 sameAs 的格式。
    static func cut(_ input: URL, to output: URL, range: CMTimeRange) async throws {
        let ext = input.pathExtension.lowercased()
        if ["m4a", "mp4", "aac"].contains(ext) && output.pathExtension.lowercased() == "m4a" {
            do {
                try? FileManager.default.removeItem(at: output)
                try await MediaExport.export(AVURLAsset(url: input), to: output,
                                             preset: AVAssetExportPresetPassthrough, fileType: .m4a, timeRange: range)
                return
            } catch {
                // 有些檔案不支援直接複製，改走重新編碼。
            }
        }
        let format = AudioFormat.sameAs(output)
        try await transcode(input, to: output, format: format, bitrate: 256_000, timeRange: range)
    }
}

private let bitrateOptions: [(String, String)] = [
    ("64", "64 kbps"), ("96", "96 kbps"), ("128", "128 kbps"), ("192", "192 kbps"), ("256", "256 kbps"), ("320", "320 kbps"),
]

// MARK: - 轉檔

struct AudioConvertOp: ToolOperation {
    let id = "audio.convert"
    let title = "轉檔"
    let subtitle = "M4A、無損 ALAC、WAV、AIFF、CAF"
    let systemImage = "arrow.triangle.2.circlepath"
    let accepts: Set<FileKind> = [.audio, .video]
    var parameters: [ParameterSpec] {
        [
            .choice("format", "轉成", AudioFormat.options, default: "m4a"),
            .choice("bitrate", "位元率", bitrateOptions, default: "256", showIf: ["format": "m4a"]),
            .choice("sampleRate", "取樣率", [("source", "與原檔相同"), ("44100", "44.1 kHz"), ("48000", "48 kHz"),
                                             ("22050", "22.05 kHz")], default: "source"),
            .choice("channels", "聲道", [("source", "與原檔相同"), ("2", "立體聲"), ("1", "單聲道")], default: "source"),
        ]
    }

    func isAvailable(for kinds: [FileKind]) -> Bool {
        !kinds.isEmpty && kinds.allSatisfy { $0 == .audio }
    }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        let format = AudioFormat(rawValue: params.string("format", "m4a")) ?? .m4a
        let rate = Double(params.string("sampleRate", "source"))
        let channels = Int(params.string("channels", "source"))
        let bitrate = (Int(params.string("bitrate", "256")) ?? 256) * 1000
        return try await eachInput(inputs, context) { input in
            let out = context.output(for: input, suffix: format == .alac ? "_alac" : "", ext: format.ext)
            try await AudioEngine.transcode(input, to: out, format: format, bitrate: bitrate,
                                            sampleRate: rate, channels: channels)
            return [out]
        }
    }
}

// MARK: - 壓縮

struct AudioCompressOp: ToolOperation {
    let id = "audio.compress"
    let title = "壓縮"
    let subtitle = "轉成較低位元率的 M4A"
    let systemImage = "arrow.down.right.and.arrow.up.left"
    let accepts: Set<FileKind> = [.audio]
    var parameters: [ParameterSpec] {
        [
            .choice("bitrate", "位元率", Array(bitrateOptions.prefix(4)), default: "96",
                    footer: "語音 64 kbps 就夠，音樂建議 128 kbps 以上。"),
            .toggle("mono", "轉成單聲道（再小一半）", default: false),
        ]
    }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        let bitrate = (Int(params.string("bitrate", "96")) ?? 96) * 1000
        let mono = params.bool("mono", false)
        return try await eachInput(inputs, context) { input in
            let out = context.output(for: input, suffix: "_small", ext: "m4a")
            try await AudioEngine.transcode(input, to: out, format: .m4a, bitrate: bitrate, channels: mono ? 1 : nil)
            return [out]
        }
    }
}

// MARK: - 切割

struct AudioSplitOp: ToolOperation {
    let id = "audio.split"
    let title = "切割"
    let subtitle = "在指定時間切開、平均分段或固定長度"
    let systemImage = "scissors"
    let accepts: Set<FileKind> = [.audio]
    var parameters: [ParameterSpec] {
        [
            .choice("mode", "方式", [("points", "在指定時間切開"), ("parts", "平均分成幾段"), ("length", "每段固定長度")],
                    default: "points"),
            .text("points", "切點", default: "1:00", placeholder: "例如 1:00, 2:30",
                  footer: "一個時間點會切成兩段，多個時間點用逗號分開。", showIf: ["mode": "points"]),
            .number("parts", "段數", range: 2...50, step: 1, default: 2, unit: " 段", showIf: ["mode": "parts"]),
            .text("length", "每段長度", default: "1:00", placeholder: "例如 30 或 1:00", showIf: ["mode": "length"]),
        ]
    }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        try await eachInput(inputs, context) { input in
            let duration = try await MediaExport.duration(of: input)
            guard duration > 0 else { throw ToolError("讀不到音訊長度") }
            var cuts: [Double]
            switch params.string("mode", "points") {
            case "parts":
                let n = Swift.max(2, params.int("parts", 2))
                cuts = (1..<n).map { duration * Double($0) / Double(n) }
            case "length":
                guard let length = TimeText.seconds(params.string("length", "60")), length > 0 else {
                    throw ToolError("每段長度格式不正確")
                }
                cuts = Array(stride(from: length, to: duration, by: length))
            default:
                cuts = TimeText.list(params.string("points", ""))
            }
            cuts = cuts.filter { $0 > 0.05 && $0 < duration - 0.05 }
            guard !cuts.isEmpty else { throw ToolError("切點要在 0 到 \(TimeText.string(duration)) 之間") }

            let bounds = [0] + cuts + [duration]
            let ext = AudioFormat.sameAs(input).ext
            var outputs: [URL] = []
            for index in 0..<(bounds.count - 1) {
                context.report("輸出第 \(index + 1)/\(bounds.count - 1) 段")
                let out = context.output(for: input, suffix: String(format: "_%02d", index + 1), ext: ext)
                try await AudioEngine.cut(input, to: out, range: MediaExport.range(start: bounds[index], end: bounds[index + 1]))
                outputs.append(out)
            }
            return outputs
        }
    }
}

// MARK: - 合併

struct AudioMergeOp: ToolOperation {
    let id = "audio.merge"
    let title = "合併"
    let subtitle = "依目前順序接成一個檔案"
    let systemImage = "link"
    let accepts: Set<FileKind> = [.audio]
    let minInputs = 2
    var parameters: [ParameterSpec] {
        [.text("name", "檔名", default: "合併音訊", placeholder: "檔名")]
    }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ToolError("無法建立音軌")
        }
        var cursor = CMTime.zero
        for (index, input) in inputs.enumerated() {
            context.report("加入第 \(index + 1)/\(inputs.count) 個")
            let asset = AVURLAsset(url: input)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first else { continue }
            let duration = try await asset.load(.duration)
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: cursor)
            cursor = CMTimeAdd(cursor, duration)
        }
        let name = params.string("name", "合併音訊")
        let out = context.output(named: name.isEmpty ? "合併音訊" : name, ext: "m4a")
        context.report("輸出中")
        try await MediaExport.export(composition, to: out, preset: AVAssetExportPresetAppleM4A, fileType: .m4a)
        return [out]
    }
}

// MARK: - 鈴聲

struct AudioRingtoneOp: ToolOperation {
    let id = "audio.ringtone"
    let title = "做成鈴聲"
    let subtitle = "剪一段輸出成 M4R"
    let systemImage = "bell.badge"
    let accepts: Set<FileKind> = [.audio]
    var parameters: [ParameterSpec] {
        [
            .text("start", "開始時間", default: "0:00", placeholder: "0:00"),
            .number("length", "長度", range: 5...40, step: 1, default: 30, unit: " 秒",
                    footer: "iPhone 鈴聲最長 40 秒。存到「檔案」後可以用 GarageBand 設成鈴聲。"),
        ]
    }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        try await eachInput(inputs, context) { input in
            let duration = try await MediaExport.duration(of: input)
            let start = Swift.min(Swift.max(0, TimeText.seconds(params.string("start", "0")) ?? 0), Swift.max(0, duration - 1))
            let end = Swift.min(duration, start + params.double("length", 30))
            let temp = context.output(for: input, suffix: "_ringtone_tmp", ext: "m4a")
            try await AudioEngine.transcode(input, to: temp, format: .m4a, bitrate: 256_000,
                                            timeRange: MediaExport.range(start: start, end: end))
            let out = context.output(for: input, suffix: "_鈴聲", ext: "m4r")
            try FileManager.default.moveItem(at: temp, to: out)
            return [out]
        }
    }
}
