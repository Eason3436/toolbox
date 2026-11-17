import SwiftUI
import Photos

/// 照片頁的背景：目前這張照片放大模糊，再往下壓暗
struct Backdrop: View {
    let asset: PHAsset?

    var body: some View {
        ZStack {
            Color.black
            if let asset {
                AssetImage(asset: asset, targetSize: CGSize(width: 160, height: 160), showsProgress: false)
                    .scaleEffect(1.4)
                    .blur(radius: 70)
                    .opacity(0.9)
                    .id(asset.localIdentifier)
                    .transition(.opacity)
            }
            LinearGradient(colors: [.black.opacity(0.05), .black.opacity(0.6)],
                           startPoint: .top, endPoint: .bottom)
        }
        .animation(.easeInOut(duration: 0.35), value: asset?.localIdentifier)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
