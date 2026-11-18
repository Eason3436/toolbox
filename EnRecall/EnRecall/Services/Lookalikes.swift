import Foundation
import SwiftData

/// 長得像、容易搞混的字（adopt ≠ adapt、adult），放在卡片背面單字下面。
///
/// 不用向量模型：向量比的是「意思像」，搞混通常是「拼字像」。
/// 1. 單字包已經整理好的「易混淆」「相似字比較」排最前面
/// 2. 再從自己牌組裡找拼字只差一兩個字母的（編輯距離，相鄰對調算一步）
struct Lookalike: Hashable, Identifiable {
    let word: String
    let zh: String?
    /// 跟原本的字一樣長時，哪幾個字母不一樣（標顏色用）；長度不同就是空的
    let differing: Set<Int>

    var id: String { word.lowercased() }
}

/// 牌組裡所有單字（只有字和中文），一輪複習在背景建一次；查過的字記起來
@MainActor
final class LookalikeIndex {
    struct Entry: Sendable {
        let word: String
        let key: String
        let zh: String
    }

    static let limit = 3

    private let entries: [Entry]
    private let byKey: [String: Entry]
    private var cache: [String: [Lookalike]] = [:]

    init(entries: [Entry]) {
        self.entries = entries
        var byKey: [String: Entry] = [:]
        for entry in entries where byKey[entry.key] == nil {
            byKey[entry.key] = entry
        }
        self.byKey = byKey
    }

    /// 在背景讀所有單字卡的字和中文（片語、句型有空白，不算）
    static func build(container: ModelContainer) async -> LookalikeIndex {
        let entries = await Task.detached(priority: .utility) { () -> [Entry] in
            let context = ModelContext(container)
            var descriptor = FetchDescriptor<Card>(predicate: #Predicate { $0.isRetired == false })
            descriptor.propertiesToFetch = [\.word, \.zh]
            let cards = (try? context.fetch(descriptor)) ?? []
            return cards.compactMap { card -> Entry? in
                let key = card.word.lowercased()
                guard key.count >= 3, key.allSatisfy({ $0.isLetter }) else { return nil }
                return Entry(word: card.word, key: key, zh: card.zh)
            }
        }.value
        return LookalikeIndex(entries: entries)
    }

    func lookalikes(for card: Card, detail: CardDetail?) -> [Lookalike] {
        if let cached = cache[card.id] { return cached }
        let result = compute(word: card.word, detail: detail)
        cache[card.id] = result
        return result
    }

    private func compute(word: String, detail: CardDetail?) -> [Lookalike] {
        let key = word.lowercased()
        // 片語、句型不找
        guard detail?.phrase == nil, detail?.pattern == nil, key.allSatisfy({ $0.isLetter }) else { return [] }
        let target = Array(key)
        var seen: Set<String> = [key]
        var result: [Lookalike] = []

        func add(_ other: String, zh: String?) {
            let otherKey = other.lowercased()
            guard result.count < Self.limit, seen.insert(otherKey).inserted else { return }
            let gloss = Self.shortGloss(byKey[otherKey]?.zh ?? zh)
            result.append(Lookalike(word: other, zh: gloss, differing: Self.differing(target, Array(otherKey))))
        }

        // 1. 單字包整理好的
        for pair in detail?.similar ?? [] {
            if pair.a.lowercased() == key {
                add(pair.b, zh: pair.bZh)
            } else if pair.b.lowercased() == key {
                add(pair.a, zh: pair.aZh)
            }
        }
        for item in detail?.word?.confusables ?? [] {
            for token in Self.words(in: item.words) {
                add(token, zh: nil)
            }
        }

        // 2. 拼字像的
        if result.count < Self.limit {
            var candidates: [(entry: Entry, distance: Int, sameFirst: Bool)] = []
            for entry in entries where entry.key != key && !seen.contains(entry.key) {
                let other = Array(entry.key)
                guard abs(other.count - target.count) <= 2 else { continue }
                guard let distance = Self.distance(target, other, cutoff: 2) else { continue }
                let sameFirst = other.first == target.first
                guard Self.isLookalike(length: target.count, distance: distance, sameFirst: sameFirst,
                                       sameLast: other.last == target.last) else { continue }
                candidates.append((entry, distance, sameFirst))
            }
            candidates.sort { lhs, rhs in
                if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
                if lhs.sameFirst != rhs.sameFirst { return lhs.sameFirst }
                return lhs.entry.key < rhs.entry.key
            }
            for candidate in candidates {
                add(candidate.entry.word, zh: candidate.entry.zh)
            }
        }
        return result
    }

    /// 短字容易一抓一大把，要求比較嚴
    private static func isLookalike(length: Int, distance: Int, sameFirst: Bool, sameLast: Bool) -> Bool {
        switch length {
        case ..<4: false
        case 4: distance == 1 && sameFirst
        case 5...6: distance == 1 || (sameFirst && sameLast)
        default: distance == 1 || sameFirst
        }
    }

    /// 「abstract vs extract」「affect / effect」→ 各個英文字
    private static func words(in text: String?) -> [String] {
        guard let text else { return [] }
        return text
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
            .filter { $0.count >= 2 && $0.lowercased() != "vs" && $0.allSatisfy(\.isASCII) }
    }

    /// 「v. 適應；改編」→「適應」
    static func shortGloss(_ zh: String?) -> String? {
        guard var text = zh?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if let range = text.range(of: #"^[a-z]+\.\s*"#, options: .regularExpression) {
            text.removeSubrange(range)
        }
        let first = text.split(whereSeparator: { "；;，,、/".contains($0) }).first.map(String.init) ?? text
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 一樣長才標哪幾個字母不同
    private static func differing(_ a: [Character], _ b: [Character]) -> Set<Int> {
        guard a.count == b.count else { return [] }
        return Set(b.indices.filter { a[$0] != b[$0] })
    }

    /// 編輯距離（相鄰兩個字母對調算一步）；超過 cutoff 就回 nil
    static func distance(_ a: [Character], _ b: [Character], cutoff: Int) -> Int? {
        if abs(a.count - b.count) > cutoff { return nil }
        if a.isEmpty || b.isEmpty { return max(a.count, b.count) <= cutoff ? max(a.count, b.count) : nil }
        var previous2 = [Int](repeating: 0, count: b.count + 1)
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            var rowMin = current[0]
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var value = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    value = min(value, previous2[j - 2] + 1)
                }
                current[j] = value
                rowMin = min(rowMin, value)
            }
            if rowMin > cutoff { return nil }
            previous2 = previous
            previous = current
        }
        let result = previous[b.count]
        return result <= cutoff ? result : nil
    }
}
