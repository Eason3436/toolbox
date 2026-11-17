import Foundation

/// PDF 的強調色：跟著 App 目前的配色（取淺色模式的主色），印黑白也看得清楚
struct HandoutStyle: Equatable {
    /// 標號、記憶條、標籤、分隔線
    var accent: String
    /// 例句裡單字的螢光底、淡底
    var tint: String
    /// 例句左邊的細線
    var rule: String

    init(red: Double, green: Double, blue: Double) {
        func css(_ amount: Double) -> String {
            // amount：往白色混的比例
            let mix = { (value: Double) in Int(((value + (1 - value) * amount) * 255).rounded()) }
            return "rgb(\(mix(red)),\(mix(green)),\(mix(blue)))"
        }
        accent = css(0)
        tint = css(0.82)
        rule = css(0.6)
    }

    /// 黑白
    static let ink = HandoutStyle(red: 0.11, green: 0.11, blue: 0.12)
}

/// 把要印的字排成 HTML。版面：
/// - 講義：雙欄字卡，襯線字的單字、記憶條、例句螢光筆，最後是易混淆字對
/// - 自測卷：每題右邊有答案，沿虛線往後折就蓋住，寫完翻開對；上面有得分欄
/// - 速查表：照記得的程度分組（還不熟／快記住了／穩了／新字），三欄
/// 頁尾由 PDFRenderer 畫
enum HandoutHTML {
    static let blank = "_____"

    static func document(entries: [HandoutEntry], options: HandoutOptions, rangeTitle: String,
                         date: Date = Date(), style: HandoutStyle = .ink) -> String {
        let day = date.formatted(.iso8601.year().month().day())
        let meta = "\(rangeTitle) · \(entries.count) 字 · \(day)"
        var body = header(options: options, rangeTitle: rangeTitle, count: entries.count, meta: meta)
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
        <style>:root { --a: \(style.accent); --t: \(style.tint); --r: \(style.rule); }
        \(css)</style></head>
        <body><main>\(body)</main></body></html>
        """
    }

    // MARK: 共同

    private static let css = """
    html { zoom: 0.75; }
    * { box-sizing: border-box; }
    body { margin: 0; font: 11px/1.45 -apple-system, "PingFang TC", sans-serif; color: rgb(28,28,30); background: white; -webkit-print-color-adjust: exact; }
    .sf { font-family: ui-serif, "New York", Georgia, serif; }
    .mono { font-family: ui-monospace, Menlo, monospace; }
    .g { color: rgb(110,110,115); } .g2 { color: rgb(150,150,155); }

    .top { display: flex; justify-content: space-between; align-items: flex-end; padding-bottom: 10px; border-bottom: 2px solid var(--a); margin-bottom: 4px; }
    .top .k { font: 600 8.5px ui-monospace, Menlo, monospace; letter-spacing: .2em; color: var(--a); }
    .top h1 { font: 700 30px/1.1 ui-serif, "New York", Georgia, serif; margin: 6px 0 0; letter-spacing: .04em; }
    .top h1 small { font: 400 12px -apple-system, "PingFang TC", sans-serif; color: rgb(110,110,115); margin-left: 10px; letter-spacing: 0; }
    .top .r { text-align: right; }
    .top .big { font: 700 34px/1 ui-serif, "New York", Georgia, serif; color: var(--a); }
    .top .big span { font: 400 11px -apple-system, "PingFang TC", sans-serif; color: rgb(110,110,115); margin-left: 3px; }
    .top .meta { font-size: 9px; color: rgb(110,110,115); margin-top: 4px; }
    .note { font-size: 9px; color: rgb(110,110,115); margin: 0 0 10px; }
    .note b { color: var(--a); font-weight: 600; }

    /* 講義：雙欄字卡 */
    .cards { columns: 2; column-gap: 24px; }
    .e { break-inside: avoid; page-break-inside: avoid; padding: 8px 0 9px; border-top: 1px solid rgb(229,229,234); }
    .e .h { display: flex; align-items: baseline; gap: 6px; }
    .e .n { font: 600 8.5px ui-monospace, Menlo, monospace; color: var(--a); width: 16px; flex: none; }
    .e .w { font: 700 15.5px/1.2 ui-serif, "New York", Georgia, serif; word-break: break-word; }
    .e .w.p { font-size: 13.5px; }
    .e .ph { font-size: 9px; color: rgb(150,150,155); }
    .e .st { margin-left: auto; display: flex; align-items: center; gap: 5px; flex: none; font-size: 8px; color: rgb(150,150,155); }
    .bars { display: inline-flex; gap: 1.5px; }
    .bars i { display: block; width: 7px; height: 3.5px; border-radius: 1px; background: rgb(225,225,229); }
    .bars i.on { background: var(--a); }
    .fresh { font-size: 7.5px; color: var(--a); border: 1px solid var(--a); border-radius: 6px; padding: 0 4px; }
    .lv { font: 600 7.5px ui-monospace, Menlo, monospace; color: rgb(110,110,115); }
    .e .d { padding-left: 22px; }
    .mn { margin-top: 2px; font-size: 10.8px; line-height: 1.4; }
    .mn .ps { font: italic 9.5px ui-serif, "New York", Georgia, serif; color: rgb(110,110,115); margin-right: 3px; }
    .mn .sep { color: rgb(200,200,204); margin: 0 4px; }
    .ex { margin-top: 4px; padding: 1px 0 1px 8px; border-left: 2px solid var(--r); font: 10.4px/1.4 ui-serif, "New York", Georgia, serif; }
    .ex b { font-weight: 700; background: linear-gradient(transparent 55%, var(--t) 55%); }
    .ex .zh { display: block; font: 9.2px/1.4 -apple-system, "PingFang TC", sans-serif; color: rgb(110,110,115); }
    .x { margin-top: 3px; font-size: 9.2px; line-height: 1.4; color: rgb(72,72,74); }
    .x .l { font-weight: 700; font-size: 7.8px; color: var(--a); margin-right: 4px; letter-spacing: .06em; }
    .x i { font-style: normal; color: rgb(150,150,155); }
    h2 { font: 700 14px ui-serif, "New York", Georgia, serif; margin: 18px 0 2px; display: flex; align-items: center; gap: 8px; break-after: avoid; page-break-after: avoid; }
    h2::after { content: ""; flex: 1; height: 1px; background: var(--r); }
    h2 span { font: 400 9px -apple-system, "PingFang TC", sans-serif; color: rgb(110,110,115); }
    .pair { break-inside: avoid; page-break-inside: avoid; display: grid; grid-template-columns: 1fr 1fr; column-gap: 18px; padding: 8px 0; border-top: 1px solid rgb(229,229,234); }
    .pair .w { font: 700 13.5px ui-serif, "New York", Georgia, serif; }
    .pair .w u { text-decoration: none; background: var(--t); border-bottom: 1.5px solid var(--a); }
    .pair .tip { grid-column: 1 / -1; margin-top: 4px; font-size: 9.3px; color: rgb(72,72,74); }

    /* 自測卷：折起來對答案 */
    .bar { display: flex; justify-content: space-between; align-items: center; margin: 2px 0 8px; font-size: 9.5px; color: rgb(110,110,115); }
    .score { border: 1.5px solid var(--a); border-radius: 8px; padding: 4px 12px; font-size: 10.5px; color: var(--a); font-weight: 600; }
    .score span { display: inline-block; width: 34px; border-bottom: 1px solid var(--a); margin: 0 4px; }
    .q { display: grid; grid-template-columns: 24px 1fr 168px 16px 118px; align-items: end; padding: 7px 0; border-bottom: 1px solid rgb(236,236,240); break-inside: avoid; page-break-inside: avoid; }
    .q.head { padding: 0 0 3px; border-bottom: 1.5px solid var(--a); font-size: 8.5px; color: rgb(110,110,115); align-items: center; }
    .q .n { font: 600 9px ui-monospace, Menlo, monospace; color: var(--a); align-self: start; padding-top: 2px; }
    .q .p { font-size: 11.5px; font-weight: 600; padding-right: 10px; }
    .q .p .ps { font: italic 400 9.5px ui-serif, "New York", Georgia, serif; color: rgb(110,110,115); margin-left: 4px; }
    .q .pw { font: 700 13px ui-serif, "New York", Georgia, serif; }
    .q .s { font: 10px/1.35 ui-serif, "New York", Georgia, serif; color: rgb(110,110,115); margin-top: 1px; padding-right: 10px; }
    .q .s b { color: rgb(28,28,30); }
    .q .line { border-bottom: 1px solid rgb(72,72,74); height: 21px; font: 9px ui-monospace, Menlo, monospace; color: rgb(190,190,194); letter-spacing: .08em; padding-left: 2px; white-space: nowrap; overflow: hidden; }
    .q .fold { align-self: stretch; border-left: 1px dashed rgb(170,170,175); margin-left: 8px; margin-top: -7px; margin-bottom: -7px; }
    .q.head .fold { margin: 0 0 -3px 8px; }
    .q .key { font-size: 10px; color: var(--a); padding-left: 2px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .q .key.en { font: 600 10.5px ui-serif, "New York", Georgia, serif; }

    /* 速查表：照熟悉度分組 */
    .grp { margin-top: 12px; }
    .grp h3 { margin: 0 0 3px; padding-bottom: 3px; border-bottom: 1.5px solid var(--a); font-size: 11px; display: flex; align-items: baseline; gap: 6px; break-after: avoid; page-break-after: avoid; }
    .grp h3 i { width: 7px; height: 7px; border-radius: 50%; background: var(--a); display: inline-block; }
    .grp h3 span { font-weight: 400; font-size: 9px; color: rgb(110,110,115); }
    .list { columns: 3; column-gap: 18px; }
    .it { break-inside: avoid; page-break-inside: avoid; display: flex; align-items: baseline; gap: 5px; padding: 2.6px 0; border-bottom: 1px dotted rgb(220,220,224); font-size: 9.6px; white-space: nowrap; overflow: hidden; }
    .it b { font: 700 10.6px ui-serif, "New York", Georgia, serif; }
    .it .ps { font: italic 8.4px ui-serif, "New York", Georgia, serif; color: rgb(150,150,155); }
    .it .z { overflow: hidden; text-overflow: ellipsis; color: rgb(58,58,60); }
    """

    private static func header(options: HandoutOptions, rangeTitle: String, count: Int, meta: String) -> String {
        """
        <header class="top"><div><div class="k">ENRECALL</div>\
        <h1>\(esc(options.kind.title))<small>\(esc(rangeTitle))</small></h1></div>\
        <div class="r"><div class="big">\(count)<span>字</span></div><div class="meta">\(esc(meta))</div></div></header>
        """
    }

    // MARK: 講義

    private static func notes(_ entries: [HandoutEntry], amount: HandoutAmount) -> String {
        var html = "<p class=\"note\">右上的長條＝現在記得的程度　<b>螢光</b>＝這個字在例句裡</p><div class=\"cards\">"
        for (index, entry) in entries.enumerated() {
            if entry.isPattern {
                html += patternCard(entry, index: index, amount: amount)
            } else if entry.isPhrase {
                html += phraseCard(entry, index: index, amount: amount)
            } else {
                html += wordCard(entry, index: index, amount: amount)
            }
        }
        html += "</div>"
        let pairs = similarPairs(entries)
        if !pairs.isEmpty {
            html += "<h2>易混淆<span>\(pairs.count) 組</span></h2>"
            html += pairs.map { pairBlock($0, amount: amount) }.joined()
        }
        return html
    }

    /// 單字、記憶條、級別
    private static func head(_ entry: HandoutEntry, index: Int, title: String, small: Bool = false, phonetic: String? = nil, label: String? = nil) -> String {
        var html = "<div class=\"h\"><span class=\"n\">\(String(format: "%02d", index + 1))</span>"
        html += "<span class=\"w\(small ? " p" : "")\">\(esc(title))</span>"
        if let phonetic, !phonetic.isEmpty { html += "<span class=\"ph\">\(esc(phonetic))</span>" }
        html += "<span class=\"st\">"
        if let label { html += "<span class=\"lv\">\(esc(label))</span>" }
        if entry.card.lapses > 0 { html += "<span>忘 \(entry.card.lapses)</span>" }
        html += memory(entry) + "</span></div>"
        return html
    }

    private static func memory(_ entry: HandoutEntry) -> String {
        guard let recall = entry.recall else { return "<span class=\"fresh\">新字</span>" }
        let filled = min(5, max(0, Int((recall * 5).rounded())))
        let bars = (0..<5).map { $0 < filled ? "<i class=\"on\"></i>" : "<i></i>" }.joined()
        return "<span class=\"bars\">\(bars)</span>"
    }

    private static func example(_ en: String, _ zh: String?, highlighter: Highlighter) -> String {
        "<div class=\"ex\">\(bolded(en, highlighter: highlighter))\(zh.map { "<span class=\"zh\">\(esc($0))</span>" } ?? "")</div>"
    }

    private static func extra(_ label: String, _ content: String) -> String {
        "<div class=\"x\"><span class=\"l\">\(esc(label))</span>\(content)</div>"
    }

    private static func wordCard(_ entry: HandoutEntry, index: Int, amount: HandoutAmount) -> String {
        let card = entry.card
        let word = entry.detail?.word
        let highlighter = Highlighter.forCard(card, detail: entry.detail)
        var html = "<div class=\"e\">" + head(entry, index: index, title: card.word,
                                               phonetic: word?.phonetic ?? card.phonetic, label: entry.levelText)
        var body = ""

        // 字義：一個詞性一段
        let meanings = (word?.meanings ?? []).filter { $0.zh != nil }
        if meanings.isEmpty {
            body += "<div class=\"mn\">\(posSpan(card.pos))\(esc(card.zh.replacingOccurrences(of: "\n", with: "；")))</div>"
        } else {
            let shown = amount == .brief ? Array(meanings.prefix(3)) : meanings
            let text = shown.map { "\(posSpan($0.pos))\(esc($0.zh ?? ""))" }.joined(separator: "<span class=\"sep\">/</span>")
            body += "<div class=\"mn\">\(text)</div>"
        }

        if amount != .brief {
            if let first = meanings.lazy.compactMap({ $0.examples.first }).first {
                body += example(first.en, first.zh, highlighter: highlighter)
            } else if let en = card.example, !en.isEmpty {
                body += example(en, card.exampleZh, highlighter: highlighter)
            }
            if let word {
                let collocations = word.allCollocations.prefix(2)
                if !collocations.isEmpty {
                    body += extra("搭配", collocations.map { "\(esc($0.en))\($0.zh.map { " <i>\(esc($0))</i>" } ?? "")" }.joined(separator: "；"))
                }
                let synonyms = word.synonyms.filter { !($0.tag ?? []).contains("beyond") && $0.word.lowercased() != word.word.lowercased() }.prefix(3)
                if !synonyms.isEmpty {
                    body += extra("近義", synonyms.map { "\(esc($0.word))\($0.zh.map { " <i>\(esc($0))</i>" } ?? "")" }.joined(separator: " · "))
                }
                let antonyms = word.antonyms.prefix(3)
                if !antonyms.isEmpty {
                    body += extra("反義", antonyms.map { "\(esc($0.word))\($0.zh.map { " <i>\(esc($0))</i>" } ?? "")" }.joined(separator: " · "))
                }
                let confusables = word.confusables.compactMap(\.words).prefix(3)
                if !confusables.isEmpty {
                    body += extra("別搞混", confusables.map(esc).joined(separator: " · "))
                }
            }
        }

        if amount == .full, let word {
            if let forms = word.forms { body += extra("變化", esc(forms)) }
            if let pattern = meanings.lazy.compactMap({ $0.patterns.first }).first {
                body += extra("句型", esc(pattern.pattern) + (pattern.en.map { " <i>\(esc($0))</i>" } ?? ""))
            }
            if let error = word.commonErrors.first(where: { $0.wrong != nil && $0.right != nil }),
               let wrong = error.wrong, let right = error.right {
                body += extra("常錯", "<s>\(esc(wrong))</s> → \(esc(right))")
            }
            if !word.breakdown.isEmpty {
                body += extra("字源", word.breakdown.map { "\(esc($0.part))\($0.gloss.map { " <i>\(esc($0))</i>" } ?? "")" }.joined(separator: " + "))
            } else if let origin = word.origin {
                body += extra("字源", esc(origin))
            }
            if !word.related.isEmpty {
                body += extra("同根", word.related.prefix(4).map { esc($0.word) }.joined(separator: " · "))
            }
        }
        html += "<div class=\"d\">\(body)</div></div>"
        return html
    }

    private static func phraseCard(_ entry: HandoutEntry, index: Int, amount: HandoutAmount) -> String {
        let card = entry.card
        let phrase = entry.detail?.phrase
        let highlighter = Highlighter.forCard(card, detail: entry.detail)
        let label: String? = switch phrase?.tier {
        case 1: "核心"
        case 2: "常見"
        case .some: "看得懂就好"
        case nil: nil
        }
        var html = "<div class=\"e\">" + head(entry, index: index, title: card.word, small: true, label: label)
        var body = "<div class=\"mn\">\(posSpan(phrase?.pos ?? card.pos))\(esc(phrase?.zh ?? card.zh))"
        if amount != .brief {
            let years = phrase?.years?.split(separator: " ").count ?? 0
            if years > 0 { body += "<span class=\"sep\">/</span><span class=\"g\">學測考過 \(years) 次</span>" }
        }
        body += "</div>"
        if amount != .brief {
            if let en = phrase?.ex ?? card.example {
                body += example(en, phrase?.exZh ?? card.exampleZh, highlighter: highlighter)
            }
            if let use = phrase?.use { body += extra("用法", esc(use)) }
            if let mix = phrase?.mix { body += extra("別搞混", esc(mix)) }
        }
        html += "<div class=\"d\">\(body)</div></div>"
        return html
    }

    private static func patternCard(_ entry: HandoutEntry, index: Int, amount: HandoutAmount) -> String {
        let card = entry.card
        let pattern = entry.detail?.pattern
        let highlighter = Highlighter.forCard(card, detail: entry.detail)
        var html = "<div class=\"e\">" + head(entry, index: index, title: pattern?.pattern ?? card.word, small: true, label: "句型")
        var body = "<div class=\"mn\">\(esc(pattern?.zh ?? card.zh))</div>"
        if amount != .brief {
            if let explanation = pattern?.explanation { body += "<div class=\"x\">\(esc(explanation))</div>" }
            if let pattern, !pattern.examples.isEmpty {
                for item in pattern.examples.prefix(2) { body += example(item.en, item.zh, highlighter: highlighter) }
            } else if let en = card.example, !en.isEmpty {
                body += example(en, card.exampleZh, highlighter: highlighter)
            }
        }
        if amount == .full, let pattern {
            if !pattern.slots.isEmpty {
                body += extra("填入", pattern.slots.map { "\(esc($0.slot))\($0.accepts.map { "：\(esc($0))" } ?? "")" }.joined(separator: "；"))
            }
            if !pattern.collocations.isEmpty {
                body += extra("搭配", pattern.collocations.prefix(3).map { esc($0.en) }.joined(separator: " · "))
            }
            if let error = pattern.errors.first(where: { $0.wrong != nil && $0.right != nil }),
               let wrong = error.wrong, let right = error.right {
                body += extra("常錯", "<s>\(esc(wrong))</s> → \(esc(right))")
            }
            if let tips = pattern.tips { body += extra("記法", esc(tips)) }
        }
        html += "<div class=\"d\">\(body)</div></div>"
        return html
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

    private static func pairBlock(_ pair: SimilarPair, amount: HandoutAmount) -> String {
        let (a, b) = underlinedDifference(pair.a, pair.b)
        func side(_ marked: String, _ word: String, _ zh: String?, _ sentence: SimilarPair.Sentence?) -> String {
            var html = "<div><span class=\"w\">\(marked)</span> <span class=\"g\">\(esc(zh ?? ""))</span>"
            if amount != .brief, let sentence {
                html += example(sentence.en, sentence.zh, highlighter: Highlighter(word: word))
            }
            return html + "</div>"
        }
        var html = "<div class=\"pair\">" + side(a, pair.a, pair.aZh, pair.exA) + side(b, pair.b, pair.bZh, pair.exB)
        var tip = pair.diff.map { "<b>\(esc($0))</b>" } ?? ""
        if amount != .brief, let more = pair.tip { tip += (tip.isEmpty ? "" : "　") + esc(more) }
        if amount == .full, !pair.points.isEmpty { tip += "　" + pair.points.map(esc).joined(separator: "　") }
        if !tip.isEmpty { html += "<div class=\"tip\">\(tip)</div>" }
        return html + "</div>"
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
        let how = direction == .zhToEn ? "看中文和挖空的例句寫英文，灰色是首字母和字母數" : "看英文寫中文"
        var html = """
        <div class="bar"><span>\(how)。寫完沿虛線往後折，蓋住右邊的答案再對。</span>\
        <span class="score">得分<span></span>/ \(entries.count)</span></div>\
        <div class="q head"><span></span><span>題目</span><span>作答</span><span class="fold"></span><span>答案（往後折）</span></div>
        """
        for (index, entry) in entries.enumerated() {
            let number = String(format: "%02d", index + 1)
            let card = entry.card
            let highlighter = Highlighter.forCard(card, detail: entry.detail)
            let zh = shortZh(entry)
            var prompt: String
            var line = ""
            let key: String
            switch direction {
            case .zhToEn:
                prompt = "<div class=\"p\">\(esc(zh))\(posSpan(card.pos, trailing: false))</div>"
                if let sentence = blankedExample(entry, highlighter: highlighter) {
                    prompt += "<div class=\"s\">\(esc(sentence))</div>"
                }
                line = esc(letterHint(card.word))
                key = "<div class=\"key en\">\(esc(card.word))</div>"
            case .enToZh:
                prompt = "<div class=\"pw\">\(esc(card.word))\(posSpan(card.pos, trailing: false))</div>"
                if let en = examples(entry).first?.0 {
                    prompt += "<div class=\"s\">\(bolded(en, highlighter: highlighter))</div>"
                }
                key = "<div class=\"key\">\(esc(zh))</div>"
            }
            html += "<div class=\"q\"><span class=\"n\">\(number)</span><div>\(prompt)</div><div class=\"line\">\(line)</div><span class=\"fold\"></span>\(key)</div>"
        }
        return html
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

    /// 速查表的分組：記得的機率
    enum SheetGroup: CaseIterable {
        case shaky, almost, solid, fresh

        var title: String {
            switch self {
            case .shaky: "還不熟"
            case .almost: "快記住了"
            case .solid: "穩了"
            case .fresh: "新字"
            }
        }

        static func of(_ entry: HandoutEntry) -> SheetGroup {
            guard let recall = entry.recall else { return .fresh }
            if recall < 0.8 || entry.card.lapses >= 3 { return .shaky }
            return recall < 0.92 ? .almost : .solid
        }
    }

    private static func sheet(_ entries: [HandoutEntry]) -> String {
        let groups = Dictionary(grouping: entries, by: SheetGroup.of)
        var html = ""
        for group in SheetGroup.allCases {
            guard let items = groups[group], !items.isEmpty else { continue }
            html += "<section class=\"grp\"><h3><i></i>\(group.title)<span>\(items.count) 字</span></h3><div class=\"list\">"
            for entry in items.sorted(by: { $0.card.wordNorm < $1.card.wordNorm }) {
                let zh = shortZh(entry).split(separator: "；").first.map(String.init) ?? ""
                html += "<div class=\"it\"><b>\(esc(entry.card.word))</b>\(posSpan(entry.card.pos, trailing: false))<span class=\"z\">\(esc(zh))</span></div>"
            }
            html += "</div></section>"
        }
        return html
    }

    // MARK: 小工具

    private static func posSpan(_ pos: String?, trailing: Bool = true) -> String {
        guard let pos, !pos.isEmpty else { return "" }
        return "<span class=\"ps\">\(esc(pos))</span>" + (trailing ? " " : "")
    }

    /// 英文例句：這個字（含變化形）粗體＋螢光
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
