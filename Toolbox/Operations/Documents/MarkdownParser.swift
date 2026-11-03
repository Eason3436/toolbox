import Foundation

/// 小型 Markdown 解析器：轉成區塊和行內元素，HTML 和 Word 共用。
/// 支援標題、段落、清單（含待辦）、引言、程式碼區塊、表格、分隔線，
/// 以及粗體、斜體、刪除線、行內程式碼、連結、圖片。
enum MD {
    indirect enum Inline {
        case text(String)
        case code(String)
        case bold([Inline])
        case italic([Inline])
        case strike([Inline])
        case link([Inline], String)
        case image(String, String)
        case lineBreak
    }

    struct ListItem {
        var level: Int
        var ordered: Bool
        var number: Int
        var checked: Bool?
        var content: [Inline]
    }

    enum Align { case left, center, right }

    indirect enum Block {
        case heading(Int, [Inline])
        case paragraph([Inline])
        case list([ListItem])
        case quote([Block])
        case code(String, String)
        case table([[Inline]], [Align], [[[Inline]]])
        case rule
    }

    // MARK: 區塊

    static func parse(_ source: String) -> [Block] {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        return parseBlocks(lines)
    }

    private static func parseBlocks(_ lines: [String]) -> [Block] {
        var blocks: [Block] = []
        var i = 0
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraphInlines(paragraph)))
            paragraph = []
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            // 程式碼區塊
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i])
                    i += 1
                }
                i += 1
                blocks.append(.code(lang, code.joined(separator: "\n")))
                continue
            }

            // 標題
            if let heading = headingLevel(trimmed) {
                flushParagraph()
                let text = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                let cleaned = text.replacingOccurrences(of: "\\s+#+\\s*$", with: "", options: .regularExpression)
                blocks.append(.heading(heading, inlines(cleaned)))
                i += 1
                continue
            }

            // Setext 標題（下一行是 === 或 ---）
            if !paragraph.isEmpty, isSetextUnderline(trimmed) {
                let level = trimmed.hasPrefix("=") ? 1 : 2
                let text = paragraph.joined(separator: " ")
                paragraph = []
                blocks.append(.heading(level, inlines(text)))
                i += 1
                continue
            }

            // 分隔線
            if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                i += 1
                continue
            }

            // 表格
            if trimmed.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushParagraph()
                let header = splitRow(trimmed)
                let aligns = splitRow(lines[i + 1]).map(alignment)
                var rows: [[[Inline]]] = []
                i += 2
                while i < lines.count {
                    let row = lines[i].trimmingCharacters(in: .whitespaces)
                    if row.isEmpty || !row.contains("|") { break }
                    var cells = splitRow(row)
                    while cells.count < header.count { cells.append("") }
                    rows.append(cells.prefix(header.count).map(inlines))
                    i += 1
                }
                blocks.append(.table(header.map(inlines), aligns + Array(repeating: .left, count: Swift.max(0, header.count - aligns.count)), rows))
                continue
            }

            // 引言
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var inner: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    var rest = String(t.dropFirst())
                    if rest.hasPrefix(" ") { rest.removeFirst() }
                    inner.append(rest)
                    i += 1
                }
                blocks.append(.quote(parseBlocks(inner)))
                continue
            }

            // 清單
            if listMarker(line) != nil {
                flushParagraph()
                var items: [ListItem] = []
                while i < lines.count {
                    let current = lines[i]
                    if let marker = listMarker(current) {
                        var text = marker.text
                        var checked: Bool?
                        if text.hasPrefix("[ ] ") { checked = false; text = String(text.dropFirst(4)) }
                        else if text.lowercased().hasPrefix("[x] ") { checked = true; text = String(text.dropFirst(4)) }
                        items.append(ListItem(level: marker.indent / 2, ordered: marker.ordered, number: marker.number,
                                              checked: checked, content: inlines(text)))
                        i += 1
                    } else if !current.trimmingCharacters(in: .whitespaces).isEmpty,
                              current.hasPrefix("  ") || current.hasPrefix("\t"),
                              var last = items.popLast() {
                        // 清單項目的延續行
                        last.content += [.text(" ")] + inlines(current.trimmingCharacters(in: .whitespaces))
                        items.append(last)
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(.list(items))
                continue
            }

            paragraph.append(line)
            i += 1
        }
        flushParagraph()
        return blocks
    }

    private static func paragraphInlines(_ lines: [String]) -> [Inline] {
        var result: [Inline] = []
        for (index, raw) in lines.enumerated() {
            let hardBreak = raw.hasSuffix("  ") || raw.hasSuffix("\\")
            var text = raw.trimmingCharacters(in: .whitespaces)
            if text.hasSuffix("\\") { text.removeLast() }
            result += inlines(text)
            if index < lines.count - 1 {
                if hardBreak {
                    result.append(.lineBreak)
                } else if let last = text.last, let next = lines[index + 1].trimmingCharacters(in: .whitespaces).first,
                          isCJK(last) || isCJK(next) {
                    // 中文換行不補空白
                } else {
                    result.append(.text(" "))
                }
            }
        }
        return result
    }

    static func isCJK(_ c: Character) -> Bool {
        guard let scalar = c.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x2E80...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF, 0x3000...0x303F: return true
        default: return false
        }
    }

    private static func headingLevel(_ line: String) -> Int? {
        var count = 0
        for c in line {
            if c == "#" { count += 1 } else { break }
        }
        guard (1...6).contains(count) else { return nil }
        let rest = line.dropFirst(count)
        return rest.isEmpty || rest.first == " " ? count : nil
    }

    private static func isSetextUnderline(_ line: String) -> Bool {
        line.range(of: "^(=+|-+)$", options: .regularExpression) != nil && line.count >= 2
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-") else { return false }
        return t.range(of: "^\\|?\\s*:?-+:?\\s*(\\|\\s*:?-+:?\\s*)*\\|?$", options: .regularExpression) != nil
    }

    private static func splitRow(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") && !t.hasSuffix("\\|") { t.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for c in t {
            if escaped { current.append(c); escaped = false; continue }
            if c == "\\" { escaped = true; continue }
            if c == "|" { cells.append(current.trimmingCharacters(in: .whitespaces)); current = ""; continue }
            current.append(c)
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func alignment(_ cell: String) -> Align {
        let left = cell.hasPrefix(":"), right = cell.hasSuffix(":")
        if left && right { return .center }
        if right { return .right }
        return .left
    }

    private struct Marker {
        let indent: Int
        let ordered: Bool
        let number: Int
        let text: String
    }

    private static func listMarker(_ line: String) -> Marker? {
        let expanded = line.replacingOccurrences(of: "\t", with: "    ")
        let indent = expanded.prefix(while: { $0 == " " }).count
        let rest = expanded.dropFirst(indent)
        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            if isRule(String(rest)) { return nil }
            return Marker(indent: indent, ordered: false, number: 0, text: String(rest.dropFirst(2)))
        }
        let digits = rest.prefix(while: { $0.isNumber })
        if !digits.isEmpty, digits.count <= 9 {
            let after = rest.dropFirst(digits.count)
            if let mark = after.first, mark == "." || mark == ")", after.dropFirst().first == " " {
                return Marker(indent: indent, ordered: true, number: Int(digits) ?? 1, text: String(after.dropFirst(2)))
            }
        }
        return nil
    }

    // MARK: 行內

    static func inlines(_ text: String) -> [Inline] {
        var parser = InlineParser(chars: Array(text))
        return parser.parse(until: nil)
    }

    private struct InlineParser {
        let chars: [Character]
        var i = 0

        mutating func parse(until closing: String?) -> [Inline] {
            var result: [Inline] = []
            var buffer = ""
            func flush() {
                if !buffer.isEmpty { result.append(.text(buffer)); buffer = "" }
            }
            while i < chars.count {
                if let closing, matches(closing, at: i) {
                    flush()
                    i += closing.count
                    return result
                }
                let c = chars[i]
                if c == "\\", i + 1 < chars.count, "\\`*_{}[]()#+-.!|~<>".contains(chars[i + 1]) {
                    buffer.append(chars[i + 1]); i += 2; continue
                }
                if c == "`" {
                    let run = countRun("`", at: i)
                    let fence = String(repeating: "`", count: run)
                    if let end = find(fence, from: i + run) {
                        flush()
                        let code = String(chars[(i + run)..<end]).trimmingCharacters(in: .whitespaces)
                        result.append(.code(code))
                        i = end + run
                        continue
                    }
                }
                if c == "!", i + 1 < chars.count, chars[i + 1] == "[", let parts = linkParts(at: i + 1) {
                    flush()
                    result.append(.image(parts.0, parts.1))
                    i = parts.2
                    continue
                }
                if c == "[", let parts = linkParts(at: i) {
                    flush()
                    var inner = InlineParser(chars: Array(parts.0))
                    result.append(.link(inner.parse(until: nil), parts.1))
                    i = parts.2
                    continue
                }
                if (c == "*" || c == "_"), matches(String(repeating: c, count: 2), at: i),
                   find(String(repeating: c, count: 2), from: i + 2) != nil, canOpen(at: i, width: 2) {
                    flush()
                    i += 2
                    result.append(.bold(parse(until: String(repeating: c, count: 2))))
                    continue
                }
                if c == "~", matches("~~", at: i), find("~~", from: i + 2) != nil {
                    flush()
                    i += 2
                    result.append(.strike(parse(until: "~~")))
                    continue
                }
                if (c == "*" || c == "_"), canOpen(at: i, width: 1), let end = find(String(c), from: i + 1), end > i + 1 {
                    if c == "_", i > 0, chars[i - 1].isLetter || chars[i - 1].isNumber, !MD.isCJK(chars[i - 1]) {
                        buffer.append(c); i += 1; continue
                    }
                    flush()
                    i += 1
                    result.append(.italic(parse(until: String(c))))
                    continue
                }
                if c == "<", let end = find(">", from: i + 1) {
                    let inside = String(chars[(i + 1)..<end])
                    if inside.lowercased() == "br" || inside.lowercased() == "br/" || inside.lowercased() == "br /" {
                        flush(); result.append(.lineBreak); i = end + 1; continue
                    }
                    if inside.hasPrefix("http://") || inside.hasPrefix("https://") || inside.hasPrefix("mailto:") {
                        flush(); result.append(.link([.text(inside)], inside)); i = end + 1; continue
                    }
                }
                if c == "h", matches("http://", at: i) || matches("https://", at: i),
                   i == 0 || !(chars[i - 1].isLetter || chars[i - 1].isNumber) {
                    var end = i
                    while end < chars.count, !chars[end].isWhitespace, !"<>\"）)」，。".contains(chars[end]) { end += 1 }
                    while end > i, ".,;:!?".contains(chars[end - 1]) { end -= 1 }
                    let url = String(chars[i..<end])
                    flush()
                    result.append(.link([.text(url)], url))
                    i = end
                    continue
                }
                buffer.append(c)
                i += 1
            }
            flush()
            return result
        }

        func canOpen(at index: Int, width: Int) -> Bool {
            let next = index + width
            return next < chars.count && !chars[next].isWhitespace
        }

        func matches(_ token: String, at index: Int) -> Bool {
            let t = Array(token)
            guard index + t.count <= chars.count else { return false }
            for k in 0..<t.count where chars[index + k] != t[k] { return false }
            return true
        }

        func countRun(_ c: Character, at index: Int) -> Int {
            var n = 0
            while index + n < chars.count, chars[index + n] == c { n += 1 }
            return n
        }

        func find(_ token: String, from start: Int) -> Int? {
            var k = start
            while k < chars.count {
                if chars[k] == "\\" { k += 2; continue }
                if matches(token, at: k) { return k }
                k += 1
            }
            return nil
        }

        /// [文字](網址) → (文字, 網址, 結束位置)
        func linkParts(at start: Int) -> (String, String, Int)? {
            guard chars[start] == "[" else { return nil }
            var depth = 0
            var k = start
            var close: Int?
            while k < chars.count {
                if chars[k] == "\\" { k += 2; continue }
                if chars[k] == "[" { depth += 1 }
                if chars[k] == "]" { depth -= 1; if depth == 0 { close = k; break } }
                k += 1
            }
            guard let close, close + 1 < chars.count, chars[close + 1] == "(" else { return nil }
            var j = close + 2
            var parens = 1
            while j < chars.count {
                if chars[j] == "(" { parens += 1 }
                if chars[j] == ")" { parens -= 1; if parens == 0 { break } }
                j += 1
            }
            guard j < chars.count else { return nil }
            let label = String(chars[(start + 1)..<close])
            var target = String(chars[(close + 2)..<j]).trimmingCharacters(in: .whitespaces)
            if let space = target.firstIndex(of: " ") { target = String(target[..<space]) }
            if target.hasPrefix("<") && target.hasSuffix(">") { target = String(target.dropFirst().dropLast()) }
            return (label, target, j + 1)
        }
    }

    // MARK: 純文字

    static func plain(_ inlines: [Inline]) -> String {
        inlines.map { inline -> String in
            switch inline {
            case .text(let t), .code(let t): return t
            case .bold(let x), .italic(let x), .strike(let x): return plain(x)
            case .link(let x, _): return plain(x)
            case .image(let alt, _): return alt
            case .lineBreak: return "\n"
            }
        }.joined()
    }
}
