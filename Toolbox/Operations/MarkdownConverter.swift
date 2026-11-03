import Foundation
import PDFKit
import UIKit
import Vision

/// PDF 轉 Markdown：依字體大小判斷標題，辨認清單，把同一段的行接起來。
enum MarkdownConverter {
    struct Line {
        var text: String
        var size: CGFloat
        var bold: Bool
    }

    static func convert(_ document: PDFDocument, ocr: Bool, pageBreaks: Bool,
                        report: @Sendable (String) -> Void) async throws -> String {
        var pages: [[Line]] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            report("讀取第 \(index + 1)/\(document.pageCount) 頁")
            var lines = extractLines(from: page)
            let hasText = lines.contains { !$0.text.isEmpty }
            if !hasText && ocr {
                report("辨識文字 第 \(index + 1)/\(document.pageCount) 頁")
                lines = try recognizeLines(on: page)
            }
            pages.append(lines)
        }

        let body = bodySize(pages.flatMap { $0 })
        var blocks: [String] = []
        for (index, lines) in pages.enumerated() {
            if index > 0 && pageBreaks { blocks.append("---") }
            blocks.append(contentsOf: makeBlocks(lines, bodySize: body))
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    // MARK: 讀文字

    static func extractLines(from page: PDFPage) -> [Line] {
        guard let attributed = page.attributedString else { return [] }
        let string = attributed.string as NSString
        var lines: [Line] = []
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .byLines) { substring, range, _, _ in
            let text = (substring ?? "").trimmingCharacters(in: .whitespaces)
            if text.isEmpty {
                lines.append(Line(text: "", size: 0, bold: false))
                return
            }
            var sizeWeights: [CGFloat: Int] = [:]
            var boldLength = 0
            var totalLength = 0
            attributed.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
                guard let font = value as? UIFont else { return }
                let size = (font.pointSize * 2).rounded() / 2
                sizeWeights[size, default: 0] += subrange.length
                let isBold = font.fontDescriptor.symbolicTraits.contains(.traitBold)
                    || font.fontName.lowercased().contains("bold")
                    || font.fontName.lowercased().contains("heavy")
                    || font.fontName.lowercased().contains("black")
                if isBold { boldLength += subrange.length }
                totalLength += subrange.length
            }
            let size = sizeWeights.max { $0.value < $1.value }?.key ?? 0
            lines.append(Line(text: text, size: size, bold: totalLength > 0 && boldLength * 2 >= totalLength))
        }
        return lines
    }

    static func recognizeLines(on page: PDFPage) throws -> [Line] {
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2.5
        let image = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
        guard let cgImage = image.cgImage else { return [] }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hant", "en-US"]
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        let observations = (request.results ?? []).sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
        var lines: [Line] = []
        var previousBottom: CGFloat?
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let box = observation.boundingBox
            let height = box.height * bounds.height
            // 行距明顯變大時當成新段落。
            if let previousBottom, previousBottom - box.maxY > box.height * 1.2 {
                lines.append(Line(text: "", size: 0, bold: false))
            }
            lines.append(Line(text: candidate.string.trimmingCharacters(in: .whitespaces), size: (height * 2).rounded() / 2, bold: false))
            previousBottom = box.minY
        }
        return lines
    }

    // MARK: 排版

    static func bodySize(_ lines: [Line]) -> CGFloat {
        var weights: [CGFloat: Int] = [:]
        for line in lines where !line.text.isEmpty && line.size > 0 {
            weights[line.size, default: 0] += line.text.count
        }
        return weights.max { $0.value < $1.value }?.key ?? 0
    }

    static func makeBlocks(_ lines: [Line], bodySize body: CGFloat) -> [String] {
        var blocks: [String] = []
        var paragraph: [String] = []
        var lastWasList = false

        func flush() {
            if !paragraph.isEmpty {
                blocks.append(join(paragraph))
                paragraph.removeAll()
                lastWasList = false
            }
        }

        func appendListItem(_ item: String) {
            flush()
            if lastWasList, let last = blocks.popLast() {
                blocks.append(last + "\n" + item)
            } else {
                blocks.append(item)
            }
            lastWasList = true
        }

        for line in lines {
            let text = line.text
            if text.isEmpty {
                flush()
                lastWasList = false
                continue
            }
            if isPageNumber(text) { continue }

            if body > 0, line.size >= body * 1.15, text.count <= 120 {
                flush()
                let ratio = line.size / body
                let level = ratio >= 1.8 ? 1 : (ratio >= 1.4 ? 2 : 3)
                blocks.append(String(repeating: "#", count: level) + " " + text)
                lastWasList = false
                continue
            }
            if line.bold, text.count <= 60, paragraph.isEmpty, !endsSentence(text) {
                flush()
                blocks.append("**\(text)**")
                lastWasList = false
                continue
            }
            if let item = bulletItem(text) {
                appendListItem("- " + item)
                continue
            }
            if isNumberedItem(text) {
                appendListItem(text)
                continue
            }
            if lastWasList, let last = blocks.popLast() {
                // 清單項目換行的延續。
                blocks.append(join([last, text]))
                continue
            }
            paragraph.append(text)
        }
        flush()
        return blocks
    }

    static let bulletMarks: Set<Character> = ["•", "●", "▪", "■", "◦", "‣", "・", "○", "◆", "◇", "-", "–", "*", "·"]

    static func bulletItem(_ text: String) -> String? {
        guard let first = text.first, bulletMarks.contains(first) else { return nil }
        let rest = text.dropFirst()
        if "-–*".contains(first), let next = rest.first, !next.isWhitespace { return nil }
        let item = rest.trimmingCharacters(in: .whitespaces)
        return item.isEmpty ? nil : item
    }

    static func isNumberedItem(_ text: String) -> Bool {
        text.range(of: #"^(\d{1,3}|[a-zA-Z])[\.\)、]\s*\S"#, options: .regularExpression) != nil
            || text.range(of: #"^[（(]\d{1,3}[)）]"#, options: .regularExpression) != nil
    }

    static func isPageNumber(_ text: String) -> Bool {
        text.range(of: #"^[-–\s]*\d{1,4}[-–\s]*$"#, options: .regularExpression) != nil
            || text.range(of: #"^第?\s*\d{1,4}\s*頁$"#, options: .regularExpression) != nil
    }

    static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return "。.！!？?：:；;".contains(last)
    }

    static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first?.value else { return false }
        return (0x4E00...0x9FFF).contains(scalar) || (0x3400...0x4DBF).contains(scalar)
            || (0x3000...0x303F).contains(scalar) || (0xFF00...0xFFEF).contains(scalar)
            || (0x3040...0x30FF).contains(scalar) || (0xAC00...0xD7AF).contains(scalar)
    }

    /// 把同一段的多行接起來：中文直接接，英文補空白，斷字的連字號去掉。
    static func join(_ lines: [String]) -> String {
        var result = ""
        for line in lines {
            guard let lastChar = result.last, let firstChar = line.first else {
                result += line
                continue
            }
            if lastChar == "-", firstChar.isLowercase {
                result.removeLast()
                result += line
            } else if isCJK(lastChar) || isCJK(firstChar) {
                result += line
            } else {
                result += " " + line
            }
        }
        return result
    }
}
