import Foundation

enum Registry {
    /// 內建積木。順序就是動作清單的顯示順序。
    static let builtIns: [any ToolOperation] = [
        // 圖片
        ImageCropOp(),
        ImageConvertOp(),
        ImageCompressOp(),
        ImageResizeOp(),
        ImageStripMetadataOp(),
        ImagesToPDFOp(),
        // 影片
        VideoCompressOp(),
        VideoConvertOp(),
        VideoTrimOp(),
        VideoExtractAudioOp(),
        VideoToGIFOp(),
        // 音訊
        AudioConvertOp(),
        AudioCompressOp(),
        AudioSplitOp(),
        AudioMergeOp(),
        AudioRingtoneOp(),
        // PDF
        PDFToMarkdownOp(),
        PDFMergeOp(),
        PDFSplitOp(),
        PDFToImagesOp(),
    ]

    static func all() -> [any ToolOperation] {
        builtIns + PackStore.loadAll().map { RecipeOperation(pack: $0) }
    }

    static func operation(id: String) -> (any ToolOperation)? {
        all().first { $0.id == id }
    }

    static func builtIn(id: String) -> (any ToolOperation)? {
        builtIns.first { $0.id == id }
    }

    static func available(for kinds: [FileKind]) -> [any ToolOperation] {
        all().filter { $0.isAvailable(for: kinds) }
    }
}
