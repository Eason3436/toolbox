import Photos
import UIKit

/// 從 PhotoKit 取圖。用 AsyncStream 傳回：先給模糊預覽，再給清晰版。
@MainActor
final class ImageLoader {
    static let shared = ImageLoader()

    private let manager = PHCachingImageManager()

    func image(for asset: PHAsset, targetSize: CGSize, contentMode: PHImageContentMode = .aspectFill) -> AsyncStream<UIImage> {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        // iCloud 上的照片要能下載
        options.isNetworkAccessAllowed = true
        let (stream, continuation) = AsyncStream<UIImage>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let requestID = Self.request(manager: manager, asset: asset, size: targetSize, mode: contentMode, options: options, continuation: continuation)
        continuation.onTermination = { _ in
            Task { @MainActor in ImageLoader.shared.cancel(requestID) }
        }
        return stream
    }

    /// 前後幾張先放進快取，滑到的時候馬上出現
    func preheat(_ assets: [PHAsset], targetSize: CGSize) {
        manager.stopCachingImagesForAllAssets()
        guard !assets.isEmpty else { return }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        manager.startCachingImages(for: assets, targetSize: targetSize, contentMode: .aspectFill, options: options)
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
            let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
            if let image { continuation.yield(image) }
            if !degraded || cancelled || info?[PHImageErrorKey] != nil { continuation.finish() }
        }
    }
}
