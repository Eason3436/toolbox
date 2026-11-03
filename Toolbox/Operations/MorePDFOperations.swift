import Foundation
import PDFKit
import UIKit

enum PDFTools {
    static func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw ToolError("無法開啟：\(url.lastPathComponent)") }
        if doc.isLocked { throw ToolError("\(url.lastPathComponent) 有密碼保護，請先用「移除密碼」") }
        return doc
    }

    /// 「1-3, 5」→ 從 0 開始的頁碼。空字串代表全部。
    static func pages(_ text: String, count: Int) -> [Int] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return Array(0..<count) }
        var seen = Set<Int>()
        var result: [Int] = []
        for range in PDFSplitOp.parse(trimmed, pageCount: count) {
            for n in range where seen.insert(n - 1).inserted { result.append(n - 1) }
        }
        return result
    }

    static func write(_ doc: PDFDocument, to url: URL, options: [PDFDocumentWriteOption: Any] = [:]) throws {
        guard doc.write(to: url, withOptions: options) else { throw ToolError("PDF 寫入失敗") }
    }

    static let pagesSpec = ParameterSpec.text("pages", "頁碼", default: "", placeholder: "留空代表全部，例如 1-3, 5",
                                              footer: "「8-」代表第 8 頁到最後。")
}

// MARK: - 壓縮

struct PDFCompressOp: ToolOperation {
    let id = "pdf.compress"
    let title = "壓縮"
    let subtitle = "縮小裡面的圖片，文字不變"
    let systemImage = "arrow.down.right.and.arrow.up.left"
    let accepts: Set<FileKind> = [.pdf]
    var parameters: [ParameterSpec] {
        [
            .choice("mode", "方式", [("smart", "保留文字"), ("strong", "強力壓縮")], default: "smart",
                    footer: "強力壓縮會把每頁變成圖片，檔案最小，但文字無法再選取或搜尋。"),
            .choice("quality", "品質", [("0.75", "高"), ("0.55", "中"), ("0.35", "低")], default: "0.55",
                    showIf: ["mode": "strong"]),
            .choice("dpi", "解析度", [("150", "150 dpi"), ("110", "110 dpi"), ("80", "80 dpi")], default: "110",
                    showIf: ["mode": "strong"]),
        ]
    }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        let strong = params.string("mode", "smart") == "strong"
        let quality = CGFloat(Double(params.string("quality", "0.55")) ?? 0.55)
        let dpi = CGFloat(Double(params.string("dpi", "110")) ?? 110)
        return try await eachInput(inputs, context) { input in
            let doc = try PDFTools.open(input)
            let out = context.output(for: input, suffix: "_small", ext: "pdf")
            if !strong {
                try PDFTools.write(doc, to: out, options: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true])
                return [out]
            }
            let first = doc.page(at: 0)?.bounds(for: .cropBox) ?? CGRect(x: 0, y: 0, width: 595, height: 842)
            let renderer = UIGraphicsPDFRenderer(bounds: first)
            let scale = dpi / 72
            let data = try renderer.pdfData { ctx in
                for index in 0..<doc.pageCount {
                    guard let page = doc.page(at: index) else { continue }
                    context.report("第 \(index + 1)/\(doc.pageCount) 頁")
                    ProgressScope.report?(Double(index) / Double(doc.pageCount))
                    let bounds = page.bounds(for: .cropBox)
                    let rotated = page.rotation % 180 != 0
                    let size = rotated ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
                    let image = page.thumbnail(of: CGSize(width: size.width * scale, height: size.height * scale), for: .cropBox)
                    guard let jpeg = image.jpegData(compressionQuality: quality), let small = UIImage(data: jpeg) else { continue }
                    ctx.beginPage(withBounds: CGRect(origin: .zero, size: size), pageInfo: [:])
                    small.draw(in: CGRect(origin: .zero, size: size))
                }
            }
            try data.write(to: out, options: .atomic)
            return [out]
        }
    }
}

// MARK: - 加密碼／移除密碼

struct PDFEncryptOp: ToolOperation {
    let id = "pdf.encrypt"
    let title = "加上密碼"
    let subtitle = "開啟檔案時要輸入密碼"
    let systemImage = "lock"
    let accepts: Set<FileKind> = [.pdf]
    var parameters: [ParameterSpec] {
        [.text("password", "密碼", default: "", placeholder: "輸入密碼")]
    }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        let password = params.string("password", "")
        guard !password.isEmpty else { throw ToolError("請輸入密碼") }
        return try await eachInput(inputs, context) { input in
            let doc = try PDFTools.open(input)
            let out = context.output(for: input, suffix: "_locked", ext: "pdf")
            try PDFTools.write(doc, to: out, options: [.userPasswordOption: password, .ownerPasswordOption: password])
            return [out]
        }
    }
}

struct PDFDecryptOp: ToolOperation {
    let id = "pdf.decrypt"
    let title = "移除密碼"
    let subtitle = "輸入一次密碼，存成不用密碼的 PDF"
    let systemImage = "lock.open"
    let accepts: Set<FileKind> = [.pdf]
    var parameters: [ParameterSpec] {
        [.text("password", "密碼", default: "", placeholder: "目前的密碼")]
    }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        let password = params.string("password", "")
        return try await eachInput(inputs, context) { input in
            guard let doc = PDFDocument(url: input) else { throw ToolError("無法開啟：\(input.lastPathComponent)") }
            if doc.isLocked && !doc.unlock(withPassword: password) {
                throw ToolError("\(input.lastPathComponent) 的密碼不正確")
            }
            let copy = PDFDocument()
            for index in 0..<doc.pageCount {
                if let page = doc.page(at: index)?.copy() as? PDFPage { copy.insert(page, at: copy.pageCount) }
            }
            let out = context.output(for: input, suffix: "_unlocked", ext: "pdf")
            try PDFTools.write(copy, to: out)
            return [out]
        }
    }
}

// MARK: - 旋轉頁面

struct PDFRotateOp: ToolOperation {
    let id = "pdf.rotate"
    let title = "旋轉頁面"
    let subtitle = "轉正掃描歪掉的頁面"
    let systemImage = "rotate.right"
    let accepts: Set<FileKind> = [.pdf]
    let editor: OperationEditor = .pages
    var parameters: [ParameterSpec] {
        [
            PDFTools.pagesSpec,
            .choice("angle", "方向", [("90", "向右 90°"), ("270", "向左 90°"), ("180", "180°")], default: "90"),
        ]
    }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        let angle = Int(params.string("angle", "90")) ?? 90
        return try await eachInput(inputs, context) { input in
            let doc = try PDFTools.open(input)
            let pages = PDFTools.pages(params.string("pages", ""), count: doc.pageCount)
            guard !pages.isEmpty else { throw ToolError("沒有選到任何頁面") }
            for index in pages {
                if let page = doc.page(at: index) { page.rotation = (page.rotation + angle) % 360 }
            }
            let out = context.output(for: input, suffix: "_rotated", ext: "pdf")
            try PDFTools.write(doc, to: out)
            return [out]
        }
    }
}

// MARK: - 選取／刪除頁面

struct PDFPickPagesOp: ToolOperation {
    let id = "pdf.pickPages"
    let title = "選取或刪除頁面"
    let subtitle = "只留下需要的頁面，或刪掉不要的"
    let systemImage = "checklist"
    let accepts: Set<FileKind> = [.pdf]
    let editor: OperationEditor = .pages
    var parameters: [ParameterSpec] {
        [
            PDFTools.pagesSpec,
            .choice("mode", "選到的頁面", [("keep", "保留"), ("delete", "刪除")], default: "keep"),
        ]
    }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        let keep = params.string("mode", "keep") == "keep"
        return try await eachInput(inputs, context) { input in
            let doc = try PDFTools.open(input)
            let selected = Set(PDFTools.pages(params.string("pages", ""), count: doc.pageCount))
            let wanted = (0..<doc.pageCount).filter { keep ? selected.contains($0) : !selected.contains($0) }
            guard !wanted.isEmpty else { throw ToolError(keep ? "沒有選到任何頁面" : "不能把每一頁都刪掉") }
            let result = PDFDocument()
            for index in wanted {
                if let page = doc.page(at: index)?.copy() as? PDFPage { result.insert(page, at: result.pageCount) }
            }
            let out = context.output(for: input, suffix: "_\(wanted.count)頁", ext: "pdf")
            try PDFTools.write(result, to: out)
            return [out]
        }
    }
}

// MARK: - 轉成純文字

struct PDFToTextOp: ToolOperation {
    let id = "pdf.toText"
    let title = "轉成純文字"
    let subtitle = "取出所有文字，掃描檔會自動辨識"
    let systemImage = "doc.plaintext"
    let accepts: Set<FileKind> = [.pdf]
    var parameters: [ParameterSpec] {
        [.toggle("ocr", "沒有文字的頁面自動辨識（OCR）", default: true)]
    }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        let ocr = params.bool("ocr", true)
        return try await eachInput(inputs, context) { input in
            let doc = try PDFTools.open(input)
            var pages: [String] = []
            for index in 0..<doc.pageCount {
                try Task.checkCancellation()
                guard let page = doc.page(at: index) else { continue }
                context.report("第 \(index + 1)/\(doc.pageCount) 頁")
                ProgressScope.report?(Double(index) / Double(Swift.max(doc.pageCount, 1)))
                var text = page.string ?? ""
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && ocr {
                    text = try MarkdownConverter.recognizeLines(on: page).map(\.text).joined(separator: "\n")
                }
                pages.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            let out = context.output(for: input, ext: "txt")
            try TextIO.write(pages.joined(separator: "\n\n"), to: out)
            return [out]
        }
    }
}
