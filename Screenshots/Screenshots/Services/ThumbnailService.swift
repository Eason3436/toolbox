import Photos
import UIKit

/// 從 PhotoKit 取卡片縮圖與詳情頁大圖。用 AsyncStream 傳回（先給模糊預覽，再給清晰版）。
@MainActor
final class ThumbnailService {
    private let manager = PHCachingImageManager()

    func thumbnail(for asset: PHAsset, targetSize: CGSize) -> AsyncStream<UIImage> {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return stream(asset: asset, size: targetSize, mode: .aspectFill, options: options)
    }

    func fullImage(for asset: PHAsset, targetSize: CGSize) -> AsyncStream<UIImage> {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = true
        return stream(asset: asset, size: targetSize, mode: .aspectFit, options: options)
    }

    private func stream(asset: PHAsset, size: CGSize, mode: PHImageContentMode, options: PHImageRequestOptions) -> AsyncStream<UIImage> {
        let (stream, continuation) = AsyncStream<UIImage>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let requestID = Self.request(manager: manager, asset: asset, size: size, mode: mode, options: options, continuation: continuation)
        continuation.onTermination = { _ in
            Task { @MainActor in self.cancel(requestID) }
        }
        return stream
    }

    private func cancel(_ id: PHImageRequestID) {
        manager.cancelImageRequest(id)
    }

    /// 回呼可能在背景執行緒，所以這裡不隔離在主執行緒。
    nonisolated private static func request(
        manager: PHImageManager,
        asset: PHAsset,
        size: CGSize,
        mode: PHImageContentMode,
        options: PHImageRequestOptions,
        continuation: AsyncStream<UIImage>.Continuation
    ) -> PHImageRequestID {
        manager.requestImage(for: asset, targetSize: size, contentMode: mode, options: options) { image, info in
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            if let image { continuation.yield(image) }
            if !degraded { continuation.finish() }
        }
    }
}

enum PhotoLoadError: LocalizedError {
    case assetMissing
    case imageUnavailable

    var errorDescription: String? {
        switch self {
        case .assetMissing: "相簿裡找不到這張截圖，可能已被刪除。"
        case .imageUnavailable: "無法讀取這張截圖的影像。"
        }
    }
}

/// 背景分析用的影像讀取（不綁定主執行緒）。
enum PhotoImageLoader {
    /// 讀取高畫質影像，最長邊不超過 `maxPixel`。
    static func loadImage(assetID: String, maxPixel: CGFloat) async throws -> UIImage {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else {
            throw PhotoLoadError.assetMissing
        }
        let width = CGFloat(asset.pixelWidth)
        let height = CGFloat(asset.pixelHeight)
        let scale = min(1, maxPixel / max(width, height, 1))
        let target = CGSize(width: max(width * scale, 1), height: max(height * scale, 1))
        return try await request(asset: asset, size: target, mode: .aspectFit, fast: false)
    }

    /// 小縮圖（比對指紋用）。
    static func loadSmallImage(asset: PHAsset, side: CGFloat) async throws -> UIImage {
        try await request(asset: asset, size: CGSize(width: side, height: side), mode: .aspectFit, fast: true)
    }

    private static func request(asset: PHAsset, size: CGSize, mode: PHImageContentMode, fast: Bool) async throws -> UIImage {
        let options = PHImageRequestOptions()
        // highQualityFormat / fastFormat 都只回呼一次
        options.deliveryMode = fast ? .fastFormat : .highQualityFormat
        options.resizeMode = fast ? .fast : .exact
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UIImage, Error>) in
            PHImageManager.default().requestImage(for: asset, targetSize: size, contentMode: mode, options: options) { image, _ in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: PhotoLoadError.imageUnavailable)
                }
            }
        }
    }
}

/// 小縮圖快取：存在 App Group，最長邊 400 px，HEIC。給 Spotlight 與問答來源使用。
enum ThumbnailCache {
    static let maxPixel: CGFloat = 400

    static var directory: URL { AppGroup.directory("Thumbnails") }

    static func url(for assetID: String) -> URL {
        let safe = assetID.replacingOccurrences(of: "/", with: "_")
        return directory.appending(path: "\(safe).heic")
    }

    /// 縮小並存檔，回傳 HEIC 資料。
    @discardableResult
    static func store(_ image: UIImage, for assetID: String) -> Data? {
        let size = image.size
        let scale = min(1, maxPixel / max(size.width * image.scale, size.height * image.scale, 1))
        let target = CGSize(width: size.width * image.scale * scale, height: size.height * image.scale * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let small = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let data = small.heicData() else { return nil }
        try? data.write(to: url(for: assetID), options: .atomic)
        return data
    }

    static func data(for assetID: String) -> Data? {
        try? Data(contentsOf: url(for: assetID))
    }

    static func image(for assetID: String) -> UIImage? {
        data(for: assetID).flatMap(UIImage.init(data:))
    }

    static func remove(_ assetID: String) {
        try? FileManager.default.removeItem(at: url(for: assetID))
    }

    static func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// 目前快取大小（位元組）。
    static func totalSize() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { sum, url in
            sum + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}
