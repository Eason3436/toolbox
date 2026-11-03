import SwiftUI
import QuickLookThumbnailing
import AVFoundation
import PDFKit

struct FileRow: View {
    let file: InputFile
    var onRemove: (() -> Void)?
    @State private var thumbnail: UIImage?
    @State private var detail = ""

    var body: some View {
        HStack(spacing: 12) {
            FileThumbnail(image: thumbnail, kind: file.kind)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .foregroundStyle(Color.tbInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(Workspace.formattedSize(file.size)) · \(file.url.pathExtension.uppercased())\(detail)")
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(Color.tbInkSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.tbInkTertiary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("移除 \(file.name)")
            }
        }
        .frame(minHeight: 52)
        .task(id: file.id) {
            thumbnail = await Thumbnails.make(for: file.url)
            detail = await FileInfo.detail(for: file)
        }
    }
}

/// 44×44 的檔案縮圖，沒有縮圖時顯示類型圖示。
struct FileThumbnail: View {
    let image: UIImage?
    let kind: FileKind

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.tbGround)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: kind.systemImage)
                    .foregroundStyle(Color.tbInkSecondary)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.tbHairline, lineWidth: 0.5)
        )
    }
}

enum Thumbnails {
    static func make(for url: URL, side: CGFloat = 96) async -> UIImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side),
                                                   scale: 3, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).uiImage
    }
}

enum FileInfo {
    static func detail(for file: InputFile) async -> String {
        switch file.kind {
        case .image:
            if let size = ImageEngine.pixelSize(file.url) {
                return " · \(Int(size.width))×\(Int(size.height))"
            }
        case .video, .audio:
            if let duration = try? await AVURLAsset(url: file.url).load(.duration) {
                return " · " + TimeText.string(duration.seconds)
            }
        case .pdf:
            if let doc = PDFDocument(url: file.url) {
                return " · \(doc.pageCount) 頁"
            }
        default:
            break
        }
        return ""
    }
}
