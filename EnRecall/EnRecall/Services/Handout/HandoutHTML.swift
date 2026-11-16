import Foundation

/// 把要印的字排成 HTML（樣式照 Android 版的單字 PDF：A4、只用黑白灰、英文用等寬字）。
/// 頁尾由 PDFRenderer 畫
enum HandoutHTML {
    static let blank = "_____"

    static func document(entries: [HandoutEntry], options: HandoutOptions, rangeTitle: String, date: Date = Date()) -> String {
        let meta = "\(rangeTitle) · \(entries.count) 字 · \(date.formatted(.iso8601.year().month().day()))"
        var body = header(title: options.kind.title, meta: meta)
        switch options.kind {
        case .notes:
            body += notes(entries, amount: options.amount)
        case .test:
            body += test(entries, direction: options.direction)
        case .sheet:
            body += sheet(entries)
        }
        return """
        <!doctype html>
        <html lang="zh-Hant"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width">
        <style>\(style)</style></head>
        <body><main>\(body)</main></body></html>
        """
    }

    // MARK: 共同

    private static let style = """
    html { zoom: 0.75; }
    * { box-sizing: border-box; }
    body { margin: 0; font-family: -apple-system, "PingFang TC", sans-serif; color: rgb(17,17,17); font-size: 11px; background: white; }
    .m { font-family: ui-monospace, Menlo, monospace; }
    header { display: flex; justify-content: space-between; align-items: flex-end; border-bottom: 1.6px solid rgb(17,17,17); padding-bottom: 6px; }
    header h1 { font-size: 19px; margin: 0; } header h1 i { font-style: normal; color: rgb(119,119,119); font-weight: 400; }
    header .r { text-align: right; } header .brand { font: 700 9px ui-monospace, Menlo, monospace; letter-spacing: .14em; }
    header .meta { font-size: 9.5px; color: rgb(85,85,85); }
    .legend { font-size: 8.8px; color: rgb(102,102,102); padding: 3px 0; border-bottom: 1px solid rgb(221,221,221); display: flex; gap: 14px; flex-wrap: wrap; }
    .row { display: grid; grid-template-columns: 112px 1fr; column-gap: 10px; padding: 5px 0; border-bottom: 1px dotted rgb(196,196,196); break-inside: avoid; page-break-inside: avoid; }
    .w { font: 700 13.5px ui-monospace, Menlo, monospace; word-break: break-word; }
    .wp { font: 700 11.8px ui-monospace, Menlo, monospace; word-break: break-word; }
    .ph { font-size: 8.8px; color: rgb(102,102,102); }
    .st { font: 8.5px ui-monospace, Menlo, monospace; color: rgb(85,85,85); margin-top: 2px; }
    .lv { font-weight: 700; color: rgb(17,17,17); border: 1px solid rgb(17,17,17); border-radius: 2px; padding: 0 2px; font-size: 7.8px; }
    .ss { font-size: 11.2px; line-height: 1.25; }
    .pos { font: 700 9px ui-monospace, Menlo, monospace; color: rgb(85,85,85); }
    .dim { color: rgb(122,122,122); } .sep { color: rgb(187,187,187); }
    .ex { font-size: 9.8px; color: rgb(34,34,34); line-height: 1.2; margin-top: 1px; } .ex i { font-style: normal; color: rgb(119,119,119); }
    .xs { font-size: 9px; color: rgb(68,68,68); line-height: 1.25; margin-top: 1px; } .xs i { font-style: normal; color: rgb(119,119,119); }
    .tag { font-weight: 700; font-size: 8px; color: rgb(17,17,17); border: .9px solid rgb(153,153,153); border-radius: 2px; padding: 0 2px; margin-right: 3px; }
    h2 { font-size: 10px; margin: 10px 0 0; padding-bottom: 2px; border-bottom: 1px solid rgb(17,17,17); break-after: avoid; page-break-after: avoid; }
    .pair { display: grid; grid-template-columns: 1fr 1fr; column-gap: 12px; }
    .pair > div { border-left: 1.6px solid rgb(17,17,17); padding-left: 6px; }
    .steps { display: flex; justify-content: space-between; font-size: 9px; color: rgb(85,85,85); padding: 4px 0; border-bottom: 1px solid rgb(221,221,221); }
    .steps b { display: inline-block; width: 13px; height: 13px; border: 1px solid rgb(17,17,17); border-radius: 50%; text-align: center; line-height: 11px; font-size: 8px; color: rgb(17,17,17); margin-right: 3px; }
    .q { display: grid; grid-template-columns: 22px 1fr 220px; column-gap: 8px; padding: 6px 0; border-bottom: 1px dotted rgb(196,196,196); break-inside: avoid; page-break-inside: avoid; align-items: end; }
    .q .n { font: 9px ui-monospace, Menlo, monospace; color: rgb(119,119,119); align-self: start; padding-top: 2px; }
    .q .p { font-size: 11.2px; font-weight: 700; } .q .p .pos { font-weight: 400; }
    .q .pe { font: 700 12px ui-monospace, Menlo, monospace; }
    .q .e { font-size: 9.2px; color: rgb(102,102,102); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .q .a { border-bottom: 1px solid rgb(17,17,17); height: 22px; font: 9px ui-monospace, Menlo, monospace; color: rgb(153,153,153); letter-spacing: .06em; }
    .answers { break-before: page; page-break-before: always; }
    .answers h1 { font-size: 15px; margin: 0; } .answers p { font-size: 9px; color: rgb(102,102,102); margin: 2px 0 8px; }
    .cols { column-gap: 14px; column-rule: 1px solid rgb(221,221,221); font-size: 9.6px; line-height: 1.6; }
    .cols div { break-inside: avoid; page-break-inside: avoid; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .cols .k { font: 9px ui-monospace, Menlo, monospace; color: rgb(119,119,119); margin-right: 4px; }
    .sheet { columns: 4; column-gap: 14px; column-rule: 1px solid rgb(221,221,221); margin-top: 6px; }
    .sheet .l { font: 700 11.5px ui-monospace, Menlo, monospace; border-bottom: 1px solid rgb(17,17,17); margin: 6px 0 2px; break-after: avoid; page-break-after: avoid; }
    .sheet .s { font-size: 9.2px; line-height: 1.45; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; break-inside: avoid; }
    .sheet .s b { font-family: ui-monospace, Menlo, monospace; }
    .sheet .s .pos { font-weight: 400; font-size: 8px; }
    """

    private static func header(title: String, meta: String) -> String {
        """
        <header><h1>單字 <i>·</i> \(esc(title))</h1><div class="r"><div class="brand">ENRECALL</div><div class="meta">\(esc(meta))</div></div></header>
        """
    }

    private static func legend(_ items: [String]) -> String {
        "<div class=\"legend\">" + items.map { "<span>\(esc($0))</span>" }.joined() + "</div>"
    }

    // MARK: 講義

    private static func notes(_ entries: [HandoutEntry], amount: HandoutAmount) -> String {
        var html = legend(["●●●○○＝現在記得的機率", "忘 N＝忘過幾次", "粗體＝這個字在例句裡"])
        for entry in entries {
            if entry.isPattern {
                html += patternRow(entry, amount: amount)
            } else if entry.isPhrase {
                html += phraseRow(entry, amount: amount)
            } else {
                html += wordRow(entry, amount: amount)
            }
        }
        let pairs = similarPairs(entries)
        if !pairs.isEmpty {
            html += "<h2>易混淆字對（\(pairs.count) 組）</h2>"
            html += pairs.map { pairRow($0, amount: amount) }.joined()
        }
        return html
    }

    private static func status(_ entry: HandoutEntry) -> String {
        var parts: [String] = []
        if let level = entry.levelText { parts.append("<span class=\"lv\">\(level)</span>") }
        parts.append(entry.memoryText)
        if entry.card.lapses > 0 { parts.append("忘\(entry.card.lapses)") }
        return "<div class=\"st\">\(parts.joined(separator: " "))</div>"
    }

    private static func wordRow(_ entry: HandoutEntry, amount: HandoutAmount) -> String {
        let card = entry.card
        let word = entry.detail?.word
        let highlighter = Highlighter.forCard(card, detail: entry.detail)
        var left = "<div class=\"w\">\(esc(card.word))</div>"
        if let phonetic = word?.phonetic ?? card.phonetic, !phonetic.isEmpty {
            left += "<div class=\"ph\">\(esc(phonetic))</div>"
        }
        left += status(entry)

        var right = ""
        // 字義
        let meanings = (word?.meanings ?? []).filter { $0.zh != nil }
        if meanings.isEmpty {
            right += "<div class=\"ss\">\(posSpan(card.pos))\(esc(card.zh.replacingOccurrences(of: "\n", with: "；")))</div>"
        } else {
            let shown = amount == .brief ? Array(meanings.prefix(3)) : meanings
            let text = shown.map { "\(posSpan($0.pos))\(esc($0.zh ?? ""))" }.joined(separator: "　")
            right += "<div class=\"ss\">\(text)</div>"
        }

        if amount != .brief {
            // 例句
            var example: (en: String, zh: String?)?
            if let first = meanings.lazy.compactMap({ $0.examples.first }).first {
                example = (first.en, first.zh)
            } else if let en = card.example, !en.isEmpty {
                example = (en, card.exampleZh)
            }
            if let example {
                let en = example.en, zh = example.zh
                right += "<div class=\"ex\">\(bolded(en, highlighter: highlighter))\(zh.map { "　<i>\(esc($0))</i>" } ?? "")</div>"
            }
            // 延伸
            if let word {
                var extras: [String] = []
                let collocations = word.allCollocations.sorted { ($0.star ?? false) && !($1.star ?? false) }.prefix(2)
                if !collocations.isEmpty {
                    extras.append(tag("搭配") + collocations.map { "\(esc($0.en))\($0.zh.map { " <i>\(esc($0))</i>" } ?? "")" }.joined(separator: "；"))
                }
                let synonyms = word.synonyms.filter { !($0.tag ?? []).contains("beyond") && $0.word.lowercased() != word.word.lowercased() }.prefix(3)
                if !synonyms.isEmpty {
                    extras.append(tag("近") + synonyms.map { "\(esc($0.word))\($0.zh.map { " <i>\(esc($0))</i>" } ?? "")" }.joined(separator: " · "))
                }
                let antonyms = word.antonyms.prefix(3)
                if !antonyms.isEmpty {
                    extras.append(tag("反") + antonyms.map { "\(esc($0.word))\($0.zh.map { " <i>\(esc($0))</i>" } ?? "")" }.joined(separator: " · "))
                }
                let confusables = word.confusables.compactMap(\.words).prefix(3)
                if !confusables.isEmpty {
                    extras.append(tag("混") + confusables.map(esc).joined(separator: " · "))
                }
                if !extras.isEmpty {
                    right += "<div class=\"xs\">\(extras.joined(separator: "　"))</div>"
                }
            }
        }

        if amount == .full, let word {
            var more: [String] = []
            if let forms = word.forms { more.append(tag("變化") + esc(forms)) }
            if let pattern = meanings.lazy.compactMap({ $0.patterns.first }).first {
                more.append(tag("句型") + esc(pattern.pattern) + (pattern.en.map { " <i>\(esc($0))</i>" } ?? ""))
            }
            if let error = word.commonErrors.first(where: { $0.wrong != nil && $0.right != nil }),
               let wrong = error.wrong, let right = error.right {
                more.append(tag("誤") + "<s>\(esc(wrong))</s> → \(esc(right))")
            }
            if !word.breakdown.isEmpty {
                let parts = word.breakdown.map { "\(esc($0.part))\($0.gloss.map { " <i>\(esc($0))</i>" } ?? "")" }.joined(separator: " + ")
                more.append(tag("字源") + parts)
            } else if let origin = word.origin {
                more.append(tag("字源") + esc(origin))
            }
            if !word.related.isEmpty {
                more.append(tag("同根") + word.related.prefix(4).map { esc($0.word) }.joined(separator: " · "))
            }
            if !more.isEmpty {
                right += "<div class=\"xs\">\(more.joined(separator: "　"))</div>"
            }
        }
        return "<div class=\"row\"><div>\(left)</div><div>\(right)</div></div>"
    }

    private static func phraseRow(_ entry: HandoutEntry, amount: HandoutAmount) -> String {
        let card = entry.card
        let phrase = entry.detail?.phrase
        let highlighter = Highlighter.forCard(card, detail: entry.detail)
        var statusParts: [String] = []
        switch phrase?.tier {
        case 1: statusParts.append("<span class=\"lv\">核心</span>")
        case 2: statusParts.append("常見")
        case .some: statusParts.append("看得懂就好")
        case nil: break
        }
        statusParts.append(entry.memoryText)
        if card.lapses > 0 { statusParts.append("忘\(card.lapses)") }
        let left = "<div class=\"wp\">\(esc(card.word))</div><div class=\"st\">\(statusParts.joined(separator: " "))</div>"

        var first = "<b>\(esc(phrase?.zh ?? card.zh))</b>"
        if let pos = phrase?.pos ?? card.pos { first += " <span class=\"dim\">\(esc(pos))</span>" }
        if amount != .brief {
            let years = phrase?.years?.split(separator: " ").count ?? 0
            if years > 0 { first += " <span class=\"dim\">學測 \(years) 次</span>" }
            if let use = phrase?.use { first += "　" + tag("用法") + esc(use) }
        }
        var right = "<div class=\"ss\">\(first)</div>"
        if amount != .brief, let en = phrase?.ex ?? card.example {
            let zh = phrase?.exZh ?? card.exampleZh
            right += "<div class=\"ex\">\(bolded(en, highlighter: highlighter))\(zh.map { "　<i>\(esc($0))</i>" } ?? "")</div>"
        }
        if amount != .brief, let mix = phrase?.mix {
            right += "<div class=\"xs\">\(tag("混"))\(esc(mix))</div>"
        }
        return "<div class=\"row\"><div>\(left)</div><div>\(right)</div></div>"
    }

    private static func patternRow(_ entry: HandoutEntry, amount: HandoutAmount) -> String {
        let card = entry.card
        let pattern = entry.detail?.pattern
        let highlighter = Highlighter.forCard(card, detail: entry.detail)
        let left = "<div class=\"wp\">\(esc(pattern?.pattern ?? card.word))</div>" + status(entry)
        var right = "<div class=\"ss\"><b>\(esc(pattern?.zh ?? card.zh))</b></div>"
        if amount != .brief {
            if let explanation = pattern?.explanation {
                right += "<div class=\"xs\">\(esc(explanation))</div>"
            }
            var examples: [(String, String?)] = []
            if let pattern, !pattern.examples.isEmpty {
                for item in pattern.examples.prefix(2) { examples.append((item.en, item.zh)) }
            } else if let en = card.example, !en.isEmpty {
                examples.append((en, card.exampleZh))
            }
            for (en, zh) in examples {
                right += "<div class=\"ex\">\(bolded(en, highlighter: highlighter))\(zh.map { "　<i>\(esc($0))</i>" } ?? "")</div>"
            }
        }
        if amount == .full, let pattern {
            var more: [String] = []
            if !pattern.slots.isEmpty {
                more.append(tag("填入") + pattern.slots.map { "\(esc($0.slot))\($0.accepts.map { "：\(esc($0))" } ?? "")" }.joined(separator: "；"))
            }
            if !pattern.collocations.isEmpty {
                more.append(tag("搭配") + pattern.collocations.prefix(3).map { esc($0.en) }.joined(separator: " · "))
            }
            if let error = pattern.errors.first(where: { $0.wrong != nil && $0.right != nil }),
               let wrong = error.wrong, let right = error.right {
                more.append(tag("誤") + "<s>\(esc(wrong))</s> → \(esc(right))")
            }
            if let tips = pattern.tips { more.append(tag("記法") + esc(tips)) }
            if !more.isEmpty {
                right += "<div class=\"xs\">\(more.joined(separator: "　"))</div>"
            }
        }
        return "<div class=\"row\"><div>\(left)</div><div>\(right)</div></div>"
    }

    /// 印到的字有關的相似字對（同一對只印一次）
    private static func similarPairs(_ entries: [HandoutEntry]) -> [SimilarPair] {
        var seen: Set<String> = []
        var result: [SimilarPair] = []
        for entry in entries {
            for pair in entry.detail?.similar ?? [] {
                let key = [pair.a.lowercased(), pair.b.lowercased()].sorted().joined(separator: "|")
                if seen.insert(key).inserted { result.append(pair) }
            }
        }
        return result
    }

    private static func pairRow(_ pair: SimilarPair, amount: HandoutAmount) -> String {
        let (a, b) = underlinedDifference(pair.a, pair.b)
        let left = "<div class=\"wp\">\(a)</div><div class=\"wp\">\(b)</div>"
        func side(_ word: String, _ zh: String?, _ example: SimilarPair.Sentence?) -> String {
            var html = "<div><div class=\"ss\"><b class=\"m\">\(esc(word))</b> \(esc(zh ?? ""))</div>"
            if amount != .brief, let example {
                let highlighter = Highlighter(word: word)
                html += "<div class=\"ex\">\(bolded(example.en, highlighter: highlighter))\(example.zh.map { "　<i>\(esc($0))</i>" } ?? "")</div>"
            }
            return html + "</div>"
        }
        var right = "<div class=\"pair\">\(side(pair.a, pair.aZh, pair.exA))\(side(pair.b, pair.bZh, pair.exB))</div>"
        var line = pair.diff.map { "<b>\(esc($0))</b>" } ?? ""
        if amount != .brief, let tip = pair.tip { line += "　" + tag("記法") + esc(tip) }
        if !line.isEmpty { right += "<div class=\"xs\">\(line)</div>" }
        if amount == .full, !pair.points.isEmpty {
            right += "<div class=\"xs\">\(pair.points.map(esc).joined(separator: "　"))</div>"
        }
        return "<div class=\"row\"><div>\(left)</div><div>\(right)</div></div>"
    }

    /// 兩個字不一樣的字母加底線
    static func underlinedDifference(_ a: String, _ b: String) -> (String, String) {
        let x = Array(a), y = Array(b)
        func mark(_ chars: [Character], against other: [Character]) -> String {
            chars.enumerated().map { index, char in
                let same = index < other.count && other[index].lowercased() == char.lowercased()
                return same ? esc(String(char)) : "<u>\(esc(String(char)))</u>"
            }.joined()
        }
        return (mark(x, against: y), mark(y, against: x))
    }

    // MARK: 自測卷

    private static func test(_ entries: [HandoutEntry], direction: HandoutDirection) -> String {
        let first = direction == .zhToEn ? "看中文和挖空的例句寫英文" : "看英文寫中文"
        var html = """
        <div class="steps"><span><b>1</b>\(first)　<b>2</b>寫完翻到最後一頁對答案</span>\
        \(direction == .zhToEn ? "<span>灰色提示＝首字母和字母數</span>" : "")</div>
        """
        var answers: [String] = []
        for (index, entry) in entries.enumerated() {
            let number = String(format: "%02d", index + 1)
            let card = entry.card
            let highlighter = Highlighter.forCard(card, detail: entry.detail)
            let zh = shortZh(entry)
            let prompt: String
            var example = ""
            var answerLine = ""
            switch direction {
            case .zhToEn:
                prompt = "<div class=\"p\">\(esc(zh))\(posSpan(card.pos, leading: true))</div>"
                if let sentence = blankedExample(entry, highlighter: highlighter) {
                    example = "<div class=\"e\">\(esc(sentence))</div>"
                }
                answerLine = esc(letterHint(card.word))
                answers.append(card.word)
            case .enToZh:
                prompt = "<div class=\"pe\">\(esc(card.word))</div>"
                if let en = examples(entry).first?.0 {
                    example = "<div class=\"e\">\(bolded(en, highlighter: highlighter))</div>"
                }
                answers.append(zh)
            }
            html += "<div class=\"q\"><div class=\"n\">\(number)</div><div>\(prompt)\(example)</div><div class=\"a\">\(answerLine)</div></div>"
        }
        let columns = direction == .zhToEn ? 5 : 3
        html += """
        <section class="answers"><h1>單字 · 自測卷答案</h1><p>寫完再翻過來對。</p>\
        <div class="cols" style="columns: \(columns)">
        """
        for (index, answer) in answers.enumerated() {
            html += "<div><span class=\"k\">\(index + 1)</span>\(esc(answer))</div>"
        }
        return html + "</div></section>"
    }

    /// 例句挖空：每個比對到的字（含變化形、片語中間的字）換成 _____；挖不到的句子不用（答案不能印在題目上）
    static func blankedExample(_ entry: HandoutEntry, highlighter: Highlighter) -> String? {
        guard let regex = highlighter.regex else { return nil }
        for (en, _) in examples(entry) {
            let range = NSRange(en.startIndex..., in: en)
            guard regex.firstMatch(in: en, range: range) != nil else { continue }
            return regex.stringByReplacingMatches(in: en, range: range, withTemplate: blank)
        }
        return nil
    }

    private static func examples(_ entry: HandoutEntry) -> [(String, String?)] {
        var result: [(String, String?)] = []
        if let word = entry.detail?.word {
            result += word.meanings.flatMap(\.examples).map { ($0.en, $0.zh) }
        }
        if let phrase = entry.detail?.phrase, let ex = phrase.ex {
            result.append((ex, phrase.exZh))
        }
        if let example = entry.card.example, !example.isEmpty {
            result.append((example, entry.card.exampleZh))
        }
        return result
    }

    /// 題目用的中文：最多兩個字義
    private static func shortZh(_ entry: HandoutEntry) -> String {
        if let meanings = entry.detail?.word?.meanings.compactMap(\.zh), !meanings.isEmpty {
            return meanings.prefix(2).joined(separator: "；")
        }
        let zh = entry.detail?.phrase?.zh ?? entry.card.zh
        return zh.split(whereSeparator: { $0 == "\n" }).prefix(2).joined(separator: "；")
    }

    /// 「g _ _ _   u _」：首字母＋每個字母一格（最多 10 格）；sb、sth 照印
    static func letterHint(_ answer: String) -> String {
        answer.split(separator: " ").map { part in
            let word = String(part)
            if ["sb", "sth", "sb's", "one's", "...", "…"].contains(word.lowercased()) { return word }
            guard let first = word.first else { return "" }
            let rest = min(max(word.count - 1, 0), 9)
            return ([String(first)] + Array(repeating: "_", count: rest)).joined(separator: " ")
        }
        .joined(separator: "   ")
    }

    // MARK: 速查表

    private static func sheet(_ entries: [HandoutEntry]) -> String {
        var html = "<div class=\"sheet\">"
        var letter: Character?
        for entry in entries.sorted(by: { $0.card.wordNorm < $1.card.wordNorm }) {
            let first = entry.card.wordNorm.first.map { Character($0.uppercased()) }
            if let first, first != letter, first.isLetter {
                letter = first
                html += "<div class=\"l\">\(esc(String(first)))</div>"
            }
            let zh = shortZh(entry).split(separator: "；").first.map(String.init) ?? ""
            html += "<div class=\"s\"><b>\(esc(entry.card.word))</b>\(posSpan(entry.card.pos, leading: true)) \(esc(zh))</div>"
        }
        return html + "</div>"
    }

    // MARK: 小工具

    private static func tag(_ text: String) -> String {
        "<span class=\"tag\">\(esc(text))</span>"
    }

    private static func posSpan(_ pos: String?, leading: Bool = false) -> String {
        guard let pos, !pos.isEmpty else { return "" }
        return leading ? " <span class=\"pos\">\(esc(pos))</span>" : "<span class=\"pos\">\(esc(pos))</span> "
    }

    /// 英文例句：這個字（含變化形）粗體
    static func bolded(_ text: String, highlighter: Highlighter) -> String {
        guard let regex = highlighter.regex else { return esc(text) }
        let ns = text as NSString
        var result = ""
        var location = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += esc(ns.substring(with: NSRange(location: location, length: match.range.location - location)))
            result += "<b>\(esc(ns.substring(with: match.range)))</b>"
            location = match.range.location + match.range.length
        }
        return result + esc(ns.substring(from: location))
    }

    static func esc(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
