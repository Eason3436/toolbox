import Photos
import UIKit

/// 從 PhotoKit 取縮圖與原圖。用 AsyncStream 傳回（先給模糊預覽，再給清晰版）。
final class ThumbnailService {
    private let manager = PHCachingImageManager()

    init() {
        manager.allowsCachingHighQualityImages = false
    }

    /// 卡片縮圖。
    func thumbnail(for asset: PHAsset, targetSize: CGSize) -> AsyncStream<UIImage> {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return stream(asset: asset, size: targetSize, mode: .aspectFill, options: options)
    }

    /// 詳情頁大圖（螢幕解析度即可，不必讀原始大小）。
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

    /// 回呼可能在背景執行緒，所以這裡不能隔離在主執行緒。
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
