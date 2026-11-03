import Photos
import UIKit

/// 比對分享進來的圖片是相簿裡的哪一張截圖（同尺寸＋影像指紋）。
enum ImageMatcher {
    struct Match: Sendable {
        let id: String
        let date: Date
    }

    /// 8×8 平均雜湊（aHash）。
    static func fingerprint(_ image: UIImage) -> UInt64? {
        let side = 8
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let small = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        guard let cg = small.cgImage else { return nil }
        var pixels = [UInt8](repeating: 0, count: side * side)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side, space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        let average = pixels.reduce(0) { $0 + Int($1) } / pixels.count
        var hash: UInt64 = 0
        for (i, value) in pixels.enumerated() where Int(value) > average {
            hash |= 1 << UInt64(i)
        }
        return hash
    }

    static func distance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    /// 在最近的同尺寸截圖中找最像的一張。
    static func findScreenshot(matching image: UIImage) async -> Match? {
        let width = Int(image.size.width * image.scale)
        let height = Int(image.size.height * image.scale)
        guard let target = fingerprint(image) else { return nil }

        let options = PHFetchOptions()
        options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "(mediaSubtypes & %d) != 0", PHAssetMediaSubtype.photoScreenshot.rawValue),
            NSPredicate(format: "pixelWidth == %d AND pixelHeight == %d", width, height),
        ])
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 60
        let assets = PHAsset.fetchAssets(with: .image, options: options)

        var best: (match: Match, distance: Int)?
        for i in 0..<assets.count {
            let asset = assets.object(at: i)
            guard let small = try? await PhotoImageLoader.loadSmallImage(asset: asset, side: 64),
                  let hash = fingerprint(small) else { continue }
            let d = distance(hash, target)
            if d <= 5, best == nil || d < best!.distance {
                best = (Match(id: asset.localIdentifier, date: asset.creationDate ?? .now), d)
                if d == 0 { break }
            }
        }
        return best?.match
    }
}
