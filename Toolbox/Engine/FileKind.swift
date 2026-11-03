import Foundation
import UniformTypeIdentifiers

/// 檔案類型。App 依這個決定要列出哪些動作。
enum FileKind: String, Codable, CaseIterable, Sendable {
    case image, video, audio, pdf, json, other

    var label: String {
        switch self {
        case .image: return "圖片"
        case .video: return "影片"
        case .audio: return "音訊"
        case .pdf: return "PDF"
        case .json: return "功能包"
        case .other: return "其他檔案"
        }
    }

    var systemImage: String {
        switch self {
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .pdf: return "doc.richtext"
        case .json: return "puzzlepiece.extension"
        case .other: return "doc"
        }
    }

    static func detect(_ url: URL) -> FileKind {
        let resourceType = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        guard let type = resourceType ?? UTType(filenameExtension: url.pathExtension) else {
            return .other
        }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .json) { return .json }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        return .other
    }
}

struct InputFile: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let kind: FileKind

    var name: String { url.lastPathComponent }
    var size: Int64 { Workspace.fileSize(url) }
}
