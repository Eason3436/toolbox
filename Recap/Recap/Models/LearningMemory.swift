import Foundation
import Observation

/// 一個學過的詞（例如課堂筆記裡的術語、AI 校正時改回來的英文單字）。
struct LearnedTerm: Codable, Identifiable, Hashable, Sendable {
    var id: String { "\(subject?.rawValue ?? "-")|\(term.lowercased())" }
    var term: String
    var note: String?
    var subject: SchoolSubject?
    var count: Int
    var lastSeen: Date
}

/// 學習記憶：越用越準。記住出現過的術語，之後辨識和校正都會優先參考；
/// 整理新的一堂課時，也會參考同科目上一堂課的內容。全部存在手機裡。
@MainActor
@Observable
final class LearningMemory {
    static let shared = LearningMemory()

    private(set) var terms: [LearnedTerm] = []
    private let url: URL
    static let maxTerms = 600

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        url = docs.appending(path: "learned-terms.json")
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([LearnedTerm].self, from: data) {
            terms = saved
        }
    }

    /// 記住一批詞（重複出現的會加權）。
    func learn(_ items: [(term: String, note: String?)], subject: SchoolSubject?) {
        guard AppSettings.shared.learningMemory else { return }
        var changed = false
        for item in items {
            let term = Self.clean(item.term)
            guard term.count >= 2, term.count <= 40 else { continue }
            let key = "\(subject?.rawValue ?? "-")|\(term.lowercased())"
            if let index = terms.firstIndex(where: { $0.id == key }) {
                terms[index].count += 1
                terms[index].lastSeen = .now
                if let note = item.note, !note.isEmpty { terms[index].note = note }
            } else {
                terms.append(LearnedTerm(term: term, note: item.note, subject: subject, count: 1, lastSeen: .now))
            }
            changed = true
        }
        guard changed else { return }
        if terms.count > Self.maxTerms {
            terms.sort { score($0) > score($1) }
            terms = Array(terms.prefix(Self.maxTerms))
        }
        save()
    }

    /// 從課堂筆記的「術語」學（格式：原文術語：中文解釋）。
    func learn(fromTerms lines: [String], subject: SchoolSubject?) {
        let items = lines.map { line -> (String, String?) in
            for sep in ["：", ":", "－", " - ", "（", "("] {
                if let range = line.range(of: sep) {
                    let term = String(line[..<range.lowerBound])
                    let note = String(line[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " ）)"))
                    return (term, note)
                }
            }
            return (line, nil)
        }
        learn(items, subject: subject)
    }

    /// AI 校正後才出現的英文詞（原本被辨識成中文諧音），就是值得記住的詞。
    func learn(corrected: String, original: String, subject: SchoolSubject?) {
        let before = Set(Self.latinWords(original).map { $0.lowercased() })
        let added = Self.latinWords(corrected).filter { !before.contains($0.lowercased()) && $0.count >= 3 }
        let common: Set<String> = ["the", "and", "you", "are", "for", "that", "this", "with", "okay", "ok", "yes"]
        learn(added.filter { !common.contains($0.lowercased()) }.map { ($0, nil) }, subject: subject)
    }

    /// 給辨識器的提示詞：同科目的先，再來是不分科的，常出現的優先。
    func vocabulary(for subject: SchoolSubject?, limit: Int) -> [String] {
        guard AppSettings.shared.learningMemory else { return [] }
        let relevant = terms.filter { $0.subject == nil || $0.subject == subject }
        return relevant.sorted { a, b in
            let sa = score(a) + (a.subject == subject && subject != nil ? 5 : 0)
            let sb = score(b) + (b.subject == subject && subject != nil ? 5 : 0)
            return sa > sb
        }
        .prefix(limit)
        .map(\.term)
    }

    func remove(_ term: LearnedTerm) {
        terms.removeAll { $0.id == term.id }
        save()
    }

    func add(_ term: String, subject: SchoolSubject?) {
        let saved = AppSettings.shared.learningMemory
        if !saved { return }
        learn([(term, nil)], subject: subject)
    }

    func clear() {
        terms = []
        save()
    }

    private func score(_ t: LearnedTerm) -> Double {
        // 次數越多越重要，太久沒出現的慢慢降低
        let days = Date().timeIntervalSince(t.lastSeen) / 86_400
        return Double(t.count) - days / 30
    }

    private func save() {
        if let data = try? JSONEncoder().encode(terms) { try? data.write(to: url, options: .atomic) }
    }

    private static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-•・*「」『』\"'★")))
    }

    private static func latinWords(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        for ch in text {
            if ch.isASCII, ch.isLetter || (ch == "-" && !current.isEmpty) {
                current.append(ch)
            } else {
                if current.count >= 2 { words.append(current) }
                current = ""
            }
        }
        if current.count >= 2 { words.append(current) }
        return words
    }

    // MARK: - 之前上過的課

    /// 同科目最近一堂（已整理好的）課，給新的一堂課當背景。
    static func previousLectureContext(for lecture: Lecture, in store: RecapStore) -> String {
        guard AppSettings.shared.learningMemory, let subject = lecture.subject, subject != .general else { return "" }
        let previous = store.allLectures
            .filter { $0.id != lecture.id && $0.subject == subject && $0.start < lecture.start }
            .compactMap { l -> (Lecture, LectureSummary)? in
                guard let s = l.summary, !s.title.isEmpty else { return nil }
                return (l, s)
            }
            .prefix(2)
        guard !previous.isEmpty else { return "" }
        let lines = previous.map { l, s in
            "・\(l.start.formatted(.dateTime.month().day()))「\(s.title)」：\(s.keyPoints.prefix(3).joined(separator: "；"))"
        }
        return "之前的\(subject.title)課（可用來理解這堂課的脈絡，例如延續的單元；但筆記只寫這堂課的內容）：\n" + lines.joined(separator: "\n")
    }
}
