import Foundation
import PDFKit
import UIKit

// MARK: - 合併

struct PDFMergeOp: ToolOperation {
    let id = "pdf.merge"
    let title = "合併"
    let subtitle = "依目前順序合成一個 PDF"
    let systemImage = "doc.on.doc"
    let accepts: Set<FileKind> = [.pdf]
    let minInputs = 2
    var parameters: [ParameterSpec] {
        [.text("name", "檔名", default: "合併文件", placeholder: "檔名")]
    }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        let merged = PDFDocument()
        for (index, input) in inputs.enumerated() {
            context.report("加入第 \(index + 1)/\(inputs.count) 個")
            guard let doc = PDFDocument(url: input) else { throw ToolError("無法開啟：\(input.lastPathComponent)") }
            if doc.isLocked { throw ToolError("\(input.lastPathComponent) 有密碼保護") }
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i)?.copy() as? PDFPage { merged.insert(page, at: merged.pageCount) }
            }
        }
        let name = params.string("name", "合併文件")
        let out = context.output(named: name.isEmpty ? "合併文件" : name, ext: "pdf")
        guard merged.write(to: out) else { throw ToolError("PDF 寫入失敗") }
        return [out]
    }
}

// MARK: - 拆分

struct PDFSplitOp: ToolOperation {
    let id = "pdf.split"
    let title = "拆分"
    let subtitle = "每頁一個檔，或依頁碼範圍拆開"
    let systemImage = "rectangle.split.3x1"
    let accepts: Set<FileKind> = [.pdf]
    var parameters: [ParameterSpec] {
        [
            .choice("mode", "方式", [("ranges", "依頁碼範圍"), ("each", "每頁一個檔")], default: "ranges"),
            .text("ranges", "頁碼", default: "1-3, 4-", placeholder: "例如 1-3, 5, 8-",
                  footer: "每個範圍輸出一個檔案。「8-」代表第 8 頁到最後。", showIf: ["mode": "ranges"]),
        ]
    }

    static func parse(_ text: String, pageCount: Int) -> [ClosedRange<Int>] {
        text.split(whereSeparator: { ",，、;".contains($0) }).compactMap { (token: Substring) -> ClosedRange<Int>? in
            let part = token.trimmingCharacters(in: .whitespaces)
            if part.isEmpty { return nil }
            let bounds = part.split(separator: "-", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let start: Int
            let end: Int
            if bounds.count == 1 {
                guard let n = Int(bounds[0]) else { return nil }
                start = n; end = n
            } else {
                start = Int(bounds[0]) ?? 1
                end = Int(bounds[1]) ?? pageCount
            }
            let s = Swift.max(1, start), e = Swift.min(pageCount, end)
            return s <= e ? s...e : nil
        }
    }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        try await eachInput(inputs, context) { input in
            guard let doc = PDFDocument(url: input) else { throw ToolError("無法開啟：\(input.lastPathComponent)") }
            let ranges: [ClosedRange<Int>]
            if params.string("mode", "ranges") == "each" {
                ranges = (1...Swift.max(doc.pageCount, 1)).map { $0...$0 }
            } else {
                ranges = Self.parse(params.string("ranges", ""), pageCount: doc.pageCount)
            }
            guard !ranges.isEmpty, doc.pageCount > 0 else { throw ToolError("頁碼範圍不正確（共 \(doc.pageCount) 頁）") }
            var outputs: [URL] = []
            for range in ranges {
                let part = PDFDocument()
                for number in range {
                    if let page = doc.page(at: number - 1)?.copy() as? PDFPage { part.insert(page, at: part.pageCount) }
                }
                let label = range.count == 1 ? "_p\(range.lowerBound)" : "_p\(range.lowerBound)-\(range.upperBound)"
                let out = context.output(for: input, suffix: label, ext: "pdf")
                guard part.write(to: out) else { throw ToolError("PDF 寫入失敗") }
                outputs.append(out)
            }
            return outputs
        }
    }
}

// MARK: - 轉圖片

struct PDFToImagesOp: ToolOperation {
    let id = "pdf.toImages"
    let title = "轉成圖片"
    let subtitle = "每頁輸出一張 JPG 或 PNG"
    let systemImage = "photo.on.rectangle"
    let accepts: Set<FileKind> = [.pdf]
    var parameters: [ParameterSpec] {
        [
            .choice("format", "格式", [("jpg", "JPG"), ("png", "PNG")], default: "jpg"),
            .choice("scale", "解析度", [("1", "標準（72 dpi）"), ("2", "高（144 dpi）"), ("3", "很高（216 dpi）")], default: "2"),
        ]
    }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        let png = params.string("format", "jpg") == "png"
        let scale = CGFloat(Double(params.string("scale", "2")) ?? 2)
        return try await eachInput(inputs, context) { input in
            guard let doc = PDFDocument(url: input) else { throw ToolError("無法開啟：\(input.lastPathComponent)") }
            var outputs: [URL] = []
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                context.report("第 \(i + 1)/\(doc.pageCount) 頁")
                let bounds = page.bounds(for: .mediaBox)
                let image = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
                guard let data = png ? image.pngData() : image.jpegData(compressionQuality: 0.9) else { continue }
                let out = context.output(for: input, suffix: String(format: "_%03d", i + 1), ext: png ? "png" : "jpg")
                try data.write(to: out, options: .atomic)
                outputs.append(out)
            }
            return outputs
        }
    }
}

// MARK: - 轉 Markdown

struct PDFToMarkdownOp: ToolOperation {
    let id = "pdf.toMarkdown"
    let title = "轉 Markdown"
    let subtitle = "保留標題層級與清單，掃描檔會自動辨識文字"
    let systemImage = "doc.plaintext"
    let accepts: Set<FileKind> = [.pdf]
    var parameters: [ParameterSpec] {
        [
            .toggle("ocr", "沒有文字的頁面自動辨識（OCR）", default: true),
            .toggle("pageBreaks", "頁與頁之間加分隔線", default: false),
        ]
    }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        try await eachInput(inputs, context) { input in
            guard let doc = PDFDocument(url: input) else { throw ToolError("無法開啟：\(input.lastPathComponent)") }
            let markdown = try await MarkdownConverter.convert(doc, ocr: params.bool("ocr", true),
                                                               pageBreaks: params.bool("pageBreaks", false),
                                                               report: context.report)
            let out = context.output(for: input, ext: "md")
            try markdown.write(to: out, atomically: true, encoding: .utf8)
            return [out]
        }
    }
}
