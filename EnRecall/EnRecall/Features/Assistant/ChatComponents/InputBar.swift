import SwiftUI
import PhotosUI

/// 底部輸入列（控制層，用 Liquid Glass）：＋（掃描／照片）、文字框、送出。送出前顯示圖片縮圖，可以移除
struct InputBar: View {
    @Binding var text: String
    @Binding var images: [Data]
    var isBusy: Bool
    var focus: FocusState<Bool>.Binding
    /// 空白頁的「拍照加單字」也會打開掃描
    @Binding var isScanning: Bool
    let send: () -> Void

    @State private var photoItems: [PhotosPickerItem] = []
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var canSend: Bool {
        !isBusy && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !images.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(Array(images.enumerated()), id: \.offset) { index, data in
                            attachment(data, index: index)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 6)
                }
                .scrollIndicators(.hidden)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    if DocumentScanner.isAvailable {
                        Button("掃描文件", systemImage: "doc.viewfinder") { isScanning = true }
                    }
                    PhotosPicker(selection: $photoItems,
                                 maxSelectionCount: max(AssistantConfig.maxImages - images.count, 1),
                                 matching: .images) {
                        Label("從照片選", systemImage: "photo.on.rectangle")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(Color.er.text)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .disabled(images.count >= AssistantConfig.maxImages)
                .accessibilityLabel("加入圖片")

                TextField("問問題、貼文章，或拍單字表", text: $text, axis: .vertical)
                    .lineLimit(1...5)
                    .font(.body)
                    .foregroundStyle(Color.er.text)
                    .focused(focus)
                    .padding(.vertical, 11)

                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.bold))
                        .foregroundStyle(canSend ? Color.er.onPrimary : Color.er.textTertiary)
                        .frame(width: 36, height: 36)
                        .background(canSend ? Color.er.primary : Color.er.fill, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(4)
                .disabled(!canSend)
                .accessibilityLabel("送出")
            }
            .padding(.leading, 2)
            .padding(.trailing, 2)
            .modifier(InputBackground(solid: reduceTransparency))
        }
        .animation(.snappy(duration: 0.25), value: images.count)
        .fullScreenCover(isPresented: $isScanning) {
            DocumentScanner { pages in
                isScanning = false
                add(pages.compactMap { ImageCompressor.compress($0) })
            }
            .ignoresSafeArea()
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                var loaded: [Data] = []
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self), let compressed = ImageCompressor.compress(data) {
                        loaded.append(compressed)
                    }
                }
                add(loaded)
                photoItems = []
            }
        }
    }

    private func add(_ new: [Data]) {
        guard !new.isEmpty else { return }
        images = Array((images + new).prefix(AssistantConfig.maxImages))
    }

    private func attachment(_ data: Data, index: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            if let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
            }
            Button {
                images.remove(at: index)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.er.onPrimary, Color.er.primary)
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
            .accessibilityLabel("移除圖片")
        }
    }
}

private struct InputBackground: ViewModifier {
    let solid: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        if solid {
            content
                .background(Color.er.surfaceHigh, in: shape)
                .overlay(shape.strokeBorder(Color.er.outline))
        } else {
            content.glassEffect(.regular.interactive(), in: shape)
        }
    }
}
