import SwiftUI
import Photos

/// PhotoKit 的圖。iCloud 上的照片下載中會顯示轉圈。
struct AssetImage: View {
    let asset: PHAsset
    var targetSize: CGSize
    var contentMode: ContentMode = .fill
    /// 背景模糊圖之類的地方不要轉圈
    var showsProgress = true

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if failed && showsProgress {
                Image(systemName: "exclamationmark.icloud")
                    .font(.title)
                    .foregroundStyle(.secondary)
            } else if showsProgress {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: asset.localIdentifier) {
            image = nil
            failed = false
            let mode: PHImageContentMode = contentMode == .fill ? .aspectFill : .aspectFit
            for await next in ImageLoader.shared.image(for: asset, targetSize: targetSize, contentMode: mode) {
                image = next
            }
            if image == nil { failed = true }
        }
    }
}

extension PHAsset {
    /// 拍攝時間（沒有就用加入相簿的時間）
    var takenAt: Date { creationDate ?? modificationDate ?? .now }
}
