import SwiftUI
import QuickLookThumbnailing
import AVFoundation
import PDFKit

struct FileRow: View {
    let file: InputFile
    @State private var thumbnail: UIImage?
    @State private var detail = ""

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.quaternary)
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: file.kind.systemImage)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(file.kind.label) · \(Workspace.formattedSize(file.size))\(detail)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: file.id) {
            thumbnail = await Thumbnails.make(for: file.url)
            detail = await FileInfo.detail(for: file)
        }
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
