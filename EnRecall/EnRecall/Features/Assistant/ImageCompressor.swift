import UIKit

/// 上傳前壓縮：長邊 ≤ 2048px、JPEG 品質 0.8；另外做畫面用的小縮圖
enum ImageCompressor {
    static func compress(_ image: UIImage) -> Data? {
        resized(image, maxEdge: AssistantConfig.imageMaxEdge).jpegData(compressionQuality: AssistantConfig.imageQuality)
    }

    static func compress(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        return compress(image)
    }

    static func thumbnail(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        return resized(image, maxEdge: 320).jpegData(compressionQuality: 0.7)
    }

    static func resized(_ image: UIImage, maxEdge: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        // 方向也要轉正（相機照片常常是 .right）
        let scale = longest > maxEdge ? maxEdge / longest : 1
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
