import SwiftUI

/// 階段 1 的簡易大圖檢視（可縮放）。階段 4 會擴充成完整詳情頁。
struct ScreenshotViewer: View {
    @Environment(PhotoSyncService.self) private var library
    @Environment(\.displayScale) private var displayScale
    let record: ScreenshotRecord

    @State private var image: UIImage?
    @State private var missing = false
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(magnify.simultaneously(with: drag))
                        .onTapGesture(count: 2) { toggleZoom() }
                } else if missing {
                    ContentUnavailableView("找不到這張截圖", systemImage: "photo.badge.exclamationmark", description: Text("它可能已經從相簿刪除。"))
                } else {
                    ProgressView()
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .task(id: record.id) { await load(size: proxy.size) }
        }
        .navigationTitle(record.createdAt.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
    }

    private func load(size: CGSize) async {
        guard let asset = library.asset(for: record) else {
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
                guard scale > 1 else { return }
                offset = CGSize(width: lastOffset.width + value.translation.width,
                                height: lastOffset.height + value.translation.height)
            }
            .onEnded { _ in lastOffset = offset }
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
