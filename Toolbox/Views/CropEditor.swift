import SwiftUI

/// 固定比例的裁切框，拖曳移動、雙指縮放圖片。
/// 結果用 0～1 的相對範圍「x,y,w,h」寫回 rect。
struct CropEditor: View {
    let url: URL
    @Binding var ratio: ParamValue
    @Binding var rect: ParamValue

    @State private var image: UIImage?
    @State private var area: CGSize = .zero
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private var ratioValue: CGFloat {
        CGFloat(ImageEngine.ratio(from: ratio.stringValue) ?? 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let image {
                    let frame = cropFrame
                    let shown = shownSize(for: image)
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: shown.width, height: shown.height)
                        .offset(offset)
                    CropMask(hole: frame)
                        .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                        .allowsHitTesting(false)
                    GridLines()
                        .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
                        .frame(width: frame.width, height: frame.height)
                        .allowsHitTesting(false)
                    Rectangle()
                        .stroke(Color.white, lineWidth: 1.5)
                        .frame(width: frame.width, height: frame.height)
                        .allowsHitTesting(false)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .gesture(dragGesture.simultaneously(with: magnifyGesture))
            .onGeometryChange(for: CGSize.self) { $0.size } action: { newSize in
                area = newSize
                offset = clamped(offset)
                lastOffset = offset
                updateRect()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(CropRatios.items) { item in
                        let isSelected = ratio.stringValue == item.value
                        Button {
                            ratio = .string(item.value)
                            resetPosition()
                        } label: {
                            Text(item.label)
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(Capsule().fill(isSelected ? Color.accentColor : Color(.secondarySystemFill)))
                                .foregroundStyle(isSelected ? Color.white : Color.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .task(id: url) {
            let target = url
            let loaded = await Task.detached { (try? ImageEngine.load(target, maxPixel: 2400))?.image }.value
            if let loaded {
                image = UIImage(cgImage: loaded)
                resetPosition()
            }
        }
    }

    // MARK: 幾何

    private var cropFrame: CGSize {
        let available = CGSize(width: Swift.max(area.width - 32, 1), height: Swift.max(area.height - 32, 1))
        if available.width / available.height > ratioValue {
            return CGSize(width: available.height * ratioValue, height: available.height)
        }
        return CGSize(width: available.width, height: available.width / ratioValue)
    }

    private func shownSize(for image: UIImage) -> CGSize {
        let frame = cropFrame
        let base = Swift.max(frame.width / image.size.width, frame.height / image.size.height)
        return CGSize(width: image.size.width * base * scale, height: image.size.height * base * scale)
    }

    private func clamped(_ proposed: CGSize) -> CGSize {
        guard let image else { return .zero }
        let shown = shownSize(for: image)
        let frame = cropFrame
        let maxX = Swift.max((shown.width - frame.width) / 2, 0)
        let maxY = Swift.max((shown.height - frame.height) / 2, 0)
        return CGSize(width: Swift.min(Swift.max(proposed.width, -maxX), maxX),
                      height: Swift.min(Swift.max(proposed.height, -maxY), maxY))
    }

    private func updateRect() {
        guard let image, area.width > 0 else { return }
        let shown = shownSize(for: image)
        let frame = cropFrame
        let x = ((shown.width - frame.width) / 2 - offset.width) / shown.width
        let y = ((shown.height - frame.height) / 2 - offset.height) / shown.height
        let w = frame.width / shown.width
        let h = frame.height / shown.height
        rect = .string(String(format: "%.5f,%.5f,%.5f,%.5f", x, y, w, h))
    }

    private func resetPosition() {
        scale = 1
        lastScale = 1
        offset = .zero
        lastOffset = .zero
        updateRect()
    }

    // MARK: 手勢

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = clamped(CGSize(width: lastOffset.width + value.translation.width,
                                        height: lastOffset.height + value.translation.height))
                updateRect()
            }
            .onEnded { _ in lastOffset = offset }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = Swift.min(Swift.max(lastScale * value.magnification, 1), 8)
                offset = clamped(offset)
                updateRect()
            }
            .onEnded { _ in
                lastScale = scale
                lastOffset = offset
            }
    }
}

private struct CropMask: Shape {
    var hole: CGSize

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addRect(CGRect(x: rect.midX - hole.width / 2, y: rect.midY - hole.height / 2,
                            width: hole.width, height: hole.height))
        return path
    }
}

private struct GridLines: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for i in 1...2 {
            let x = rect.minX + rect.width * CGFloat(i) / 3
            let y = rect.minY + rect.height * CGFloat(i) / 3
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        return path
    }
}
