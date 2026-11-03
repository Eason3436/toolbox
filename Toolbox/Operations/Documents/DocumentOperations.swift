import Foundation
import UIKit

// MARK: - 共用：把各種文件載入排版器

@MainActor
enum DocumentJobs {
    static func withRenderer<T>(width: CGFloat = 794, _ body: (WebRenderer) async throws -> T) async throws -> T {
        let renderer = WebRenderer(width: width)
        defer { renderer.close() }
        return try await body(renderer)
    }

    static func load(_ url: URL, into renderer: WebRenderer) async throws {
        let title = url.deletingPathExtension().lastPathComponent
        switch FileKind.detect(url) {
        case .markdown:
            try await renderer.load(html: HTML.fromMarkdown(try TextIO.text(url), title: title),
                                    baseURL: url.deletingLastPathComponent())
        case .html:
            try await renderer.load(file: url)
        case .csv:
            try await renderer.load(html: HTML.table(CSV.parse(try TextIO.text(url)), title: title), baseURL: nil)
        case .rtf:
            try await renderer.load(html: try rtfHTML(url), baseURL: nil)
        case .office:
            try await renderer.load(file: url, settleSeconds: 1.8)
        case .json:
            try await renderer.load(html: HTML.document(title: title, body: "<pre><code>\(HTML.escape(JSONTools.pretty(try Data(contentsOf: url))))</code></pre>"),
                                    baseURL: nil)
        default:
            try await renderer.load(html: HTML.fromPlainText(try TextIO.text(url), title: title), baseURL: nil)
        }
    }

    static func rtfHTML(_ url: URL) throws -> String {
        let attributed = try NSAttributedString(url: url, options: [:], documentAttributes: nil)
        let data = try attributed.data(from: NSRange(location: 0, length: attributed.length),
                                       documentAttributes: [.documentType: NSAttributedString.DocumentType.html])
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func pdf(_ url: URL, paper: WebRenderer.Paper, margin: CGFloat) async throws -> Data {
        try await withRenderer { r in
            try await load(url, into: r)
            let data = r.pdf(paper: paper, margin: margin)
            guard data.count > 0 else { throw ToolError("排版失敗：\(url.lastPathComponent)") }
            return data
        }
    }

    static func image(_ url: URL, pixelWidth: CGFloat) async throws -> UIImage {
        try await withRenderer(width: 800) { r in
            try await load(url, into: r)
            return try await r.snapshot(pixelWidth: pixelWidth)
        }
    }

    static func text(_ url: URL) async throws -> String {
        switch FileKind.detect(url) {
        case .text, .csv: return try TextIO.text(url)
        case .rtf: return try NSAttributedString(url: url, options: [:], documentAttributes: nil).string
        default:
            return try await withRenderer { r in
                try await load(url, into: r)
                return try await r.text()
            }
        }
    }

    /// 任何文件 → Markdown 原始碼。
    static func markdown(_ url: URL) async throws -> String {
        switch FileKind.detect(url) {
        case .markdown:
            return try TextIO.text(url)
        case .csv:
            return CSV.markdownTable(CSV.parse(try TextIO.text(url)))
        case .json:
            return "```json\n" + JSONTools.pretty(try Data(contentsOf: url)) + "\n```\n"
        case .text:
            return try TextIO.text(url)
        default:
            return try await withRenderer { r in
                try await load(url, into: r)
                return try await r.markdown()
            }
        }
    }

    /// Word 用的區塊：純文字檔每段照原樣，不套 Markdown 語法。
    static func blocks(_ url: URL) async throws -> [MD.Block] {
        if FileKind.detect(url) == .text {
            let text = try TextIO.text(url).replacingOccurrences(of: "\r\n", with: "\n")
            return text.components(separatedBy: "\n\n").map { paragraph -> MD.Block in
                var inlines: [MD.Inline] = []
                for (index, line) in paragraph.components(separatedBy: "\n").enumerated() {
                    if index > 0 { inlines.append(.lineBreak) }
                    inlines.append(.text(line))
                }
                return .paragraph(inlines)
            }
        }
        return MD.parse(try await markdown(url))
    }
}

private let paperOptions: [(String, String)] = [("a4", "A4"), ("letter", "Letter")]
private let marginOptions: [(String, String)] = [("36", "窄"), ("54", "標準"), ("72", "寬")]

// MARK: - 轉成 PDF

struct DocToPDFOp: ToolOperation {
    let id = "doc.toPDF"
    let title = "轉成 PDF"
    let subtitle = "排版成可以列印、分享的文件"
    let systemImage = "doc.richtext"
    let accepts: Set<FileKind> = FileKind.documents
    var parameters: [ParameterSpec] {
        [
            .choice("paper", "紙張", paperOptions, default: "a4"),
            .choice("margin", "邊界", marginOptions, default: "54"),
        ]
    }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        let paper = WebRenderer.Paper(rawValue: params.string("paper", "a4")) ?? .a4
        let margin = CGFloat(params.double("margin", 54))
        return try await eachInput(inputs, context) { input in
            let data = try await DocumentJobs.pdf(input, paper: paper, margin: margin)
            let out = context.output(for: input, ext: "pdf")
            try data.write(to: out, options: .atomic)
            return [out]
        }
    }
}

// MARK: - 轉成 Word

struct DocToWordOp: ToolOperation {
    let id = "doc.toWord"
    let title = "轉成 Word"
    let subtitle = "保留標題、清單、表格，輸出 DOCX"
    let systemImage = "doc.text"
    let accepts: Set<FileKind> = [.markdown, .html, .text, .rtf, .csv, .json]
    var parameters: [ParameterSpec] { [] }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        try await eachInput(inputs, context) { input in
            let blocks = try await DocumentJobs.blocks(input)
            let out = context.output(for: input, ext: "docx")
            try DocxWriter.write(blocks, to: out)
            return [out]
        }
    }
}

// MARK: - 轉成 Markdown

struct DocToMarkdownOp: ToolOperation {
    let id = "doc.toMarkdown"
    let title = "轉 Markdown"
    let subtitle = "網頁、Word、RTF、表格轉成 Markdown"
    let systemImage = "number"
    let accepts: Set<FileKind> = [.html, .rtf, .office, .csv, .json]
    var parameters: [ParameterSpec] { [] }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        try await eachInput(inputs, context) { input in
            let markdown = try await DocumentJobs.markdown(input)
            guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ToolError("\(input.lastPathComponent) 裡沒有讀到文字")
            }
            let out = context.output(for: input, ext: "md")
            try TextIO.write(markdown, to: out)
            return [out]
        }
    }
}

// MARK: - 轉成 HTML

struct DocToHTMLOp: ToolOperation {
    let id = "doc.toHTML"
    let title = "轉成網頁"
    let subtitle = "輸出排版好的 HTML"
    let systemImage = "chevron.left.forwardslash.chevron.right"
    let accepts: Set<FileKind> = [.markdown, .text, .rtf, .csv, .json]
    var parameters: [ParameterSpec] {
        [.toggle("styled", "加上排版樣式", default: true, footer: "關閉時只輸出內容，方便貼到部落格或網站後台。")]
    }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        let styled = params.bool("styled", true)
        return try await eachInput(inputs, context) { input in
            let title = input.deletingPathExtension().lastPathComponent
            let html: String
            switch FileKind.detect(input) {
            case .markdown:
                let body = HTML.render(MD.parse(try TextIO.text(input)))
                html = styled ? HTML.document(title: title, body: body) : body + "\n"
            case .csv:
                html = HTML.table(CSV.parse(try TextIO.text(input)), title: title)
            case .rtf:
                html = try await DocumentJobs.rtfHTML(input)
            case .json:
                let body = "<pre><code>\(HTML.escape(JSONTools.pretty(try Data(contentsOf: input))))</code></pre>"
                html = styled ? HTML.document(title: title, body: body) : body
            default:
                let text = try TextIO.text(input)
                html = styled ? HTML.fromPlainText(text, title: title) : "<pre>\(HTML.escape(text))</pre>\n"
            }
            let out = context.output(for: input, ext: "html")
            try TextIO.write(html, to: out)
            return [out]
        }
    }
}

// MARK: - 轉成純文字

struct DocToTextOp: ToolOperation {
    let id = "doc.toText"
    let title = "轉成純文字"
    let subtitle = "拿掉格式，只留下文字（TXT）"
    let systemImage = "doc.plaintext"
    let accepts: Set<FileKind> = [.markdown, .html, .rtf, .office, .json]
    var parameters: [ParameterSpec] { [] }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        try await eachInput(inputs, context) { input in
            let text = try await DocumentJobs.text(input)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ToolError("\(input.lastPathComponent) 裡沒有讀到文字")
            }
            let out = context.output(for: input, ext: "txt")
            try TextIO.write(text, to: out)
            return [out]
        }
    }
}

// MARK: - 轉成長圖

struct DocToImageOp: ToolOperation {
    let id = "doc.toImage"
    let title = "轉成長圖"
    let subtitle = "整份文件拼成一張圖，方便傳訊息"
    let systemImage = "photo"
    let accepts: Set<FileKind> = FileKind.documents
    var parameters: [ParameterSpec] {
        [
            .choice("width", "寬度", [("1080", "1080 px"), ("1600", "1600 px"), ("2400", "2400 px")], default: "1600"),
            .choice("format", "格式", [("jpg", "JPG"), ("png", "PNG")], default: "jpg"),
        ]
    }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        let width = CGFloat(params.double("width", 1600))
        let png = params.string("format", "jpg") == "png"
        return try await eachInput(inputs, context) { input in
            let image = try await DocumentJobs.image(input, pixelWidth: width)
            guard let data = png ? image.pngData() : image.jpegData(compressionQuality: 0.88) else {
                throw ToolError("圖片輸出失敗")
            }
            let out = context.output(for: input, ext: png ? "png" : "jpg")
            try data.write(to: out, options: .atomic)
            return [out]
        }
    }
}

// MARK: - 繁簡轉換

struct ChineseConvertOp: ToolOperation {
    let id = "text.chinese"
    let title = "繁簡轉換"
    let subtitle = "簡體轉繁體，或繁體轉簡體"
    let systemImage = "character.book.closed"
    let accepts: Set<FileKind> = [.text, .markdown, .html, .csv, .json]
    var parameters: [ParameterSpec] {
        [.choice("to", "轉成", [("hant", "繁體"), ("hans", "簡體")], default: "hant")]
    }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        let toTraditional = params.string("to", "hant") == "hant"
        return try await eachInput(inputs, context) { input in
            let text = try TextIO.text(input)
            guard let converted = text.applyingTransform(StringTransform("Hans-Hant"), reverse: !toTraditional) else {
                throw ToolError("這台裝置不支援繁簡轉換")
            }
            let out = context.output(for: input, suffix: toTraditional ? "_繁" : "_简", ext: input.pathExtension.isEmpty ? "txt" : input.pathExtension)
            try TextIO.write(converted, to: out)
            return [out]
        }
    }
}

// MARK: - 修正亂碼（轉成 UTF-8）

struct TextEncodingOp: ToolOperation {
    let id = "text.toUTF8"
    let title = "修正亂碼"
    let subtitle = "Big5、GB 等舊編碼轉成 UTF-8"
    let systemImage = "textformat"
    let accepts: Set<FileKind> = [.text, .markdown, .html, .csv]
    var parameters: [ParameterSpec] {
        [.choice("from", "原本的編碼", [("auto", "自動判斷"), ("big5", "Big5（繁中）"), ("gb", "GB18030（簡中）"),
                                         ("sjis", "Shift JIS（日文）")], default: "auto")]
    }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        let choice = params.string("from", "auto")
        return try await eachInput(inputs, context) { input in
            let text: String
            switch choice {
            case "big5", "gb", "sjis":
                let encoding = choice == "big5" ? TextIO.big5 : (choice == "gb" ? TextIO.gb18030 : .shiftJIS)
                guard let decoded = String(data: try Data(contentsOf: input), encoding: encoding) else {
                    throw ToolError("\(input.lastPathComponent) 不是這種編碼")
                }
                text = decoded
            default:
                let result = try TextIO.read(input)
                text = result.text
                context.report("偵測到 \(TextIO.name(of: result.encoding))")
            }
            let out = context.output(for: input, suffix: "_utf8", ext: input.pathExtension.isEmpty ? "txt" : input.pathExtension)
            try TextIO.write(text, to: out)
            return [out]
        }
    }
}

// MARK: - CSV／JSON

enum JSONTools {
    static func pretty(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let out = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]),
              let text = String(data: out, encoding: .utf8) else {
            return String(data: data, encoding: .utf8) ?? ""
        }
        return text
    }

    static func string(_ value: Any) -> String {
        switch value {
        case is NSNull: return ""
        case let s as String: return s
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        default:
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes, .sortedKeys]) {
                return String(data: data, encoding: .utf8) ?? ""
            }
            return "\(value)"
        }
    }
}

struct CSVToExcelOp: ToolOperation {
    let id = "csv.toExcel"
    let title = "轉成 Excel"
    let subtitle = "輸出 XLSX，數字會變成可以計算的儲存格"
    let systemImage = "tablecells"
    let accepts: Set<FileKind> = [.csv]
    var parameters: [ParameterSpec] { [] }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        try await eachInput(inputs, context) { input in
            let rows = CSV.parse(try TextIO.text(input))
            let out = context.output(for: input, ext: "xlsx")
            try XlsxWriter.write(rows, sheetName: input.deletingPathExtension().lastPathComponent, to: out)
            return [out]
        }
    }
}

struct CSVToJSONOp: ToolOperation {
    let id = "csv.toJSON"
    let title = "轉成 JSON"
    let subtitle = "第一列當欄位名稱"
    let systemImage = "curlybraces"
    let accepts: Set<FileKind> = [.csv]
    var parameters: [ParameterSpec] {
        [.toggle("header", "第一列是欄位名稱", default: true)]
    }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        let header = params.bool("header", true)
        return try await eachInput(inputs, context) { input in
            let rows = CSV.parse(try TextIO.text(input))
            let object: Any
            if header, let keys = rows.first {
                object = rows.dropFirst().map { row -> [String: String] in
                    var item: [String: String] = [:]
                    for (index, key) in keys.enumerated() { item[key.isEmpty ? "欄\(index + 1)" : key] = index < row.count ? row[index] : "" }
                    return item
                }
            } else {
                object = rows
            }
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])
            let out = context.output(for: input, ext: "json")
            try data.write(to: out, options: .atomic)
            return [out]
        }
    }
}

struct JSONToCSVOp: ToolOperation {
    let id = "json.toCSV"
    let title = "轉成 CSV／Excel"
    let subtitle = "物件陣列轉成表格"
    let systemImage = "tablecells"
    let accepts: Set<FileKind> = [.json]
    var parameters: [ParameterSpec] {
        [.choice("format", "格式", [("csv", "CSV"), ("xlsx", "Excel")], default: "csv")]
    }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        let xlsx = params.string("format", "csv") == "xlsx"
        return try await eachInput(inputs, context) { input in
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: input), options: [.fragmentsAllowed])
            var items: [Any]
            if let array = object as? [Any] {
                items = array
            } else if let dict = object as? [String: Any],
                      let inner = dict.values.first(where: { $0 is [Any] }) as? [Any], dict.count <= 3 {
                items = inner
            } else {
                items = [object]
            }
            var rows: [[String]]
            if items.allSatisfy({ $0 is [String: Any] }) {
                var keys: [String] = []
                for case let item as [String: Any] in items {
                    for key in item.keys.sorted() where !keys.contains(key) { keys.append(key) }
                }
                rows = [keys]
                for case let item as [String: Any] in items {
                    rows.append(keys.map { item[$0].map(JSONTools.string) ?? "" })
                }
            } else if items.allSatisfy({ $0 is [Any] }) {
                rows = items.compactMap { ($0 as? [Any])?.map(JSONTools.string) }
            } else {
                rows = [["value"]] + items.map { [JSONTools.string($0)] }
            }
            let out = context.output(for: input, ext: xlsx ? "xlsx" : "csv")
            if xlsx {
                try XlsxWriter.write(rows, sheetName: input.deletingPathExtension().lastPathComponent, to: out)
            } else {
                try Data(("\u{FEFF}" + CSV.write(rows)).utf8).write(to: out, options: .atomic)
            }
            return [out]
        }
    }
}

struct JSONFormatOp: ToolOperation {
    let id = "json.format"
    let title = "整理 JSON"
    let subtitle = "排版成好讀的格式，或壓成一行"
    let systemImage = "text.alignleft"
    let accepts: Set<FileKind> = [.json]
    var parameters: [ParameterSpec] {
        [
            .choice("mode", "方式", [("pretty", "排版"), ("minify", "壓成一行")], default: "pretty"),
            .toggle("sort", "依欄位名稱排序", default: true),
        ]
    }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        let pretty = params.string("mode", "pretty") == "pretty"
        let sort = params.bool("sort", true)
        return try await eachInput(inputs, context) { input in
            let object: Any
            do {
                object = try JSONSerialization.jsonObject(with: Data(contentsOf: input), options: [.fragmentsAllowed])
            } catch {
                throw ToolError("\(input.lastPathComponent) 不是正確的 JSON")
            }
            var options: JSONSerialization.WritingOptions = [.withoutEscapingSlashes, .fragmentsAllowed]
            if pretty { options.insert(.prettyPrinted) }
            if sort { options.insert(.sortedKeys) }
            let data = try JSONSerialization.data(withJSONObject: object, options: options)
            let out = context.output(for: input, suffix: pretty ? "_pretty" : "_min", ext: "json")
            try data.write(to: out, options: .atomic)
            return [out]
        }
    }
}

// MARK: - 任何檔案

struct ZipOp: ToolOperation {
    let id = "any.zip"
    let title = "壓縮成 ZIP"
    let subtitle = "把所有檔案打包成一個 ZIP"
    let systemImage = "archivebox"
    let accepts: Set<FileKind> = Set(FileKind.allCases)
    var parameters: [ParameterSpec] {
        [.text("name", "檔名", default: "封存", placeholder: "檔名")]
    }

    func isAvailable(for kinds: [FileKind]) -> Bool { !kinds.isEmpty }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        let name = params.string("name", "封存").trimmingCharacters(in: .whitespaces)
        let out = context.output(named: name.isEmpty ? "封存" : name, ext: "zip")
        var zip = try ZipWriter(url: out)
        var used = Set<String>()
        for (index, input) in inputs.enumerated() {
            try Task.checkCancellation()
            context.report("加入 \(index + 1)/\(inputs.count)：\(input.lastPathComponent)")
            ProgressScope.report?(Double(index) / Double(inputs.count))
            var entry = input.lastPathComponent
            var n = 2
            while used.contains(entry) {
                entry = input.deletingPathExtension().lastPathComponent + "-\(n)." + input.pathExtension
                n += 1
            }
            used.insert(entry)
            try zip.add(entry, file: input)
        }
        try zip.finish()
        ProgressScope.report?(1)
        return [out]
    }
}

struct RenameOp: ToolOperation {
    let id = "any.rename"
    let title = "批次重新命名"
    let subtitle = "依目前順序編號，例如「旅行_01」"
    let systemImage = "character.cursor.ibeam"
    let accepts: Set<FileKind> = Set(FileKind.allCases)
    var parameters: [ParameterSpec] {
        [
            .text("name", "檔名", default: "檔案", placeholder: "例如 旅行"),
            .number("start", "起始編號", range: 0...999, step: 1, default: 1),
            .choice("digits", "位數", [("1", "1"), ("2", "01"), ("3", "001")], default: "2"),
        ]
    }

    func isAvailable(for kinds: [FileKind]) -> Bool { !kinds.isEmpty }

    func run(inputs: [URL], params: Params, context: RunContext) async throws -> [URL] {
        let base = params.string("name", "檔案").trimmingCharacters(in: .whitespaces)
        let start = params.int("start", 1)
        let digits = params.int("digits", 2)
        var outputs: [URL] = []
        for (index, input) in inputs.enumerated() {
            let number = String(format: "%0\(digits)ld", start + index)
            let out = context.output(named: "\(base.isEmpty ? "檔案" : base)_\(number)", ext: input.pathExtension)
            try FileManager.default.copyItem(at: input, to: out)
            outputs.append(out)
        }
        return outputs
    }
}
