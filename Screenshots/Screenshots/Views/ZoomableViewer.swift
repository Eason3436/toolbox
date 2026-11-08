import SwiftUI

/// 全螢幕大圖（可縮放、雙擊放大、拖曳移動）。
struct ZoomableViewer: View {
    @Environment(PhotoSyncService.self) private var library
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dismiss) private var dismiss
    let assetID: String

    @State private var image: UIImage?
    @State private var missing = false
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(magnify.simultaneously(with: drag))
                        .onTapGesture(count: 2) { toggleZoom() }
                } else if missing {
                    ContentUnavailableView("找不到這張截圖", systemImage: "photo.badge.exclamationmark")
                        .foregroundStyle(.white)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .task(id: assetID) { await load(size: proxy.size) }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .padding(12)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .padding(16)
        }
        .statusBarHidden()
    }

    private func load(size: CGSize) async {
        guard let asset = library.asset(for: assetID) else {
            missing = true
            return
        }
        let target = CGSize(width: size.width * displayScale * 2, height: size.height * displayScale * 2)
        for await next in library.thumbnails.fullImage(for: asset, targetSize: target) {
            image = next
        }
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(max(lastScale * value.magnification, 1), 6)
            }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1 { resetZoom() }
            }
    }

    private var drag: some Gesture {
        DragGesture()
            .onChanged { value in
                if scale > 1 {
                    offset = CGSize(width: lastOffset.width + value.translation.width,
                                    height: lastOffset.height + value.translation.height)
                } else if value.translation.height > 0 {
                    offset = CGSize(width: 0, height: value.translation.height)
                }
            }
            .onEnded { value in
                if scale <= 1 {
                    // 未放大時往下滑關閉
                    if value.translation.height > 140 { dismiss() } else { withAnimation(.snappy) { offset = .zero } }
                } else {
                    lastOffset = offset
                }
            }
    }

    private func toggleZoom() {
        withAnimation(.snappy) {
            if scale > 1 {
                resetZoom()
            } else {
                scale = 2.5
                lastScale = 2.5
            }
        }
    }

    private func resetZoom() {
        withAnimation(.snappy) {
            scale = 1
            lastScale = 1
            offset = .zero
            lastOffset = .zero
        }
    }
}
