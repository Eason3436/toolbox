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
        ImageRotateOp(),
        ImageFilterOp(),
        ImageWatermarkOp(),
        ImageStitchOp(),
        ImagesToGIFOp(),
        ImageOCROp(),
        ImageRemoveBackgroundOp(),
        ImageBarcodeOp(),
        // 影片
        VideoCompressOp(),
        VideoConvertOp(),
        VideoTrimOp(),
        VideoExtractAudioOp(),
        VideoToGIFOp(),
        VideoMuteOp(),
        VideoRotateOp(),
        VideoSpeedOp(),
        VideoFramesOp(),
        VideoMergeOp(),
        // 音訊
        AudioConvertOp(),
        AudioCompressOp(),
        AudioSplitOp(),
        AudioMergeOp(),
        AudioRingtoneOp(),
        AudioTranscribeOp(),
        // PDF
        PDFToMarkdownOp(),
        PDFMergeOp(),
        PDFSplitOp(),
        PDFToImagesOp(),
        PDFCompressOp(),
        PDFPickPagesOp(),
        PDFRotateOp(),
        PDFToTextOp(),
        PDFEncryptOp(),
        PDFDecryptOp(),
        // 文件
        DocToPDFOp(),
        DocToWordOp(),
        DocToMarkdownOp(),
        DocToHTMLOp(),
        DocToTextOp(),
        DocToImageOp(),
        ChineseConvertOp(),
        TextEncodingOp(),
        CSVToExcelOp(),
        CSVToJSONOp(),
        JSONToCSVOp(),
        JSONFormatOp(),
        // 任何檔案
        ZipOp(),
        RenameOp(),
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
