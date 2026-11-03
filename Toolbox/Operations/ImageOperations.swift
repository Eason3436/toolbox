import Foundation
import ImageIO
import CoreGraphics
import UIKit
import PDFKit

enum CropRatios {
    static let all: [(String, String)] = [
        ("1:1", "1:1"),
        ("4:5", "4:5"),
        ("3:4", "3:4"),
        ("2:3", "2:3"),
        ("9:16", "9:16"),
        ("4:3", "4:3"),
        ("3:2", "3:2"),
        ("16:9", "16:9"),
        ("3:1", "3:1"),
        ("65:24", "XPan"),
        ("24:65", "XPan 直"),
        ("2.39:1", "寬銀幕 2.39"),
    ]

    struct Item: Identifiable {
        let value: String
        let label: String
        var id: String { value }
    }

    static let items: [Item] = all.map { Item(value: $0.0, label: $0.1) }
}

private let qualitySpec = ParameterSpec.number("quality", "品質", range: 10...100, step: 5, default: 90, unit: "%")
private let keepMetadataSpec = ParameterSpec.toggle("keepMetadata", "保留拍攝資訊（EXIF）", default: true)

// MARK: - 比例裁切

struct ImageCropOp: ToolOperation {
    let id = "image.crop"
    let title = "比例裁切"
    let subtitle = "1:1、4:5、16:9、XPan、寬銀幕…"
    let systemImage = "crop"
    let accepts: Set<FileKind> = [.image]
    let editor: OperationEditor = .crop
    var parameters: [ParameterSpec] {
        [
            .choice("ratio", "比例", CropRatios.all, default: "4:5",
                    footer: "選一張圖片時可以拖曳、縮放調整範圍；多張時會從中間裁切。"),
            .choice("format", "輸出格式", ImageFormat.optionsWithSame, default: "same"),
            .number("quality", "品質", range: 10...100, step: 5, default: 95, unit: "%"),
            keepMetadataSpec,
            .text("_rect", "裁切範圍", default: ""),
        ]
    }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        let ratioText = params.string("ratio", "1:1")
        guard let ratio = ImageEngine.ratio(from: ratioText) else { throw ToolError("比例格式不正確：\(ratioText)") }
        let custom = ImageEngine.normalizedRect(from: params.string("_rect", ""))
        return try await eachInput(inputs, context) { input in
            let loaded = try ImageEngine.load(input)
            let w = loaded.image.width, h = loaded.image.height
            var rect: CGRect
            if let custom, inputs.count == 1 {
                rect = CGRect(x: custom.minX * Double(w), y: custom.minY * Double(h),
                              width: custom.width * Double(w), height: custom.height * Double(h))
            } else {
                rect = ImageEngine.centerRect(width: w, height: h, ratio: ratio)
            }
            rect = rect.integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))
            guard let cropped = loaded.image.cropping(to: rect) else { throw ToolError("裁切失敗") }
            let format = ImageFormat.resolve(params.string("format", "same"), for: input)
            let out = context.output(for: input, suffix: "_crop", ext: format.ext)
            try ImageEngine.write(cropped, to: out, format: format, quality: params.double("quality", 95) / 100,
                                  metadata: params.bool("keepMetadata", true) ? loaded.properties : nil)
            return [out]
        }
    }
}

// MARK: - 轉檔

struct ImageConvertOp: ToolOperation {
    let id = "image.convert"
    let title = "轉檔"
    let subtitle = "JPG、PNG、HEIC、TIFF"
    let systemImage = "arrow.triangle.2.circlepath"
    let accepts: Set<FileKind> = [.image]
    var parameters: [ParameterSpec] {
        [
            .choice("format", "轉成", ImageFormat.options, default: "jpg"),
            .number("quality", "品質", range: 10...100, step: 5, default: 90, unit: "%", showIf: ["format": "jpg|heic"]),
            keepMetadataSpec,
        ]
    }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        let format = ImageFormat(rawValue: params.string("format", "jpg")) ?? .jpg
        return try await eachInput(inputs, context) { input in
            let loaded = try ImageEngine.load(input)
            let out = context.output(for: input, ext: format.ext)
            try ImageEngine.write(loaded.image, to: out, format: format, quality: params.double("quality", 90) / 100,
                                  metadata: params.bool("keepMetadata", true) ? loaded.properties : nil)
            return [out]
        }
    }
}

// MARK: - 壓縮

struct ImageCompressOp: ToolOperation {
    let id = "image.compress"
    let title = "壓縮"
    let subtitle = "依品質壓縮，或壓到指定大小以下"
    let systemImage = "arrow.down.right.and.arrow.up.left"
    let accepts: Set<FileKind> = [.image]
    var parameters: [ParameterSpec] {
        [
            .choice("mode", "方式", [("quality", "依品質"), ("size", "指定檔案大小")], default: "quality"),
            .number("quality", "品質", range: 10...100, step: 5, default: 70, unit: "%", showIf: ["mode": "quality"]),
            .number("targetKB", "最大檔案大小", range: 50...10_000, step: 50, default: 500, unit: " KB", showIf: ["mode": "size"]),
            .choice("maxDimension", "最長邊", [("0", "原尺寸"), ("4096", "4096 px"), ("3000", "3000 px"),
                                             ("2048", "2048 px"), ("1600", "1600 px"), ("1080", "1080 px")], default: "0"),
            .choice("format", "輸出格式", [("same", "保持原格式"), ("jpg", "JPG"), ("heic", "HEIC")], default: "same",
                    footer: "PNG 是無損格式，選「保持原格式」時只會縮小尺寸。"),
            keepMetadataSpec,
        ]
    }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        let maxDimension = Int(params.string("maxDimension", "0")) ?? 0
        let bySize = params.string("mode", "quality") == "size"
        let targetBytes = Int(params.double("targetKB", 500) * 1024)
        return try await eachInput(inputs, context) { input in
            let loaded = try ImageEngine.load(input, maxPixel: maxDimension > 0 ? maxDimension : nil)
            let format = ImageFormat.resolve(params.string("format", "same"), for: input)
            let metadata = params.bool("keepMetadata", true) ? loaded.properties : nil
            let data: Data
            if bySize {
                data = try Self.fit(loaded.image, format: format, metadata: metadata, targetBytes: targetBytes)
            } else {
                data = try ImageEngine.encode(loaded.image, format: format,
                                              quality: params.double("quality", 70) / 100, metadata: metadata)
            }
            let out = context.output(for: input, suffix: "_small", ext: format.ext)
            try data.write(to: out, options: .atomic)
            return [out]
        }
    }

    /// 先調品質，不夠再縮小尺寸，直到小於目標大小。
    static func fit(_ image: CGImage, format: ImageFormat, metadata: [CFString: Any]?, targetBytes: Int) throws -> Data {
        var current = image
        var best: Data?
        for _ in 0..<8 {
            if format.isLossy {
                var low = 0.05, high = 0.95
                var found: Data?
                for _ in 0..<7 {
                    let mid = (low + high) / 2
                    let data = try ImageEngine.encode(current, format: format, quality: mid, metadata: metadata)
                    if data.count <= targetBytes { found = data; low = mid } else { high = mid }
                }
                if let found { return found }
                best = try ImageEngine.encode(current, format: format, quality: 0.05, metadata: metadata)
            } else {
                let data = try ImageEngine.encode(current, format: format, quality: 1, metadata: metadata)
                if data.count <= targetBytes { return data }
                best = data
            }
            guard let smaller = ImageEngine.scaled(current, factor: 0.8) else { break }
            current = smaller
        }
        if let best { return best }
        throw ToolError("無法壓到指定大小")
    }
}

// MARK: - 調整尺寸

struct ImageResizeOp: ToolOperation {
    let id = "image.resize"
    let title = "調整尺寸"
    let subtitle = "指定最長邊或百分比"
    let systemImage = "arrow.up.left.and.down.right.magnifyingglass"
    let accepts: Set<FileKind> = [.image]
    var parameters: [ParameterSpec] {
        [
            .choice("mode", "方式", [("long", "最長邊"), ("percent", "百分比")], default: "long"),
            .number("longEdge", "最長邊", range: 100...8000, step: 100, default: 2048, unit: " px", showIf: ["mode": "long"]),
            .number("percent", "比例", range: 5...100, step: 5, default: 50, unit: "%", showIf: ["mode": "percent"]),
            .choice("format", "輸出格式", ImageFormat.optionsWithSame, default: "same"),
            qualitySpec,
            keepMetadataSpec,
        ]
    }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        try await eachInput(inputs, context) { input in
            let original = ImageEngine.pixelSize(input) ?? CGSize(width: 4000, height: 4000)
            let longest = Swift.max(original.width, original.height)
            let target: Int
            if params.string("mode", "long") == "percent" {
                target = Int(longest * params.double("percent", 50) / 100)
            } else {
                target = params.int("longEdge", 2048)
            }
            let loaded = try ImageEngine.load(input, maxPixel: Swift.max(target, 1))
            var image = loaded.image
            // ImageIO 不會放大，需要放大時自己畫。
            let currentLong = Swift.max(image.width, image.height)
            if target > currentLong, let bigger = ImageEngine.scaled(image, factor: Double(target) / Double(currentLong)) {
                image = bigger
            }
            let format = ImageFormat.resolve(params.string("format", "same"), for: input)
            let out = context.output(for: input, suffix: "_\(Swift.max(image.width, image.height))px", ext: format.ext)
            try ImageEngine.write(image, to: out, format: format, quality: params.double("quality", 90) / 100,
                                  metadata: params.bool("keepMetadata", true) ? loaded.properties : nil)
            return [out]
        }
    }
}

// MARK: - 移除中繼資料

struct ImageStripMetadataOp: ToolOperation {
    let id = "image.stripMetadata"
    let title = "移除位置與拍攝資訊"
    let subtitle = "分享前保護隱私"
    let systemImage = "location.slash"
    let accepts: Set<FileKind> = [.image]
    var parameters: [ParameterSpec] {
        [
            .choice("mode", "移除", [("gps", "只移除位置（不重新壓縮）"), ("all", "全部 EXIF 與位置")], default: "gps"),
        ]
    }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        let all = params.string("mode", "gps") == "all"
        return try await eachInput(inputs, context) { input in
            if all {
                let loaded = try ImageEngine.load(input)
                let format = ImageFormat.resolve("same", for: input)
                let out = context.output(for: input, suffix: "_clean", ext: format.ext)
                try ImageEngine.write(loaded.image, to: out, format: format, quality: 0.95, metadata: nil)
                return [out]
            }
            guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
                  let type = CGImageSourceGetType(source) else {
                throw ToolError("無法讀取圖片：\(input.lastPathComponent)")
            }
            let out = context.output(for: input, suffix: "_noGPS", ext: input.pathExtension.isEmpty ? "jpg" : input.pathExtension)
            guard let destination = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil) else {
                throw ToolError("無法建立輸出檔")
            }
            let options: [CFString: Any] = [kCGImageMetadataShouldExcludeGPS: true]
            var error: Unmanaged<CFError>?
            guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error) else {
                throw ToolError("移除位置失敗")
            }
            return [out]
        }
    }
}

// MARK: - 圖片合成 PDF

struct ImagesToPDFOp: ToolOperation {
    let id = "image.toPDF"
    let title = "合成 PDF"
    let subtitle = "依目前順序，一張圖一頁"
    let systemImage = "doc.badge.plus"
    let accepts: Set<FileKind> = [.image, .pdf]
    var parameters: [ParameterSpec] {
        [
            .choice("page", "頁面大小", [("fit", "依圖片大小"), ("a4", "A4"), ("letter", "Letter")], default: "fit"),
            .number("quality", "圖片品質", range: 30...100, step: 5, default: 85, unit: "%"),
            .text("name", "檔名", default: "合併文件", placeholder: "檔名"),
        ]
    }

    func isAvailable(for kinds: [FileKind]) -> Bool {
        !kinds.isEmpty && Set(kinds).isSubset(of: accepts) && kinds.contains(.image)
    }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        let document = PDFDocument()
        let pageChoice = params.string("page", "fit")
        let quality = params.double("quality", 85) / 100
        for (index, input) in inputs.enumerated() {
            context.report("加入第 \(index + 1)/\(inputs.count) 個檔案")
            if FileKind.detect(input) == .pdf {
                guard let other = PDFDocument(url: input) else { continue }
                for i in 0..<other.pageCount {
                    if let page = other.page(at: i)?.copy() as? PDFPage { document.insert(page, at: document.pageCount) }
                }
                continue
            }
            let loaded = try ImageEngine.load(input, maxPixel: 3000)
            let image = UIImage(cgImage: loaded.image)
            let box: CGRect
            switch pageChoice {
            case "a4": box = CGRect(x: 0, y: 0, width: 595, height: 842)
            case "letter": box = CGRect(x: 0, y: 0, width: 612, height: 792)
            default:
                let longest = Swift.max(image.size.width, image.size.height)
                let scale = 842 / longest
                box = CGRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
            }
            let options: [PDFPage.ImageInitializationOption: Any] = [
                .mediaBox: box,
                .upscaleIfSmaller: true,
                .compressionQuality: quality,
            ]
            if let page = PDFPage(image: image, options: options) {
                document.insert(page, at: document.pageCount)
            }
        }
        guard document.pageCount > 0 else { throw ToolError("沒有可以加入的頁面") }
        let name = params.string("name", "合併文件")
        let out = context.output(named: name.isEmpty ? "合併文件" : name, ext: "pdf")
        guard document.write(to: out) else { throw ToolError("PDF 寫入失敗") }
        return [out]
    }
}
