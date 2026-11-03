import Foundation
import UniformTypeIdentifiers

/// 檔案類型。App 依這個決定要列出哪些動作。
enum FileKind: String, Codable, CaseIterable, Sendable {
    case image, video, audio, pdf, json, other
    case markdown, html, text, rtf, csv, office

    var label: String {
        switch self {
        case .image: return "圖片"
        case .video: return "影片"
        case .audio: return "音訊"
        case .pdf: return "PDF"
        case .json: return "JSON"
        case .markdown: return "Markdown"
        case .html: return "網頁"
        case .text: return "文字檔"
        case .rtf: return "RTF"
        case .csv: return "CSV"
        case .office: return "Office 文件"
        case .other: return "其他檔案"
        }
    }

    var systemImage: String {
        switch self {
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .pdf: return "doc.richtext"
        case .json: return "curlybraces"
        case .markdown: return "number"
        case .html: return "chevron.left.forwardslash.chevron.right"
        case .text: return "doc.plaintext"
        case .rtf: return "doc.text"
        case .csv: return "tablecells"
        case .office: return "doc"
        case .other: return "doc"
        }
    }

    /// 文件類（可以排版成 PDF、圖片）。
    static let documents: Set<FileKind> = [.markdown, .html, .text, .rtf, .csv, .office, .json]

    private static let officeExtensions: Set<String> = [
        "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "odt", "ods", "odp",
    ]

    static func detect(_ url: URL) -> FileKind {
        let ext = url.pathExtension.lowercased()
        if ["md", "markdown", "mdown", "mkd"].contains(ext) { return .markdown }
        if officeExtensions.contains(ext) { return .office }
        if ["csv", "tsv"].contains(ext) { return .csv }
        if ["htm", "html", "xhtml"].contains(ext) { return .html }
        let resourceType = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        guard let type = resourceType ?? UTType(filenameExtension: ext) else {
            return .other
        }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .json) { return .json }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .html) { return .html }
        if type.conforms(to: .rtf) || type.conforms(to: .rtfd) { return .rtf }
        if type.conforms(to: .commaSeparatedText) || type.conforms(to: .tabSeparatedText) { return .csv }
        if let md = UTType("net.daringfireball.markdown"), type.conforms(to: md) { return .markdown }
        if type.conforms(to: .plainText) || type.conforms(to: .sourceCode) || type.conforms(to: .xml)
            || type.conforms(to: .yaml) || ["txt", "log", "srt", "vtt", "ini", "conf"].contains(ext) { return .text }
        return .other
    }
}

struct InputFile: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let kind: FileKind
    /// 從相簿加入時的照片識別碼，原況照片瘦身要用。
    var assetID: String? = nil
    var isLivePhoto = false

    var name: String { url.lastPathComponent }
    var size: Int64 { Workspace.fileSize(url) }
}
