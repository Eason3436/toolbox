import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

enum ImageFormat: String, CaseIterable, Sendable {
    case jpg, png, heic, tiff

    var utType: UTType {
        switch self {
        case .jpg: return .jpeg
        case .png: return .png
        case .heic: return .heic
        case .tiff: return .tiff
        }
    }

    var ext: String { rawValue }
    var isLossy: Bool { self == .jpg || self == .heic }

    static func from(url: URL) -> ImageFormat? {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return .jpg
        case "png": return .png
        case "heic", "heif": return .heic
        case "tif", "tiff": return .tiff
        default: return nil
        }
    }

    /// 「same」= 保持原格式；原格式無法輸出（例如 WebP、GIF）時改用 JPG。
    static func resolve(_ choice: String, for input: URL) -> ImageFormat {
        if choice == "same" { return from(url: input) ?? .jpg }
        return ImageFormat(rawValue: choice) ?? .jpg
    }

    static let options: [(String, String)] = [
        ("jpg", "JPG"), ("png", "PNG"), ("heic", "HEIC"), ("tiff", "TIFF"),
    ]
    static let optionsWithSame: [(String, String)] = [("same", "保持原格式")] + options
}

struct LoadedImage {
    let image: CGImage
    let properties: [CFString: Any]
}

enum ImageEngine {
    /// 讀取圖片並套用方向。maxPixel 為 nil 時保留原尺寸。
    static func load(_ url: URL, maxPixel: Int? = nil) throws -> LoadedImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ToolError("無法讀取圖片：\(url.lastPathComponent)")
        }
        let properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let longEdge = Swift.max(width, height)
        let limit = maxPixel.map { Swift.min($0, longEdge > 0 ? longEdge : $0) } ?? longEdge

        if limit > 0 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: limit,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return LoadedImage(image: image, properties: properties)
            }
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ToolError("無法解碼圖片：\(url.lastPathComponent)")
        }
        return LoadedImage(image: image, properties: properties)
    }

    static func pixelSize(_ url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int,
              let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let orientation = p[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    /// 編碼成指定格式。quality 為 0～1。metadata 為 nil 時不寫入任何中繼資料。
    static func encode(_ image: CGImage, format: ImageFormat, quality: Double,
                       metadata: [CFString: Any]?) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, format.utType.identifier as CFString, 1, nil) else {
            throw ToolError("這台裝置不支援輸出 \(format.rawValue.uppercased())")
        }
        var properties: [CFString: Any] = metadata.map(cleanMetadata) ?? [:]
        if format.isLossy {
            properties[kCGImageDestinationLossyCompressionQuality] = Swift.min(Swift.max(quality, 0.01), 1)
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ToolError("圖片編碼失敗") }
        return data as Data
    }

    static func write(_ image: CGImage, to url: URL, format: ImageFormat, quality: Double,
                      metadata: [CFString: Any]?) throws {
        let data = try encode(image, format: format, quality: quality, metadata: metadata)
        try data.write(to: url, options: .atomic)
    }

    /// 方向已經套用到像素上，所以中繼資料裡的方向要改回 1，尺寸欄位交給系統重新計算。
    static func cleanMetadata(_ metadata: [CFString: Any]) -> [CFString: Any] {
        var m = metadata
        m[kCGImagePropertyOrientation] = 1
        m.removeValue(forKey: kCGImagePropertyPixelWidth)
        m.removeValue(forKey: kCGImagePropertyPixelHeight)
        if var tiff = m[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            m[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = m[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
            m[kCGImagePropertyExifDictionary] = exif
        }
        return m
    }

    static func withoutGPS(_ metadata: [CFString: Any]) -> [CFString: Any] {
        var m = metadata
        m.removeValue(forKey: kCGImagePropertyGPSDictionary)
        return m
    }

    static func scaled(_ image: CGImage, factor: Double) -> CGImage? {
        let width = Int((Double(image.width) * factor).rounded())
        let height = Int((Double(image.height) * factor).rounded())
        guard width > 0, height > 0 else { return nil }
        let space: CGColorSpace
        if let own = image.colorSpace, own.model == .rgb {
            space = own
        } else {
            space = CGColorSpace(name: CGColorSpace.sRGB)!
        }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    static func ratio(from text: String) -> Double? {
        let parts = text.split(separator: ":").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        return parts[0] / parts[1]
    }

    /// 置中、符合比例的最大裁切範圍。
    static func centerRect(width: Int, height: Int, ratio: Double) -> CGRect {
        let w = Double(width), h = Double(height)
        if w / h > ratio {
            let newW = h * ratio
            return CGRect(x: (w - newW) / 2, y: 0, width: newW, height: h)
        } else {
            let newH = w / ratio
            return CGRect(x: 0, y: (h - newH) / 2, width: w, height: newH)
        }
    }

    /// 「x,y,w,h」0～1 的相對範圍。
    static func normalizedRect(from text: String) -> CGRect? {
        let parts = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4, parts[2] > 0, parts[3] > 0 else { return nil }
        return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }
}
