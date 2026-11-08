import Foundation

/// 把其他 AI 給的 Markdown 筆記轉成課程筆記的 HTML（沿用 RichNotes 的卡片樣式）。
enum MarkdownHTML {
    static func convert(_ markdown: String) -> String {
        var out: [String] = []
        var inSection = false
        var list: String? // "ul" 或 "ol"
        var table: [[String]] = []
        var quote: [String] = []
        var sectionIndex = 0
        var sawTitle = false

        func closeList() { if let tag = list { out.append("</\(tag)>"); list = nil } }
        func closeQuote() {
            guard !quote.isEmpty else { return }
            // 第一個引言在標題後面：當成摘要
            if sawTitle, !inSection, sectionIndex == 0 {
                out.append("<p class=\"lead\">\(quote.joined(separator: "<br>"))</p>")
            } else {
                out.append("<aside class=\"tip\">\(quote.joined(separator: "<br>"))</aside>")
            }
            quote = []
        }
        func closeTable() {
            guard !table.isEmpty else { return }
            var html = "<table>"
            for (i, row) in table.enumerated() {
                let tag = i == 0 ? "th" : "td"
                html += "<tr>" + row.map { "<\(tag)>\($0)</\(tag)>" }.joined() + "</tr>"
            }
            out.append(html + "</table>")
            table = []
        }
        func closeBlocks() { closeList(); closeQuote(); closeTable() }
        func closeSection() { closeBlocks(); if inSection { out.append("</section>"); inSection = false } }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { closeBlocks(); continue }
            if line.hasPrefix("# ") {
                closeSection()
                out.append("<header><h1>\(inline(String(line.dropFirst(2))))</h1></header>")
                sawTitle = true
            } else if line.hasPrefix("## ") {
                closeSection()
                let title = inline(String(line.dropFirst(3)))
                out.append("<section class=\"card\" id=\"s\(sectionIndex)\"><h2><span class=\"num\">\(String(format: "%02d", sectionIndex))</span>\(title)</h2>")
                sectionIndex += 1
                inSection = true
            } else if line.hasPrefix("### ") || line.hasPrefix("#### ") {
                closeBlocks()
                out.append("<h3>\(inline(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))</h3>")
            } else if line.hasPrefix(">") {
                closeList(); closeTable()
                quote.append(inline(line.dropFirst().trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("|") {
                closeList(); closeQuote()
                let cells = line.trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                // 跳過 |---|---| 分隔列
                if cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy { "-: ".contains($0) } }) { continue }
                table.append(cells.map(inline))
            } else if let item = listItem(line) {
                closeQuote(); closeTable()
                if list != item.tag { closeList(); out.append("<\(item.tag)>"); list = item.tag }
                out.append("<li>\(inline(item.text))</li>")
            } else if line == "---" || line == "***" {
                closeBlocks()
            } else {
                closeBlocks()
                out.append("<p>\(inline(line))</p>")
            }
        }
        closeSection()
        return out.joined(separator: "\n")
    }

    private static func listItem(_ line: String) -> (tag: String, text: String)? {
        for marker in ["- ", "* ", "• ", "・"] where line.hasPrefix(marker) {
            return ("ul", String(line.dropFirst(marker.count)))
        }
        if let range = line.range(of: #"^\d+[\.、)]\s*"#, options: .regularExpression) {
            return ("ol", String(line[range.upperBound...]))
        }
        return nil
    }

    /// 跳脫 HTML，再處理 **粗體**、`程式碼`、*斜體*
    private static func inline(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        s = s.replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "<strong>$1</strong>", options: .regularExpression)
        s = s.replacingOccurrences(of: #"`([^`]+)`"#, with: "<code>$1</code>", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?<![\*\w])\*([^\*]+)\*(?!\*)"#, with: "<em>$1</em>", options: .regularExpression)
        return s
    }
}
