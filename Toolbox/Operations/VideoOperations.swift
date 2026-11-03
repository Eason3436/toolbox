import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

enum MediaExport {
    static func export(_ asset: AVAsset, to output: URL, preset: String, fileType: AVFileType,
                       timeRange: CMTimeRange? = nil) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ToolError("無法建立匯出工作（\(preset)）")
        }
        if let timeRange { session.timeRange = timeRange }
        session.shouldOptimizeForNetworkUse = true
        var monitor: Task<Void, Never>?
        if let reporter = ProgressScope.report {
            monitor = Task {
                for await state in session.states(updateInterval: 0.5) {
                    if case .exporting(let progress) = state { reporter(progress.fractionCompleted) }
                }
            }
        }
        defer { monitor?.cancel() }
        try await session.export(to: output, as: fileType)
    }

    static func duration(of url: URL) async throws -> Double {
        try await AVURLAsset(url: url).load(.duration).seconds
    }

    static func fileType(forExtension ext: String) -> AVFileType {
        switch ext.lowercased() {
        case "mov": return .mov
        case "m4v": return .m4v
        case "m4a": return .m4a
        default: return .mp4
        }
    }

    static func range(start: Double, end: Double) -> CMTimeRange {
        CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                    end: CMTime(seconds: end, preferredTimescale: 600))
    }
}

private let videoFormatOptions: [(String, String)] = [("mp4", "MP4"), ("mov", "MOV"), ("m4v", "M4V")]

// MARK: - 壓縮

struct VideoCompressOp: ToolOperation {
    let id = "video.compress"
    let title = "壓縮"
    let subtitle = "降低解析度與位元率，適合傳 LINE、Email"
    let systemImage = "arrow.down.right.and.arrow.up.left"
    let accepts: Set<FileKind> = [.video]
    var parameters: [ParameterSpec] {
        [
            .choice("quality", "解析度", [("2160", "4K"), ("1080", "1080p"), ("720", "720p"), ("540", "540p"),
                                         ("low", "最小（畫質較差）")], default: "720"),
            .choice("codec", "編碼", [("hevc", "HEVC（較小）"), ("h264", "H.264（相容性最好）")], default: "hevc",
                    footer: "720p 以下只能使用 H.264。", showIf: ["quality": "2160|1080"]),
            .choice("format", "格式", videoFormatOptions, default: "mp4"),
        ]
    }

    static func preset(quality: String, hevc: Bool) -> String {
        switch quality {
        case "2160": return hevc ? AVAssetExportPresetHEVC3840x2160 : AVAssetExportPreset3840x2160
        case "1080": return hevc ? AVAssetExportPresetHEVC1920x1080 : AVAssetExportPreset1920x1080
        case "720": return AVAssetExportPreset1280x720
        case "540": return AVAssetExportPreset960x540
        default: return AVAssetExportPresetLowQuality
        }
    }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        let preset = Self.preset(quality: params.string("quality", "720"), hevc: params.string("codec", "hevc") == "hevc")
        let ext = params.string("format", "mp4")
        return try await eachInput(inputs, context) { input in
            let out = context.output(for: input, suffix: "_small", ext: ext)
            try await MediaExport.export(AVURLAsset(url: input), to: out, preset: preset,
                                         fileType: MediaExport.fileType(forExtension: ext))
            return [out]
        }
    }
}

// MARK: - 轉檔

struct VideoConvertOp: ToolOperation {
    let id = "video.convert"
    let title = "轉檔"
    let subtitle = "MP4、MOV、M4V，畫質不變"
    let systemImage = "arrow.triangle.2.circlepath"
    let accepts: Set<FileKind> = [.video]
    var parameters: [ParameterSpec] {
        [
            .choice("format", "轉成", videoFormatOptions, default: "mp4"),
            .choice("codec", "編碼", [("h264", "H.264（相容性最好）"), ("hevc", "HEVC（較小）")], default: "h264"),
        ]
    }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        let ext = params.string("format", "mp4")
        let preset = params.string("codec", "h264") == "hevc"
            ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
        return try await eachInput(inputs, context) { input in
            let out = context.output(for: input, ext: ext)
            try await MediaExport.export(AVURLAsset(url: input), to: out, preset: preset,
                                         fileType: MediaExport.fileType(forExtension: ext))
            return [out]
        }
    }
}

// MARK: - 剪輯

struct VideoTrimOp: ToolOperation {
    let id = "video.trim"
    let title = "剪頭去尾"
    let subtitle = "保留指定時間範圍，不重新壓縮"
    let systemImage = "timeline.selection"
    let accepts: Set<FileKind> = [.video]
    var parameters: [ParameterSpec] {
        [
            .text("start", "開始時間", default: "0:00", placeholder: "0:00"),
            .text("end", "結束時間", default: "", placeholder: "留空 = 到結尾",
                  footer: "時間可以寫成 90、1:30 或 1:02:03。"),
        ]
    }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        try await eachInput(inputs, context) { input in
            let duration = try await MediaExport.duration(of: input)
            let start = Swift.max(0, TimeText.seconds(params.string("start", "0")) ?? 0)
            let end = Swift.min(duration, TimeText.seconds(params.string("end", "")) ?? duration)
            guard end > start else { throw ToolError("結束時間要晚於開始時間") }
            let ext = ["mov", "mp4", "m4v"].contains(input.pathExtension.lowercased()) ? input.pathExtension.lowercased() : "mov"
            let out = context.output(for: input, suffix: "_trim", ext: ext)
            try await MediaExport.export(AVURLAsset(url: input), to: out, preset: AVAssetExportPresetPassthrough,
                                         fileType: MediaExport.fileType(forExtension: ext),
                                         timeRange: MediaExport.range(start: start, end: end))
            return [out]
        }
    }
}

// MARK: - 擷取音訊

struct VideoExtractAudioOp: ToolOperation {
    let id = "video.extractAudio"
    let title = "擷取音訊"
    let subtitle = "把影片的聲音存成音訊檔"
    let systemImage = "waveform.badge.plus"
    let accepts: Set<FileKind> = [.video]
    var parameters: [ParameterSpec] {
        [
            .choice("format", "格式", [("m4a", "M4A（AAC）"), ("wav", "WAV（無損）")], default: "m4a"),
            .choice("bitrate", "位元率", [("128", "128 kbps"), ("192", "192 kbps"), ("256", "256 kbps")],
                    default: "192", showIf: ["format": "m4a"]),
        ]
    }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        let format = AudioFormat(rawValue: params.string("format", "m4a")) ?? .m4a
        return try await eachInput(inputs, context) { input in
            let out = context.output(for: input, ext: format.ext)
            try await AudioEngine.transcode(input, to: out, format: format,
                                            bitrate: (Int(params.string("bitrate", "192")) ?? 192) * 1000)
            return [out]
        }
    }
}

// MARK: - 轉 GIF

struct VideoToGIFOp: ToolOperation {
    let id = "video.toGIF"
    let title = "轉 GIF"
    let subtitle = "擷取一段做成動圖"
    let systemImage = "photo.stack"
    let accepts: Set<FileKind> = [.video]
    var parameters: [ParameterSpec] {
        [
            .text("start", "開始時間", default: "0:00", placeholder: "0:00"),
            .number("length", "長度", range: 1...15, step: 1, default: 4, unit: " 秒"),
            .choice("fps", "每秒張數", [("8", "8"), ("10", "10"), ("15", "15"), ("20", "20")], default: "10"),
            .choice("width", "寬度", [("320", "320 px"), ("480", "480 px"), ("640", "640 px")], default: "480"),
        ]
    }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        let fps = Double(params.string("fps", "10")) ?? 10
        let width = Double(params.string("width", "480")) ?? 480
        return try await eachInput(inputs, context) { input in
            let asset = AVURLAsset(url: input)
            let duration = try await asset.load(.duration).seconds
            let start = Swift.min(Swift.max(0, TimeText.seconds(params.string("start", "0")) ?? 0), Swift.max(0, duration - 0.1))
            let length = Swift.min(params.double("length", 4), duration - start)
            let count = Swift.max(1, Int(length * fps))

            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: width, height: width * 4)
            let tolerance = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
            generator.requestedTimeToleranceBefore = tolerance
            generator.requestedTimeToleranceAfter = tolerance

            let times = (0..<count).map { CMTime(seconds: start + Double($0) / fps, preferredTimescale: 600) }
            var frames: [CGImage] = []
            for await result in generator.images(for: times) {
                if let image = try? result.image { frames.append(image) }
            }
            guard !frames.isEmpty else { throw ToolError("讀不到影片畫面") }

            let out = context.output(for: input, ext: "gif")
            guard let destination = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString,
                                                                    frames.count, nil) else {
                throw ToolError("無法建立 GIF")
            }
            let fileProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
            CGImageDestinationSetProperties(destination, fileProperties)
            let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / fps]] as CFDictionary
            for frame in frames { CGImageDestinationAddImage(destination, frame, frameProperties) }
            guard CGImageDestinationFinalize(destination) else { throw ToolError("GIF 寫入失敗") }
            return [out]
        }
    }
}
