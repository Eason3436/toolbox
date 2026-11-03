import AppIntents
import Foundation
import UniformTypeIdentifiers

/// 捷徑與 Siri 用的共通執行方式：把 IntentFile 存成檔案 → 跑積木 → 包回 IntentFile。
enum IntentRunner {
    static func localURLs(_ files: [IntentFile]) throws -> [URL] {
        let dir = try Workspace.newDirectory("Intent")
        return try files.enumerated().map { index, file in
            let name = file.filename.isEmpty ? "file-\(index + 1)" : file.filename
            let dest = Workspace.uniqueURL(in: dir, base: (name as NSString).deletingPathExtension,
                                           ext: (name as NSString).pathExtension.isEmpty
                                               ? (file.type?.preferredFilenameExtension ?? "dat")
                                               : (name as NSString).pathExtension)
            if let source = file.fileURL {
                let scoped = source.startAccessingSecurityScopedResource()
                defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                if (try? FileManager.default.copyItem(at: source, to: dest)) != nil { return dest }
            }
            try file.data.write(to: dest)
            return dest
        }
    }

    static func intentFiles(_ urls: [URL]) -> [IntentFile] {
        urls.map { IntentFile(fileURL: $0, filename: $0.lastPathComponent, type: UTType(filenameExtension: $0.pathExtension)) }
    }

    static func run(_ id: String, files: [IntentFile], values overrides: [String: ParamValue] = [:]) async throws -> [IntentFile] {
        guard let op = Registry.operation(id: id) else { throw ToolError("找不到這個功能：\(id)") }
        guard !files.isEmpty else { throw ToolError("沒有收到檔案") }
        var values = Params.defaults(for: op.parameters)
        values.merge(overrides) { _, new in new }
        let inputs = try localURLs(files)
        let outputs = try await Runner.run(op, inputs: inputs, values: values) { _ in }
        return intentFiles(outputs)
    }
}

// MARK: - 選項

enum ImageFormatChoice: String, AppEnum {
    case jpg, png, heic, tiff
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "圖片格式"
    static let caseDisplayRepresentations: [ImageFormatChoice: DisplayRepresentation] = [
        .jpg: "JPG", .png: "PNG", .heic: "HEIC", .tiff: "TIFF",
    ]
}

enum CropRatioChoice: String, AppEnum {
    case square, portrait45, portrait34, story916, landscape32, wide169, xpan, xpanVertical, cinema
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "裁切比例"
    static let caseDisplayRepresentations: [CropRatioChoice: DisplayRepresentation] = [
        .square: "1:1", .portrait45: "4:5", .portrait34: "3:4", .story916: "9:16", .landscape32: "3:2",
        .wide169: "16:9", .xpan: "XPan（65:24）", .xpanVertical: "XPan 直式（24:65）", .cinema: "寬銀幕 2.39:1",
    ]
    var ratio: String {
        switch self {
        case .square: return "1:1"
        case .portrait45: return "4:5"
        case .portrait34: return "3:4"
        case .story916: return "9:16"
        case .landscape32: return "3:2"
        case .wide169: return "16:9"
        case .xpan: return "65:24"
        case .xpanVertical: return "24:65"
        case .cinema: return "2.39:1"
        }
    }
}

enum VideoQualityChoice: String, AppEnum {
    case q1080 = "1080", q720 = "720", q540 = "540", low
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "影片解析度"
    static let caseDisplayRepresentations: [VideoQualityChoice: DisplayRepresentation] = [
        .q1080: "1080p", .q720: "720p", .q540: "540p", .low: "最小",
    ]
}

enum AudioFormatChoice: String, AppEnum {
    case m4a, alac, wav, aiff
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "音訊格式"
    static let caseDisplayRepresentations: [AudioFormatChoice: DisplayRepresentation] = [
        .m4a: "M4A（AAC）", .alac: "M4A（Apple 無損）", .wav: "WAV", .aiff: "AIFF",
    ]
}

// MARK: - 圖片

struct CompressImagesIntent: AppIntent {
    static let title: LocalizedStringResource = "壓縮圖片"
    static let description = IntentDescription("在裝置上壓縮圖片。")

    @Parameter(title: "圖片", supportedContentTypes: [.image])
    var files: [IntentFile]

    @Parameter(title: "品質（%）", default: 70, inclusiveRange: (10, 100))
    var quality: Int

    @Parameter(title: "最長邊（px，0 = 原尺寸）", default: 0)
    var maxDimension: Int

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let outputs = try await IntentRunner.run("image.compress", files: files, values: [
            "quality": .number(Double(quality)),
            "maxDimension": .string(String(maxDimension)),
        ])
        return .result(value: outputs)
    }
}

struct ConvertImagesIntent: AppIntent {
    static let title: LocalizedStringResource = "轉換圖片格式"
    static let description = IntentDescription("把圖片轉成 JPG、PNG、HEIC 或 TIFF。")

    @Parameter(title: "圖片", supportedContentTypes: [.image])
    var files: [IntentFile]

    @Parameter(title: "格式", default: .jpg)
    var format: ImageFormatChoice

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let outputs = try await IntentRunner.run("image.convert", files: files, values: ["format": .string(format.rawValue)])
        return .result(value: outputs)
    }
}

struct CropImagesIntent: AppIntent {
    static let title: LocalizedStringResource = "裁切圖片比例"
    static let description = IntentDescription("從中間裁成指定比例，例如 XPan 或 4:5。")

    @Parameter(title: "圖片", supportedContentTypes: [.image])
    var files: [IntentFile]

    @Parameter(title: "比例", default: .xpan)
    var ratio: CropRatioChoice

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let outputs = try await IntentRunner.run("image.crop", files: files, values: ["ratio": .string(ratio.ratio)])
        return .result(value: outputs)
    }
}

struct RemoveLocationIntent: AppIntent {
    static let title: LocalizedStringResource = "移除照片位置"
    static let description = IntentDescription("移除 GPS 位置資訊，不重新壓縮。")

    @Parameter(title: "圖片", supportedContentTypes: [.image])
    var files: [IntentFile]

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let outputs = try await IntentRunner.run("image.stripMetadata", files: files, values: ["mode": .string("gps")])
        return .result(value: outputs)
    }
}

struct ImagesToPDFIntent: AppIntent {
    static let title: LocalizedStringResource = "圖片合成 PDF"
    static let description = IntentDescription("依順序把圖片合成一個 PDF。")

    @Parameter(title: "圖片", supportedContentTypes: [.image])
    var files: [IntentFile]

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let outputs = try await IntentRunner.run("image.toPDF", files: files)
        guard let first = outputs.first else { throw ToolError("沒有產生 PDF") }
        return .result(value: first)
    }
}

// MARK: - 影片與音訊

struct CompressVideoIntent: AppIntent {
    static let title: LocalizedStringResource = "壓縮影片"
    static let description = IntentDescription("降低解析度與檔案大小。")

    @Parameter(title: "影片", supportedContentTypes: [.movie])
    var files: [IntentFile]

    @Parameter(title: "解析度", default: .q720)
    var quality: VideoQualityChoice

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let outputs = try await IntentRunner.run("video.compress", files: files, values: ["quality": .string(quality.rawValue)])
        return .result(value: outputs)
    }
}

struct ConvertAudioIntent: AppIntent {
    static let title: LocalizedStringResource = "轉換音訊格式"
    static let description = IntentDescription("轉成 M4A、無損 ALAC、WAV 或 AIFF。")

    @Parameter(title: "音訊", supportedContentTypes: [.audio])
    var files: [IntentFile]

    @Parameter(title: "格式", default: .m4a)
    var format: AudioFormatChoice

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let outputs = try await IntentRunner.run("audio.convert", files: files, values: ["format": .string(format.rawValue)])
        return .result(value: outputs)
    }
}

// MARK: - PDF

struct PDFToMarkdownIntent: AppIntent {
    static let title: LocalizedStringResource = "PDF 轉 Markdown"
    static let description = IntentDescription("把 PDF 轉成 Markdown 文字，掃描檔會自動辨識文字。")

    @Parameter(title: "PDF", supportedContentTypes: [.pdf])
    var file: IntentFile

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let outputs = try await IntentRunner.run("pdf.toMarkdown", files: [file])
        guard let url = outputs.first?.fileURL else { throw ToolError("轉換失敗") }
        let text = try String(contentsOf: url, encoding: .utf8)
        return .result(value: text)
    }
}

struct MergePDFIntent: AppIntent {
    static let title: LocalizedStringResource = "合併 PDF"
    static let description = IntentDescription("依順序合併多個 PDF。")

    @Parameter(title: "PDF", supportedContentTypes: [.pdf])
    var files: [IntentFile]

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let outputs = try await IntentRunner.run("pdf.merge", files: files)
        guard let first = outputs.first else { throw ToolError("沒有產生 PDF") }
        return .result(value: first)
    }
}

// MARK: - 任何工具（含功能包）

struct ToolEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "工具"
    static let defaultQuery = ToolQuery()

    let id: String
    let title: String
    let subtitle: String

    init(op: any ToolOperation) {
        id = op.id
        title = op.title
        subtitle = op.subtitle
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)")
    }
}

struct ToolQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ToolEntity] {
        Registry.all().filter { identifiers.contains($0.id) }.map { ToolEntity(op: $0) }
    }

    func suggestedEntities() async throws -> [ToolEntity] {
        Registry.all().map { ToolEntity(op: $0) }
    }
}

struct RunToolIntent: AppIntent {
    static let title: LocalizedStringResource = "執行工具或功能包"
    static let description = IntentDescription("用預設設定執行任何工具，也包含匯入的功能包。")

    @Parameter(title: "工具")
    var tool: ToolEntity

    @Parameter(title: "檔案")
    var files: [IntentFile]

    static var parameterSummary: some ParameterSummary {
        Summary("用 \(\.$tool) 處理 \(\.$files)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let outputs = try await IntentRunner.run(tool.id, files: files)
        return .result(value: outputs)
    }
}

// MARK: - Siri 與捷徑 App 的預設捷徑

struct ToolboxShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CompressImagesIntent(),
                    phrases: ["用\(.applicationName)壓縮圖片", "\(.applicationName)壓縮照片"],
                    shortTitle: "壓縮圖片", systemImageName: "arrow.down.right.and.arrow.up.left")
        AppShortcut(intent: ConvertImagesIntent(),
                    phrases: ["用\(.applicationName)轉換圖片格式", "\(.applicationName)轉圖片"],
                    shortTitle: "轉換圖片", systemImageName: "photo")
        AppShortcut(intent: CropImagesIntent(),
                    phrases: ["用\(.applicationName)裁切圖片", "\(.applicationName)裁成 XPan"],
                    shortTitle: "裁切比例", systemImageName: "crop")
        AppShortcut(intent: CompressVideoIntent(),
                    phrases: ["用\(.applicationName)壓縮影片"],
                    shortTitle: "壓縮影片", systemImageName: "film")
        AppShortcut(intent: ConvertAudioIntent(),
                    phrases: ["用\(.applicationName)轉換音訊"],
                    shortTitle: "轉換音訊", systemImageName: "waveform")
        AppShortcut(intent: PDFToMarkdownIntent(),
                    phrases: ["用\(.applicationName)把 PDF 轉 Markdown"],
                    shortTitle: "PDF 轉 Markdown", systemImageName: "doc.plaintext")
        AppShortcut(intent: MergePDFIntent(),
                    phrases: ["用\(.applicationName)合併 PDF"],
                    shortTitle: "合併 PDF", systemImageName: "doc.on.doc")
        AppShortcut(intent: RunToolIntent(),
                    phrases: ["用\(.applicationName)執行功能包"],
                    shortTitle: "執行工具", systemImageName: "puzzlepiece.extension")
    }
}
