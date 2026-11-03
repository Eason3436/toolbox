import Foundation
import UIKit

// MARK: - 文字檔讀取（自動判斷編碼）

enum TextIO {
    static let big5 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5_HKSCS_1999.rawValue)))
    static let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))

    /// 依序嘗試 UTF-8、系統猜測、Big5、GB18030、Shift JIS、UTF-16。
    static func read(_ url: URL) throws -> (text: String, encoding: String.Encoding) {
        let data = try Data(contentsOf: url)
        if let text = String(data: data, encoding: .utf8) { return (stripBOM(text), .utf8) }
        var guessed = String.Encoding.utf8.rawValue
        if let text = try? NSString(contentsOf: url, usedEncoding: &guessed) {
            return (text as String, String.Encoding(rawValue: guessed))
        }
        for encoding in [big5, gb18030, .shiftJIS, .utf16, .windowsCP1252] {
            if let text = String(data: data, encoding: encoding) { return (text, encoding) }
        }
        throw ToolError("看不懂 \(url.lastPathComponent) 的文字編碼")
    }

    static func text(_ url: URL) throws -> String { try read(url).text }

    private static func stripBOM(_ text: String) -> String {
        text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }

    static func name(of encoding: String.Encoding) -> String {
        switch encoding {
        case .utf8: return "UTF-8"
        case big5: return "Big5"
        case gb18030: return "GB18030"
        case .shiftJIS: return "Shift JIS"
        case .utf16, .utf16LittleEndian, .utf16BigEndian: return "UTF-16"
        default: return String.localizedName(of: encoding)
        }
    }

    static func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - HTML

enum HTML {
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for c in text {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(c)
            }
        }
        return out
    }

    /// 文件的排版樣式。寬度交給列印範圍決定，所以 body 不留邊界。
    static let css = """
    :root { color-scheme: light; }
    html { -webkit-text-size-adjust: 100%; }
    body { margin: 0; padding: 0; font-family: -apple-system, "PingFang TC", "Noto Sans TC", "Helvetica Neue", sans-serif;
           font-size: 11pt; line-height: 1.7; color: #1c1c1e; background: #fff; word-wrap: break-word; }
    .page { padding: 0; }
    h1, h2, h3, h4, h5, h6 { line-height: 1.3; margin: 1.4em 0 0.5em; font-weight: 600; page-break-after: avoid; }
    h1 { font-size: 22pt; } h2 { font-size: 17pt; border-bottom: 0.5pt solid #e6e4de; padding-bottom: 0.2em; }
    h3 { font-size: 14pt; } h4 { font-size: 12pt; } h5, h6 { font-size: 11pt; color: #6b6a66; }
    body > .page > :first-child { margin-top: 0; }
    p { margin: 0 0 0.8em; }
    a { color: #2f4a6d; }
    ul, ol { margin: 0 0 0.8em; padding-left: 1.6em; }
    li { margin: 0.15em 0; }
    li.task { list-style: none; margin-left: -1.3em; }
    blockquote { margin: 0 0 0.8em; padding: 0.2em 1em; border-left: 3pt solid #2f4a6d; color: #4a4a48; background: #f7f6f2; }
    code { font-family: "SF Mono", Menlo, monospace; font-size: 0.9em; background: #f2f1ed; padding: 0.1em 0.35em; border-radius: 3pt; }
    pre { background: #f5f4f0; padding: 0.8em 1em; border-radius: 6pt; overflow-x: auto; white-space: pre-wrap; page-break-inside: avoid; }
    pre code { background: none; padding: 0; font-size: 9.5pt; }
    pre.plain { background: none; padding: 0; font-family: -apple-system, "PingFang TC", sans-serif; font-size: 11pt; }
    table { border-collapse: collapse; margin: 0 0 1em; width: 100%; font-size: 10pt; page-break-inside: auto; }
    th, td { border: 0.5pt solid #d8d6cf; padding: 0.35em 0.6em; vertical-align: top; }
    th { background: #f5f4f0; font-weight: 600; }
    tr { page-break-inside: avoid; }
    hr { border: none; border-top: 0.5pt solid #d8d6cf; margin: 1.5em 0; }
    img { max-width: 100%; }
    """

    static func document(title: String, body: String, extraCSS: String = "") -> String {
        """
        <!doctype html>
        <html lang="zh-Hant"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>\(css)\(extraCSS)</style></head>
        <body><div class="page">
        \(body)
        </div></body></html>
        """
    }

    // Markdown → HTML

    static func render(_ blocks: [MD.Block]) -> String {
        blocks.map(render).joined(separator: "\n")
    }

    static func render(_ block: MD.Block) -> String {
        switch block {
        case .heading(let level, let content):
            return "<h\(level)>\(render(content))</h\(level)>"
        case .paragraph(let content):
            return "<p>\(render(content))</p>"
        case .code(let lang, let code):
            let cls = lang.isEmpty ? "" : " class=\"language-\(escape(lang))\""
            return "<pre><code\(cls)>\(escape(code))</code></pre>"
        case .quote(let inner):
            return "<blockquote>\(render(inner))</blockquote>"
        case .rule:
            return "<hr>"
        case .table(let header, let aligns, let rows):
            func style(_ index: Int) -> String {
                guard index < aligns.count else { return "" }
                switch aligns[index] {
                case .left: return ""
                case .center: return " style=\"text-align:center\""
                case .right: return " style=\"text-align:right\""
                }
            }
            var html = "<table><thead><tr>"
            for (index, cell) in header.enumerated() { html += "<th\(style(index))>\(render(cell))</th>" }
            html += "</tr></thead><tbody>"
            for row in rows {
                html += "<tr>"
                for (index, cell) in row.enumerated() { html += "<td\(style(index))>\(render(cell))</td>" }
                html += "</tr>"
            }
            return html + "</tbody></table>"
        case .list(let items):
            return renderList(items)
        }
    }

    private static func renderList(_ items: [MD.ListItem]) -> String {
        var html = ""
        var stack: [(level: Int, ordered: Bool)] = []
        for item in items {
            let level = Swift.max(0, item.level)
            while let top = stack.last, top.level > level {
                html += "</li></\(top.ordered ? "ol" : "ul")>"
                stack.removeLast()
            }
            if let top = stack.last, top.level == level {
                html += "</li>"
            } else {
                let tag = item.ordered ? (item.number != 1 ? "ol start=\"\(item.number)\"" : "ol") : "ul"
                html += "<\(tag)>"
                stack.append((level, item.ordered))
            }
            if let checked = item.checked {
                html += "<li class=\"task\">\(checked ? "☑" : "☐") \(render(item.content))"
            } else {
                html += "<li>\(render(item.content))"
            }
        }
        while let top = stack.popLast() {
            html += "</li></\(top.ordered ? "ol" : "ul")>"
        }
        return html
    }

    static func render(_ inlines: [MD.Inline]) -> String {
        inlines.map { inline -> String in
            switch inline {
            case .text(let t): return escape(t)
            case .code(let t): return "<code>\(escape(t))</code>"
            case .bold(let x): return "<strong>\(render(x))</strong>"
            case .italic(let x): return "<em>\(render(x))</em>"
            case .strike(let x): return "<del>\(render(x))</del>"
            case .link(let x, let url): return "<a href=\"\(escape(url))\">\(render(x))</a>"
            case .image(let alt, let url): return "<img src=\"\(escape(url))\" alt=\"\(escape(alt))\">"
            case .lineBreak: return "<br>"
            }
        }.joined()
    }

    static func fromMarkdown(_ markdown: String, title: String) -> String {
        document(title: title, body: render(MD.parse(markdown)))
    }

    static func fromPlainText(_ text: String, title: String) -> String {
        document(title: title, body: "<pre class=\"plain\">\(escape(text))</pre>")
    }

    static func table(_ rows: [[String]], title: String) -> String {
        guard let header = rows.first else { return document(title: title, body: "") }
        var html = "<table><thead><tr>" + header.map { "<th>\(escape($0))</th>" }.joined() + "</tr></thead><tbody>"
        for row in rows.dropFirst() {
            html += "<tr>" + row.map { "<td>\(escape($0))</td>" }.joined() + "</tr>"
        }
        html += "</tbody></table>"
        return document(title: title, body: html)
    }
}

// MARK: - CSV

enum CSV {
    static func detectDelimiter(_ text: String) -> Character {
        let sample = text.split(separator: "\n", maxSplits: 5, omittingEmptySubsequences: true).prefix(5).joined(separator: "\n")
        let candidates: [Character] = [",", ";", "\t", "|"]
        return candidates.max { a, b in sample.filter { $0 == a }.count < sample.filter { $0 == b }.count } ?? ","
    }

    static func parse(_ text: String, delimiter: Character? = nil) -> [[String]] {
        let d = delimiter ?? detectDelimiter(text)
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var chars = Array(text)
        if chars.first == "\u{FEFF}" { chars.removeFirst() }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 1 }
                    else { quoted = false }
                } else {
                    field.append(c)
                }
            } else if c == "\"" && field.isEmpty {
                quoted = true
            } else if c == d {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                row.append(field); field = ""
                rows.append(row); row = []
            } else {
                field.append(c)
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        let width = rows.map(\.count).max() ?? 0
        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }.map { $0 + Array(repeating: "", count: width - $0.count) }
    }

    static func write(_ rows: [[String]]) -> String {
        rows.map { row in
            row.map { field in
                if field.contains(",") || field.contains("\"") || field.contains("\n") {
                    return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }
                return field
            }.joined(separator: ",")
        }.joined(separator: "\r\n") + "\r\n"
    }

    static func markdownTable(_ rows: [[String]]) -> String {
        guard let header = rows.first else { return "" }
        func cell(_ s: String) -> String { s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }
        var lines = ["| " + header.map(cell).joined(separator: " | ") + " |",
                     "|" + header.map { _ in " --- " }.joined(separator: "|") + "|"]
        for row in rows.dropFirst() { lines.append("| " + row.map(cell).joined(separator: " | ") + " |") }
        return lines.joined(separator: "\n") + "\n"
    }
}

// MARK: - ZIP（不壓縮的 stored 格式，Word、Excel 和一般解壓縮軟體都看得懂）

struct ZipWriter {
    private struct Entry {
        let name: [UInt8]
        let crc: UInt32
        let size: UInt32
        let offset: UInt32
    }

    private let handle: FileHandle
    private var entries: [Entry] = []
    private var offset: UInt64 = 0
    private let dosTime: UInt16
    private let dosDate: UInt16

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        dosTime = UInt16(((c.hour ?? 0) << 11) | ((c.minute ?? 0) << 5) | ((c.second ?? 0) / 2))
        dosDate = UInt16((((c.year ?? 1980) - 1980) << 9) | ((c.month ?? 1) << 5) | (c.day ?? 1))
    }

    mutating func add(_ name: String, data: Data) throws {
        let output = handle
        try add(name, crc: CRC32.checksum(data), size: data.count) { try output.write(contentsOf: data) }
    }

    mutating func add(_ name: String, file: URL) throws {
        let size = Workspace.fileSize(file)
        guard size < Int64(UInt32.max) else { throw ToolError("\(file.lastPathComponent) 超過 4 GB，無法放進 ZIP") }
        let crc = try CRC32.checksum(file: file)
        let output = handle
        try add(name, crc: crc, size: Int(size)) {
            let reader = try FileHandle(forReadingFrom: file)
            defer { try? reader.close() }
            while let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
        }
    }

    private mutating func add(_ name: String, crc: UInt32, size: Int, writeBody: () throws -> Void) throws {
        guard offset < UInt64(UInt32.max) else { throw ToolError("ZIP 檔超過 4 GB") }
        let nameBytes = Array(name.utf8)
        var header = Data()
        header.le32(0x04034b50); header.le16(20); header.le16(0x0800); header.le16(0)
        header.le16(dosTime); header.le16(dosDate)
        header.le32(crc); header.le32(UInt32(size)); header.le32(UInt32(size))
        header.le16(UInt16(nameBytes.count)); header.le16(0)
        header.append(contentsOf: nameBytes)
        try handle.write(contentsOf: header)
        try writeBody()
        entries.append(Entry(name: nameBytes, crc: crc, size: UInt32(size), offset: UInt32(offset)))
        offset += UInt64(header.count) + UInt64(size)
    }

    mutating func finish() throws {
        var central = Data()
        for e in entries {
            central.le32(0x02014b50); central.le16(20); central.le16(20); central.le16(0x0800); central.le16(0)
            central.le16(dosTime); central.le16(dosDate)
            central.le32(e.crc); central.le32(e.size); central.le32(e.size)
            central.le16(UInt16(e.name.count)); central.le16(0); central.le16(0); central.le16(0); central.le16(0)
            central.le32(0); central.le32(e.offset)
            central.append(contentsOf: e.name)
        }
        var end = Data()
        end.le32(0x06054b50); end.le16(0); end.le16(0)
        end.le16(UInt16(entries.count)); end.le16(UInt16(entries.count))
        end.le32(UInt32(central.count)); end.le32(UInt32(offset)); end.le16(0)
        try handle.write(contentsOf: central)
        try handle.write(contentsOf: end)
        try handle.close()
    }
}

private extension Data {
    mutating func le16(_ v: UInt16) { append(UInt8(v & 0xff)); append(UInt8(v >> 8)) }
    mutating func le32(_ v: UInt32) { for k in 0..<4 { append(UInt8((v >> (8 * UInt32(k))) & 0xff)) } }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func update(_ crc: UInt32, _ data: Data) -> UInt32 {
        var c = crc
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            for byte in buffer { c = table[Int((c ^ UInt32(byte)) & 0xff)] ^ (c >> 8) }
        }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 { update(0xFFFFFFFF, data) ^ 0xFFFFFFFF }

    static func checksum(file: URL) throws -> UInt32 {
        let reader = try FileHandle(forReadingFrom: file)
        defer { try? reader.close() }
        var c: UInt32 = 0xFFFFFFFF
        while let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty {
            c = update(c, chunk)
        }
        return c ^ 0xFFFFFFFF
    }
}

// MARK: - XML 小工具

enum XML {
    static func escape(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default:
                // XML 1.0 不允許的控制字元直接拿掉
                if scalar.value < 0x20 && scalar != "\t" && scalar != "\n" && scalar != "\r" { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}

// MARK: - Word（.docx）

enum DocxWriter {
    static func write(_ blocks: [MD.Block], to url: URL) throws {
        var body = ""
        for block in blocks { body += render(block, quoteDepth: 0) }
        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <w:body>\(body)<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1304" w:bottom="1440" w:left="1304" w:header="708" w:footer="708" w:gutter="0"/></w:sectPr></w:body></w:document>
        """
        var zip = try ZipWriter(url: url)
        try zip.add("[Content_Types].xml", data: Data(contentTypes.utf8))
        try zip.add("_rels/.rels", data: Data(rootRels.utf8))
        try zip.add("word/_rels/document.xml.rels", data: Data(documentRels.utf8))
        try zip.add("word/document.xml", data: Data(document.utf8))
        try zip.add("word/styles.xml", data: Data(styles.utf8))
        try zip.add("word/numbering.xml", data: Data(numbering.utf8))
        try zip.finish()
    }

    private static func paragraph(style: String?, runs: String, extra: String = "") -> String {
        let pPr = (style.map { "<w:pStyle w:val=\"\($0)\"/>" } ?? "") + extra
        return "<w:p>\(pPr.isEmpty ? "" : "<w:pPr>\(pPr)</w:pPr>")\(runs)</w:p>"
    }

    private static func render(_ block: MD.Block, quoteDepth: Int) -> String {
        let quoteIndent = quoteDepth > 0 ? "<w:ind w:left=\"\(quoteDepth * 567)\"/>" : ""
        switch block {
        case .heading(let level, let content):
            return paragraph(style: "Heading\(Swift.min(level, 4))", runs: runs(content, Format()))
        case .paragraph(let content):
            return paragraph(style: quoteDepth > 0 ? "Quote" : nil, runs: runs(content, Format()), extra: quoteIndent)
        case .code(_, let code):
            return code.components(separatedBy: "\n").map {
                paragraph(style: "CodeBlock", runs: run(text: $0, Format()))
            }.joined()
        case .quote(let inner):
            return inner.map { render($0, quoteDepth: quoteDepth + 1) }.joined()
        case .rule:
            return paragraph(style: nil, runs: "", extra: "<w:pBdr><w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"1\" w:color=\"D8D6CF\"/></w:pBdr>")
        case .list(let items):
            return items.map { item in
                let level = Swift.min(Swift.max(item.level, 0), 8)
                var content = item.content
                if let checked = item.checked { content.insert(.text(checked ? "☑ " : "☐ "), at: 0) }
                let numbering = "<w:numPr><w:ilvl w:val=\"\(level)\"/><w:numId w:val=\"\(item.ordered ? 2 : 1)\"/></w:numPr>"
                return paragraph(style: "ListParagraph", runs: runs(content, Format()), extra: numbering)
            }.joined()
        case .table(let header, _, let rows):
            let columns = header.count
            let width = 9000 / Swift.max(columns, 1)
            var xml = "<w:tbl><w:tblPr><w:tblStyle w:val=\"TableGrid\"/><w:tblW w:w=\"0\" w:type=\"auto\"/><w:tblBorders>"
            for side in ["top", "left", "bottom", "right", "insideH", "insideV"] {
                xml += "<w:\(side) w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"BFBDB6\"/>"
            }
            xml += "</w:tblBorders></w:tblPr><w:tblGrid>"
            xml += String(repeating: "<w:gridCol w:w=\"\(width)\"/>", count: columns)
            xml += "</w:tblGrid>"
            func row(_ cells: [[MD.Inline]], header: Bool) -> String {
                var r = "<w:tr>"
                for cell in cells {
                    var f = Format(); f.bold = header
                    let shade = header ? "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F2F1ED\"/>" : ""
                    r += "<w:tc><w:tcPr><w:tcW w:w=\"\(width)\" w:type=\"dxa\"/>\(shade)</w:tcPr>\(paragraph(style: nil, runs: runs(cell, f)))</w:tc>"
                }
                return r + "</w:tr>"
            }
            xml += row(header, header: true)
            for r in rows { xml += row(r, header: false) }
            return xml + "</w:tbl>" + paragraph(style: nil, runs: "")
        }
    }

    private struct Format {
        var bold = false
        var italic = false
        var strike = false
        var code = false
        var link = false
    }

    private static func runs(_ inlines: [MD.Inline], _ f: Format) -> String {
        inlines.map { inline -> String in
            switch inline {
            case .text(let t): return run(text: t, f)
            case .code(let t): var g = f; g.code = true; return run(text: t, g)
            case .bold(let x): var g = f; g.bold = true; return runs(x, g)
            case .italic(let x): var g = f; g.italic = true; return runs(x, g)
            case .strike(let x): var g = f; g.strike = true; return runs(x, g)
            case .link(let x, _): var g = f; g.link = true; return runs(x, g)
            case .image(let alt, _): var g = f; g.italic = true; return run(text: "［圖片：\(alt)］", g)
            case .lineBreak: return "<w:r><w:br/></w:r>"
            }
        }.joined()
    }

    private static func run(text: String, _ f: Format) -> String {
        var props = ""
        if f.code { props += "<w:rFonts w:ascii=\"Menlo\" w:hAnsi=\"Menlo\"/><w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F2F1ED\"/>" }
        if f.bold { props += "<w:b/>" }
        if f.italic { props += "<w:i/>" }
        if f.strike { props += "<w:strike/>" }
        if f.link { props += "<w:color w:val=\"2F4A6D\"/><w:u w:val=\"single\"/>" }
        return "<w:r>\(props.isEmpty ? "" : "<w:rPr>\(props)</w:rPr>")<w:t xml:space=\"preserve\">\(XML.escape(text))</w:t></w:r>"
    }

    private static let contentTypes = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
    <Default Extension="xml" ContentType="application/xml"/>
    <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
    <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
    <Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>
    </Types>
    """

    private static let rootRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
    </Relationships>
    """

    private static let documentRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
    <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>
    </Relationships>
    """

    private static let styles: String = {
        func heading(_ n: Int, size: Int) -> String {
            """
            <w:style w:type="paragraph" w:styleId="Heading\(n)"><w:name w:val="heading \(n)"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>
            <w:pPr><w:keepNext/><w:spacing w:before="\(n == 1 ? 360 : 240)" w:after="120"/><w:outlineLvl w:val="\(n - 1)"/></w:pPr>
            <w:rPr><w:b/><w:sz w:val="\(size)"/><w:szCs w:val="\(size)"/></w:rPr></w:style>
            """
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:eastAsia="Microsoft JhengHei" w:cs="Calibri"/><w:sz w:val="22"/><w:szCs w:val="22"/><w:lang w:val="en-US" w:eastAsia="zh-TW"/></w:rPr></w:rPrDefault>
        <w:pPrDefault><w:pPr><w:spacing w:after="120" w:line="300" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>
        \(heading(1, size: 40))\(heading(2, size: 32))\(heading(3, size: 28))\(heading(4, size: 24))
        <w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="Normal"/><w:pPr><w:pBdr><w:left w:val="single" w:sz="18" w:space="8" w:color="2F4A6D"/></w:pBdr></w:pPr><w:rPr><w:color w:val="4A4A48"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="CodeBlock"><w:name w:val="Code Block"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/><w:shd w:val="clear" w:color="auto" w:fill="F5F4F0"/></w:pPr><w:rPr><w:rFonts w:ascii="Menlo" w:hAnsi="Menlo"/><w:sz w:val="19"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:after="40"/></w:pPr></w:style>
        <w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/><w:tblPr><w:tblCellMar><w:left w:w="108" w:type="dxa"/><w:right w:w="108" w:type="dxa"/></w:tblCellMar></w:tblPr></w:style>
        </w:styles>
        """
    }()

    private static let numbering: String = {
        func levels(ordered: Bool) -> String {
            (0..<9).map { level -> String in
                let bullet = ["•", "◦", "▪"][level % 3]
                let format = ordered ? "decimal" : "bullet"
                let text = ordered ? "%\(level + 1)." : bullet
                return "<w:lvl w:ilvl=\"\(level)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"\(format)\"/><w:lvlText w:val=\"\(text)\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"\(720 + level * 360)\" w:hanging=\"360\"/></w:pPr></w:lvl>"
            }.joined()
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:abstractNum w:abstractNumId="0"><w:multiLevelType w:val="hybridMultilevel"/>\(levels(ordered: false))</w:abstractNum>
        <w:abstractNum w:abstractNumId="1"><w:multiLevelType w:val="hybridMultilevel"/>\(levels(ordered: true))</w:abstractNum>
        <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
        <w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>
        </w:numbering>
        """
    }()
}

// MARK: - Excel（.xlsx）

enum XlsxWriter {
    static func write(_ rows: [[String]], sheetName: String, to url: URL) throws {
        var sheet = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
        if !rows.isEmpty { sheet += "<sheetViews><sheetView workbookViewId=\"0\"><pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/></sheetView></sheetViews>" }
        sheet += "<sheetData>"
        for (r, row) in rows.enumerated() {
            sheet += "<row r=\"\(r + 1)\">"
            for (c, value) in row.enumerated() where !value.isEmpty {
                let ref = column(c) + String(r + 1)
                let style = r == 0 ? " s=\"1\"" : ""
                if r > 0, let number = Double(value.trimmingCharacters(in: .whitespaces)), number.isFinite,
                   !(value.hasPrefix("0") && value.count > 1 && !value.hasPrefix("0.")) {
                    sheet += "<c r=\"\(ref)\"\(style)><v>\(value.trimmingCharacters(in: .whitespaces))</v></c>"
                } else {
                    sheet += "<c r=\"\(ref)\" t=\"inlineStr\"\(style)><is><t xml:space=\"preserve\">\(XML.escape(value))</t></is></c>"
                }
            }
            sheet += "</row>"
        }
        sheet += "</sheetData></worksheet>"

        let name = XML.escape(String(sheetName.prefix(31)).replacingOccurrences(of: "[\\\\/?*\\[\\]:]", with: "_", options: .regularExpression))
        let workbook = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="\(name.isEmpty ? "Sheet1" : name)" sheetId="1" r:id="rId1"/></sheets></workbook>
        """
        let styles = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>
        <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>
        <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
        <cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs>
        </styleSheet>
        """
        var zip = try ZipWriter(url: url)
        try zip.add("[Content_Types].xml", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
        <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
        </Types>
        """.utf8))
        try zip.add("_rels/.rels", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """.utf8))
        try zip.add("xl/_rels/workbook.xml.rels", data: Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
        """.utf8))
        try zip.add("xl/workbook.xml", data: Data(workbook.utf8))
        try zip.add("xl/styles.xml", data: Data(styles.utf8))
        try zip.add("xl/worksheets/sheet1.xml", data: Data(sheet.utf8))
        try zip.finish()
    }

    static func column(_ index: Int) -> String {
        var n = index + 1
        var name = ""
        while n > 0 {
            let r = (n - 1) % 26
            name = String(UnicodeScalar(UInt8(65 + r))) + name
            n = (n - 1) / 26
        }
        return name
    }
}
