import Foundation
import AVFoundation
import CoreImage
import ImageIO
import UIKit
import UniformTypeIdentifiers
import Vision
import Speech

// MARK: - 圖片：旋轉／翻轉

struct ImageRotateOp: ToolOperation {
    let id = "image.rotate"
    let title = "旋轉與翻轉"
    let subtitle = "轉 90°、180°，或左右、上下翻轉"
    let systemImage = "rotate.right"
    let accepts: Set<FileKind> = [.image]
    var parameters: [ParameterSpec] {
        [
            .choice("turn", "方式", [("cw", "向右 90°"), ("ccw", "向左 90°"), ("180", "180°"),
                                    ("flipH", "左右翻轉"), ("flipV", "上下翻轉")], default: "cw"),
            .number("quality", "品質", range: 10...100, step: 5, default: 95, unit: "%"),
        ]
    }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        let orientation: CGImagePropertyOrientation
        switch params.string("turn", "cw") {
        case "ccw": orientation = .left
        case "180": orientation = .down
        case "flipH": orientation = .upMirrored
        case "flipV": orientation = .downMirrored
        default: orientation = .right
        }
        return try await eachInput(inputs, context) { input in
            let loaded = try ImageEngine.load(input)
            let ci = CIImage(cgImage: loaded.image).oriented(orientation)
            guard let rotated = ImageFilters.context.createCGImage(ci, from: ci.extent) else { throw ToolError("旋轉失敗") }
            let format = ImageFormat.resolve("same", for: input)
            let out = context.output(for: input, suffix: "_rotated", ext: format.ext)
            try ImageEngine.write(rotated, to: out, format: format, quality: params.double("quality", 95) / 100,
                                  metadata: loaded.properties)
            return [out]
        }
    }
}

enum ImageFilters {
    static let context = CIContext(options: [.useSoftwareRenderer: false])
}

// MARK: - 圖片：濾鏡

struct ImageFilterOp: ToolOperation {
    let id = "image.filter"
    let title = "黑白與濾鏡"
    let subtitle = "黑白、單色、懷舊、褪色、鉻黃"
    let systemImage = "camera.filters"
    let accepts: Set<FileKind> = [.image]
    var parameters: [ParameterSpec] {
        [
            .choice("filter", "濾鏡", [("CIPhotoEffectNoir", "黑白（高對比）"), ("CIPhotoEffectMono", "黑白（柔和）"),
                                     ("CIPhotoEffectTonal", "灰階"), ("CIPhotoEffectTransfer", "懷舊"),
                                     ("CIPhotoEffectFade", "褪色"), ("CIPhotoEffectChrome", "鉻黃"),
                                     ("CIPhotoEffectInstant", "拍立得")], default: "CIPhotoEffectNoir"),
            .number("quality", "品質", range: 10...100, step: 5, default: 92, unit: "%"),
        ]
    }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        let name = params.string("filter", "CIPhotoEffectNoir")
        return try await eachInput(inputs, context) { input in
            let loaded = try ImageEngine.load(input)
            guard let filter = CIFilter(name: name) else { throw ToolError("找不到濾鏡") }
            filter.setValue(CIImage(cgImage: loaded.image), forKey: kCIInputImageKey)
            guard let output = filter.outputImage,
                  let image = ImageFilters.context.createCGImage(output, from: output.extent) else { throw ToolError("套用濾鏡失敗") }
            let format = ImageFormat.resolve("same", for: input)
            let out = context.output(for: input, suffix: "_filter", ext: format.ext)
            try ImageEngine.write(image, to: out, format: format, quality: params.double("quality", 92) / 100,
                                  metadata: loaded.properties)
            return [out]
        }
    }
}

// MARK: - 圖片：拼接

struct ImageStitchOp: ToolOperation {
    let id = "image.stitch"
    let title = "拼成長圖"
    let subtitle = "依目前順序上下或左右拼接"
    let systemImage = "rectangle.split.1x2"
    let accepts: Set<FileKind> = [.image]
    let minInputs = 2
    var parameters: [ParameterSpec] {
        [
            .choice("direction", "方向", [("vertical", "上下"), ("horizontal", "左右")], default: "vertical"),
            .number("gap", "間距", range: 0...80, step: 4, default: 0, unit: " px"),
            .choice("background", "間距顏色", [("white", "白"), ("black", "黑")], default: "white"),
            .choice("format", "格式", [("jpg", "JPG"), ("png", "PNG"), ("heic", "HEIC")], default: "jpg"),
        ]
    }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        let vertical = params.string("direction", "vertical") == "vertical"
        let gap = CGFloat(params.double("gap", 0))
        var images: [CGImage] = []
        for (index, input) in inputs.enumerated() {
            context.report("讀取 \(index + 1)/\(inputs.count)")
            images.append(try ImageEngine.load(input, maxPixel: 4096).image)
        }
        // 統一寬度（上下拼）或高度（左右拼），取最小值避免放大。
        let side = CGFloat(images.map { vertical ? $0.width : $0.height }.min() ?? 1000)
        let sizes = images.map { image -> CGSize in
            let w = CGFloat(image.width), h = CGFloat(image.height)
            return vertical ? CGSize(width: side, height: (h * side / w).rounded()) : CGSize(width: (w * side / h).rounded(), height: side)
        }
        let total = sizes.reduce(0) { $0 + (vertical ? $1.height : $1.width) } + gap * CGFloat(images.count - 1)
        let canvas = vertical ? CGSize(width: side, height: total) : CGSize(width: total, height: side)
        guard canvas.width * canvas.height < 400_000_000 else { throw ToolError("拼起來太大了，試著減少張數") }
        guard let ctx = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ToolError("記憶體不足") }
        ctx.setFillColor(params.string("background", "white") == "black" ? UIColor.black.cgColor : UIColor.white.cgColor)
        ctx.fill(CGRect(origin: .zero, size: canvas))
        ctx.interpolationQuality = .high
        var offset: CGFloat = 0
        for (image, size) in zip(images, sizes) {
            let rect = vertical
                ? CGRect(x: 0, y: canvas.height - offset - size.height, width: size.width, height: size.height)
                : CGRect(x: offset, y: 0, width: size.width, height: size.height)
            ctx.draw(image, in: rect)
            offset += (vertical ? size.height : size.width) + gap
        }
        guard let result = ctx.makeImage() else { throw ToolError("拼接失敗") }
        let format = ImageFormat(rawValue: params.string("format", "jpg")) ?? .jpg
        let out = context.output(named: "拼接", ext: format.ext)
        try ImageEngine.write(result, to: out, format: format, quality: 0.9, metadata: nil)
        return [out]
    }
}

// MARK: - 圖片：做成動圖

struct ImagesToGIFOp: ToolOperation {
    let id = "image.toGIF"
    let title = "做成動圖"
    let subtitle = "依目前順序輪播，輸出 GIF"
    let systemImage = "photo.stack"
    let accepts: Set<FileKind> = [.image]
    let minInputs = 2
    var parameters: [ParameterSpec] {
        [
            .number("delay", "每張停留", range: 0.1...3, step: 0.1, default: 0.5, unit: " 秒"),
            .choice("width", "寬度", [("480", "480 px"), ("720", "720 px"), ("1080", "1080 px")], default: "720"),
            .toggle("loop", "無限重播", default: true),
        ]
    }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        let out = context.output(named: "動圖", ext: "gif")
        guard let destination = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, inputs.count, nil) else {
            throw ToolError("無法建立 GIF")
        }
        let loop: [CFString: Any] = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: params.bool("loop", true) ? 0 : 1]]
        CGImageDestinationSetProperties(destination, loop as CFDictionary)
        let frame: [CFString: Any] = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: params.double("delay", 0.5)]]
        for (index, input) in inputs.enumerated() {
            try Task.checkCancellation()
            context.report("第 \(index + 1)/\(inputs.count) 張")
            ProgressScope.report?(Double(index) / Double(inputs.count))
            let image = try ImageEngine.load(input, maxPixel: params.int("width", 720)).image
            CGImageDestinationAddImage(destination, image, frame as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw ToolError("GIF 輸出失敗") }
        return [out]
    }
}

// MARK: - 圖片：辨識文字

struct ImageOCROp: ToolOperation {
    let id = "image.ocr"
    let title = "辨識文字"
    let subtitle = "把照片、截圖裡的字轉成可以複製的文字"
    let systemImage = "text.viewfinder"
    let accepts: Set<FileKind> = [.image]
    var parameters: [ParameterSpec] {
        [
            .choice("language", "主要語言", [("zh-Hant", "繁中"), ("zh-Hans", "簡中"), ("en-US", "英文"), ("ja-JP", "日文")],
                    default: "zh-Hant"),
            .toggle("merge", "全部合成一個檔", default: true),
        ]
    }

    static func recognize(_ image: CGImage, language: String) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = [language, "en-US"]
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let observations = (request.results ?? []).sorted {
            abs($0.boundingBox.midY - $1.boundingBox.midY) < 0.01 ? $0.boundingBox.minX < $1.boundingBox.minX
                : $0.boundingBox.midY > $1.boundingBox.midY
        }
        return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        let language = params.string("language", "zh-Hant")
        let merge = params.bool("merge", true) && inputs.count > 1
        var texts: [(URL, String)] = []
        let _ = try await eachInput(inputs, context) { input in
            let text = try Self.recognize(try ImageEngine.load(input, maxPixel: 4096).image, language: language)
            texts.append((input, text))
            return []
        }
        guard texts.contains(where: { !$0.1.isEmpty }) else { throw ToolError("沒有找到文字") }
        if merge {
            let out = context.output(named: "辨識文字", ext: "txt")
            try TextIO.write(texts.map { "# \($0.0.lastPathComponent)\n\n\($0.1)" }.joined(separator: "\n\n"), to: out)
            return [out]
        }
        return try texts.map { input, text in
            let out = context.output(for: input, ext: "txt")
            try TextIO.write(text, to: out)
            return out
        }
    }
}

// MARK: - 圖片：去背

struct ImageRemoveBackgroundOp: ToolOperation {
    let id = "image.removeBackground"
    let title = "去背"
    let subtitle = "自動找出主體，輸出透明背景 PNG"
    let systemImage = "person.crop.rectangle"
    let accepts: Set<FileKind> = [.image]
    var parameters: [ParameterSpec] {
        [.toggle("crop", "裁到主體範圍", default: true)]
    }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        let crop = params.bool("crop", true)
        return try await eachInput(inputs, context) { input in
            let image = try ImageEngine.load(input, maxPixel: 4096).image
            let request = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try handler.perform([request])
            guard let result = request.results?.first, !result.allInstances.isEmpty else {
                throw ToolError("\(input.lastPathComponent) 找不到明顯的主體")
            }
            let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler,
                                                        croppedToInstancesExtent: crop)
            let ci = CIImage(cvPixelBuffer: buffer)
            guard let masked = ImageFilters.context.createCGImage(ci, from: ci.extent) else { throw ToolError("去背失敗") }
            let out = context.output(for: input, suffix: "_去背", ext: "png")
            try ImageEngine.write(masked, to: out, format: .png, quality: 1, metadata: nil)
            return [out]
        }
    }
}

// MARK: - 圖片：掃描 QR Code

struct ImageBarcodeOp: ToolOperation {
    let id = "image.barcode"
    let title = "讀取 QR Code"
    let subtitle = "找出圖片裡的 QR Code、條碼內容"
    let systemImage = "qrcode.viewfinder"
    let accepts: Set<FileKind> = [.image]
    var parameters: [ParameterSpec] { [] }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        var lines: [String] = []
        let _ = try await eachInput(inputs, context) { input in
            let request = VNDetectBarcodesRequest()
            try VNImageRequestHandler(cgImage: try ImageEngine.load(input, maxPixel: 3000).image, options: [:]).perform([request])
            let payloads = (request.results ?? []).compactMap(\.payloadStringValue)
            for payload in Array(NSOrderedSet(array: payloads)) as? [String] ?? payloads {
                lines.append(inputs.count > 1 ? "\(input.lastPathComponent)：\(payload)" : payload)
            }
            return []
        }
        guard !lines.isEmpty else { throw ToolError("沒有找到 QR Code 或條碼") }
        let out = context.output(named: "QR Code 內容", ext: "txt")
        try TextIO.write(lines.joined(separator: "\n"), to: out)
        return [out]
    }
}

// MARK: - 圖片：浮水印

struct ImageWatermarkOp: ToolOperation {
    let id = "image.watermark"
    let title = "加浮水印"
    let subtitle = "例如證件影本加上「僅供某某用途使用」"
    let systemImage = "signature"
    let accepts: Set<FileKind> = [.image]
    var parameters: [ParameterSpec] {
        [
            .text("text", "文字", default: "僅供申請使用", placeholder: "浮水印文字"),
            .choice("layout", "位置", [("tile", "斜向滿版"), ("center", "中央"), ("corner", "右下角")], default: "tile"),
            .number("opacity", "不透明度", range: 10...90, step: 5, default: 35, unit: "%"),
            .number("size", "字級", range: 2...12, step: 1, default: 5, unit: "%", footer: "相對於圖片寬度。"),
            .choice("color", "顏色", [("gray", "灰"), ("white", "白"), ("red", "紅")], default: "gray"),
        ]
    }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        let text = params.string("text", "僅供申請使用")
        guard !text.isEmpty else { throw ToolError("請輸入浮水印文字") }
        let layout = params.string("layout", "tile")
        let opacity = params.double("opacity", 35) / 100
        let colors: [String: UIColor] = ["white": .white, "red": .systemRed, "gray": .darkGray]
        let base = colors[params.string("color", "gray")] ?? .darkGray
        return try await eachInput(inputs, context) { input in
            let loaded = try ImageEngine.load(input)
            let size = CGSize(width: loaded.image.width, height: loaded.image.height)
            let fontSize = size.width * params.double("size", 5) / 100
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: base.withAlphaComponent(opacity),
            ]
            let string = NSAttributedString(string: text, attributes: attributes)
            let textSize = string.size()
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let rendered = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
                UIImage(cgImage: loaded.image).draw(in: CGRect(origin: .zero, size: size))
                let cg = ctx.cgContext
                switch layout {
                case "corner":
                    let margin = fontSize * 0.8
                    string.draw(at: CGPoint(x: size.width - textSize.width - margin, y: size.height - textSize.height - margin))
                case "center":
                    cg.translateBy(x: size.width / 2, y: size.height / 2)
                    cg.rotate(by: -.pi / 8)
                    string.draw(at: CGPoint(x: -textSize.width / 2, y: -textSize.height / 2))
                default:
                    cg.translateBy(x: size.width / 2, y: size.height / 2)
                    cg.rotate(by: -.pi / 6)
                    let diagonal = hypot(size.width, size.height)
                    let stepX = textSize.width + fontSize * 2
                    let stepY = textSize.height * 3
                    var y = -diagonal / 2
                    var row = 0
                    while y < diagonal / 2 {
                        var x = -diagonal / 2 + (row % 2 == 0 ? 0 : stepX / 2)
                        while x < diagonal / 2 {
                            string.draw(at: CGPoint(x: x, y: y))
                            x += stepX
                        }
                        y += stepY
                        row += 1
                    }
                }
            }
            guard let cgImage = rendered.cgImage else { throw ToolError("浮水印失敗") }
            let fmt = ImageFormat.resolve("same", for: input)
            let out = context.output(for: input, suffix: "_浮水印", ext: fmt.ext)
            try ImageEngine.write(cgImage, to: out, format: fmt, quality: 0.92, metadata: ImageEngine.withoutGPS(loaded.properties))
            return [out]
        }
    }
}

// MARK: - 影片共用

enum VideoTools {
    static func ext(for input: URL) -> String {
        let ext = input.pathExtension.lowercased()
        return ["mov", "mp4", "m4v"].contains(ext) ? ext : "mov"
    }

    /// 把影片（可選音訊）放進新的組合。
    static func composition(of asset: AVURLAsset, audio: Bool) async throws -> (AVMutableComposition, AVMutableCompositionTrack, CGAffineTransform, CGSize) {
        guard let source = try await asset.loadTracks(withMediaType: .video).first else { throw ToolError("找不到影片軌") }
        let duration = try await asset.load(.duration)
        let range = CMTimeRange(start: .zero, duration: duration)
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ToolError("無法建立影片軌")
        }
        try video.insertTimeRange(range, of: source, at: .zero)
        let transform = try await source.load(.preferredTransform)
        let natural = try await source.load(.naturalSize)
        video.preferredTransform = transform
        if audio {
            for track in try await asset.loadTracks(withMediaType: .audio) {
                let a = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                try a?.insertTimeRange(range, of: track, at: .zero)
            }
        }
        return (composition, video, transform, natural)
    }
}

// MARK: - 影片：靜音

struct VideoMuteOp: ToolOperation {
    let id = "video.mute"
    let title = "移除聲音"
    let subtitle = "拿掉音軌，畫面不重新壓縮"
    let systemImage = "speaker.slash"
    let accepts: Set<FileKind> = [.video]
    var parameters: [ParameterSpec] { [] }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        try await eachInput(inputs, context) { input in
            let (composition, _, _, _) = try await VideoTools.composition(of: AVURLAsset(url: input), audio: false)
            let ext = VideoTools.ext(for: input)
            let out = context.output(for: input, suffix: "_muted", ext: ext)
            try await MediaExport.export(composition, to: out, preset: AVAssetExportPresetPassthrough,
                                         fileType: MediaExport.fileType(forExtension: ext))
            return [out]
        }
    }
}

// MARK: - 影片：旋轉

struct VideoRotateOp: ToolOperation {
    let id = "video.rotate"
    let title = "旋轉"
    let subtitle = "轉正拍歪的影片，不重新壓縮"
    let systemImage = "rotate.right"
    let accepts: Set<FileKind> = [.video]
    var parameters: [ParameterSpec] {
        [.choice("turn", "方向", [("cw", "向右 90°"), ("ccw", "向左 90°"), ("180", "180°")], default: "cw")]
    }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        let turn = params.string("turn", "cw")
        return try await eachInput(inputs, context) { input in
            let (composition, video, transform, natural) = try await VideoTools.composition(of: AVURLAsset(url: input), audio: true)
            let shown = CGRect(origin: .zero, size: natural).applying(transform)
            let w = abs(shown.width), h = abs(shown.height)
            let extra: CGAffineTransform
            switch turn {
            case "ccw": extra = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
            case "180": extra = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
            default: extra = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
            }
            video.preferredTransform = transform.concatenating(extra)
            let ext = VideoTools.ext(for: input)
            let out = context.output(for: input, suffix: "_rotated", ext: ext)
            try await MediaExport.export(composition, to: out, preset: AVAssetExportPresetPassthrough,
                                         fileType: MediaExport.fileType(forExtension: ext))
            return [out]
        }
    }
}

// MARK: - 影片：變速

struct VideoSpeedOp: ToolOperation {
    let id = "video.speed"
    let title = "變速"
    let subtitle = "快轉或慢動作，聲音不會變調"
    let systemImage = "gauge.with.dots.needle.67percent"
    let accepts: Set<FileKind> = [.video]
    var parameters: [ParameterSpec] {
        [.choice("speed", "速度", [("0.25", "0.25×"), ("0.5", "0.5×"), ("1.5", "1.5×"), ("2", "2×"), ("4", "4×")], default: "2")]
    }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        let speed = Swift.max(0.1, Double(params.string("speed", "2")) ?? 2)
        return try await eachInput(inputs, context) { input in
            let asset = AVURLAsset(url: input)
            let (composition, _, _, _) = try await VideoTools.composition(of: asset, audio: true)
            let duration = composition.duration
            composition.scaleTimeRange(CMTimeRange(start: .zero, duration: duration),
                                       toDuration: CMTimeMultiplyByFloat64(duration, multiplier: 1 / speed))
            let out = context.output(for: input, suffix: "_\(params.string("speed", "2"))x", ext: "mp4")
            try await MediaExport.export(composition, to: out, preset: AVAssetExportPresetHighestQuality, fileType: .mp4,
                                         pitch: .spectral)
            return [out]
        }
    }
}

// MARK: - 影片：擷取畫面

struct VideoFramesOp: ToolOperation {
    let id = "video.frames"
    let title = "擷取畫面"
    let subtitle = "把影片存成一張張照片"
    let systemImage = "photo.on.rectangle.angled"
    let accepts: Set<FileKind> = [.video]
    var parameters: [ParameterSpec] {
        [
            .choice("mode", "方式", [("count", "平均取幾張"), ("interval", "每隔幾秒"), ("at", "指定時間")], default: "count"),
            .number("count", "張數", range: 1...60, step: 1, default: 6, unit: " 張", showIf: ["mode": "count"]),
            .number("interval", "間隔", range: 0.5...60, step: 0.5, default: 2, unit: " 秒", showIf: ["mode": "interval"]),
            .text("times", "時間", default: "0:01", placeholder: "例如 0:03, 1:20", showIf: ["mode": "at"]),
            .choice("format", "格式", [("jpg", "JPG"), ("heic", "HEIC"), ("png", "PNG")], default: "jpg"),
        ]
    }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        let format = ImageFormat(rawValue: params.string("format", "jpg")) ?? .jpg
        return try await eachInput(inputs, context) { input in
            let asset = AVURLAsset(url: input)
            let duration = try await asset.load(.duration).seconds
            var seconds: [Double]
            switch params.string("mode", "count") {
            case "interval":
                let step = Swift.max(0.5, params.double("interval", 2))
                seconds = Array(stride(from: 0, to: duration, by: step))
            case "at":
                seconds = TimeText.list(params.string("times", "0:01")).filter { $0 < duration }
            default:
                let n = Swift.max(1, params.int("count", 6))
                seconds = (0..<n).map { duration * (Double($0) + 0.5) / Double(n) }
            }
            seconds = Array(seconds.prefix(300))
            guard !seconds.isEmpty else { throw ToolError("時間超出影片長度") }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)
            var outputs: [URL] = []
            for (index, second) in seconds.enumerated() {
                try Task.checkCancellation()
                context.report("第 \(index + 1)/\(seconds.count) 張")
                ProgressScope.report?(Double(index) / Double(seconds.count))
                let (image, _) = try await generator.image(at: CMTime(seconds: second, preferredTimescale: 600))
                let stamp = TimeText.string(second).replacingOccurrences(of: ":", with: "-")
                let out = context.output(for: input, suffix: "_\(stamp)", ext: format.ext)
                try ImageEngine.write(image, to: out, format: format, quality: 0.92, metadata: nil)
                outputs.append(out)
            }
            return outputs
        }
    }
}

// MARK: - 影片：合併

struct VideoMergeOp: ToolOperation {
    let id = "video.merge"
    let title = "合併"
    let subtitle = "依目前順序接成一支影片"
    let systemImage = "arrow.triangle.merge"
    let accepts: Set<FileKind> = [.video]
    let minInputs = 2
    var parameters: [ParameterSpec] {
        [.text("name", "檔名", default: "合併影片", placeholder: "檔名")]
    }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ToolError("無法建立影片")
        }
        var cursor = CMTime.zero
        var hasAudio = false
        for (index, input) in inputs.enumerated() {
            context.report("讀取 \(index + 1)/\(inputs.count)")
            let asset = AVURLAsset(url: input)
            let duration = try await asset.load(.duration)
            let range = CMTimeRange(start: .zero, duration: duration)
            guard let source = try await asset.loadTracks(withMediaType: .video).first else {
                throw ToolError("\(input.lastPathComponent) 沒有影片軌")
            }
            try video.insertTimeRange(range, of: source, at: cursor)
            if index == 0 { video.preferredTransform = try await source.load(.preferredTransform) }
            if let sound = try await asset.loadTracks(withMediaType: .audio).first {
                try audio.insertTimeRange(range, of: sound, at: cursor)
                hasAudio = true
            }
            cursor = CMTimeAdd(cursor, duration)
        }
        if !hasAudio { composition.removeTrack(audio) }
        let name = params.string("name", "合併影片")
        let out = context.output(named: name.isEmpty ? "合併影片" : name, ext: "mp4")
        try await MediaExport.export(composition, to: out, preset: AVAssetExportPresetHighestQuality, fileType: .mp4)
        return [out]
    }
}

// MARK: - 音訊：語音轉文字

struct AudioTranscribeOp: ToolOperation {
    let id = "audio.transcribe"
    let title = "語音轉文字"
    let subtitle = "在手機上辨識，輸出逐字稿或字幕"
    let systemImage = "text.bubble"
    let accepts: Set<FileKind> = [.audio, .video]
    var parameters: [ParameterSpec] {
        [
            .choice("language", "語言", [("zh-TW", "國語"), ("en-US", "英文"), ("ja-JP", "日文"), ("zh-CN", "普通話")],
                    default: "zh-TW"),
            .choice("format", "輸出", [("txt", "逐字稿 TXT"), ("srt", "字幕 SRT")], default: "txt"),
        ]
    }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        let status = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard status == .authorized else { throw ToolError("需要語音辨識權限，請到「設定 › 工具箱」開啟") }
        let language = params.string("language", "zh-TW")
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)), recognizer.isAvailable else {
            throw ToolError("這台裝置目前不能辨識這個語言")
        }
        let srt = params.string("format", "txt") == "srt"
        return try await eachInput(inputs, context) { input in
            var source = input
            if FileKind.detect(input) == .video {
                context.report("取出聲音中…")
                source = Workspace.uniqueURL(in: context.outputDirectory, base: "audio-temp", ext: "m4a")
                try await MediaExport.export(AVURLAsset(url: input), to: source, preset: AVAssetExportPresetAppleM4A, fileType: .m4a)
            }
            defer { if source != input { try? FileManager.default.removeItem(at: source) } }
            context.report("辨識中，長的錄音需要一點時間…")
            let transcription = try await Self.recognize(source, recognizer: recognizer)
            let out = context.output(for: input, ext: srt ? "srt" : "txt")
            try TextIO.write(srt ? Self.subtitles(transcription) : transcription.formattedString, to: out)
            return [out]
        }
    }

    static func recognize(_ url: URL, recognizer: SFSpeechRecognizer) async throws -> SFTranscription {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        final class State: @unchecked Sendable {
            var done = false
            var task: SFSpeechRecognitionTask?
        }
        let state = State()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<SFTranscription, Error>) in
                state.task = recognizer.recognitionTask(with: request) { result, error in
                    guard !state.done else { return }
                    if let result, result.isFinal {
                        state.done = true
                        c.resume(returning: result.bestTranscription)
                    } else if let error {
                        state.done = true
                        c.resume(throwing: ToolError("辨識失敗：\(error.localizedDescription)"))
                    }
                }
            }
        } onCancel: {
            state.task?.cancel()
        }
    }

    /// 依停頓和長度把字詞分成一句句字幕。
    static func subtitles(_ transcription: SFTranscription) -> String {
        var cues: [(Double, Double, String)] = []
        var start = 0.0, end = 0.0, text = ""
        for segment in transcription.segments {
            let s = segment.timestamp, e = segment.timestamp + segment.duration
            if !text.isEmpty && (s - end > 0.8 || e - start > 6 || text.count > 22) {
                cues.append((start, end, text)); text = ""
            }
            if text.isEmpty { start = s }
            let needsSpace = !text.isEmpty && !(text.last.map(MD.isCJK) ?? false) && !(segment.substring.first.map(MD.isCJK) ?? false)
            text += (needsSpace ? " " : "") + segment.substring
            end = e
        }
        if !text.isEmpty { cues.append((start, end, text)) }
        func stamp(_ t: Double) -> String {
            let ms = Int((t * 1000).rounded())
            return String(format: "%02ld:%02ld:%02ld,%03ld", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
        }
        return cues.enumerated().map { index, cue in
            "\(index + 1)\n\(stamp(cue.0)) --> \(stamp(cue.1))\n\(cue.2)\n"
        }.joined(separator: "\n")
    }
}
