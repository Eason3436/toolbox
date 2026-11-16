import Foundation

/// 單字庫的完整內容（字義分組、例句、句型、搭配、近義字、易混淆字、常見錯誤、字源…）。
/// 存在 CardContent（JSON），畫面要用時才解開。從 Claude 寫的字沒有這些
struct CardDetail: Codable, Equatable {
    var word: WordDetail?
    var phrase: PhraseDetail?
    /// 相似字對比（similar-levelN.json）
    var similar: [SimilarPair]?
    /// 中翻英／英文填空題（quiz-levelN.json）
    var quiz: [QuizItem]? = nil
    /// 句型卡（從 Claude 送來）
    var pattern: PatternDetail? = nil
}

// MARK: - 測驗題

/// quiz-levelN.json 的一題：中文句子挖空要寫英文、英文句子挖空要填字
struct QuizItem: Codable, Equatable {
    var target: String
    var chinese: String?
    var pos: String?
    /// 「遇到困難時，別＿＿自己的夢想」
    var contextZh: String?
    var referenceEn: String?
    var accepted: [String]
    /// 「The team had to ＿＿ its outdoor practice」
    var contextEn: String?
    var contextEnZh: String?
    var acceptedEn: [String]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        target = try c.requiredText(.target)
        chinese = c.text(.chinese)
        pos = c.text(.pos)
        contextZh = c.text(.contextZh)
        referenceEn = c.text(.referenceEn)
        accepted = c.list(.accepted)
        contextEn = c.text(.contextEn)
        contextEnZh = c.text(.contextEnZh)
        acceptedEn = c.list(.acceptedEn)
    }
}

// MARK: - 寬鬆解碼：單一欄位格式不對就略過那一欄，不要讓整包解析失敗

struct Lenient<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

extension KeyedDecodingContainer {
    func lenient<T: Decodable>(_ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }

    func text(_ key: Key) -> String? {
        guard let raw: String = lenient(key) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func list<T: Decodable>(_ key: Key) -> [T] {
        let items: [Lenient<T>]? = lenient(key)
        return items?.compactMap(\.value) ?? []
    }

    func requiredText(_ key: Key) throws -> String {
        guard let value = text(key) else {
            throw DecodingError.keyNotFound(key, .init(codingPath: codingPath, debugDescription: "empty"))
        }
        return value
    }
}

// MARK: - 單字

struct WordDetail: Codable, Equatable {
    var word: String
    var phonetic: String?
    var forms: String?
    var meanings: [Meaning]
    var phrases: [WordPhrase]
    var synonyms: [Synonym]
    var antonyms: [Antonym]
    var confusables: [Confusable]
    var commonErrors: [CommonError]
    var breakdown: [BreakdownPart]
    var origin: String?
    var related: [Related]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        word = try c.requiredText(.word)
        phonetic = c.text(.phonetic)
        forms = c.text(.forms)
        meanings = c.list(.meanings)
        phrases = c.list(.phrases)
        synonyms = c.list(.synonyms)
        antonyms = c.list(.antonyms)
        confusables = c.list(.confusables)
        commonErrors = c.list(.commonErrors)
        breakdown = c.list(.breakdown)
        origin = c.text(.origin)
        related = c.list(.related)
    }

    struct Meaning: Codable, Equatable {
        var pos: String?
        var zh: String?
        /// 字義延伸（「把東西變短 → 把字詞寫成簡短的形式」）
        var ext: String?
        var examples: [Example]
        var patterns: [Pattern]
        var collocations: [Collocation]

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            pos = c.text(.pos)
            zh = c.text(.zh)
            ext = c.text(.ext)
            examples = c.list(.examples)
            patterns = c.list(.patterns)
            collocations = c.list(.collocations)
        }
    }

    struct Example: Codable, Equatable {
        var en: String
        var zh: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            en = try c.requiredText(.en)
            zh = c.text(.zh)
        }
    }

    struct Pattern: Codable, Equatable {
        var pattern: String
        var en: String?
        var zh: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            pattern = try c.requiredText(.pattern)
            en = c.text(.en)
            zh = c.text(.zh)
        }
    }

    struct Collocation: Codable, Equatable {
        var en: String
        var zh: String?
        /// 常用（Android 版的星號）
        var star: Bool?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            en = try c.requiredText(.en)
            zh = c.text(.zh)
            star = c.lenient(.star)
        }
    }

    struct WordPhrase: Codable, Equatable {
        var phrase: String
        var zh: String?
        var example: String?
        var exampleZh: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            phrase = try c.requiredText(.phrase)
            zh = c.text(.zh)
            example = c.text(.example)
            exampleZh = c.text(.exampleZh)
        }
    }

    struct Synonym: Codable, Equatable {
        var word: String
        var zh: String?
        var note: String?
        var example: String?
        var tag: [String]?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            word = try c.requiredText(.word)
            zh = c.text(.zh)
            note = c.text(.note)
            example = c.text(.example)
            tag = c.lenient(.tag)
        }
    }

    struct Antonym: Codable, Equatable {
        var word: String
        var zh: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            word = try c.requiredText(.word)
            zh = c.text(.zh)
        }
    }

    struct Confusable: Codable, Equatable {
        var words: String?
        var note: String?
        var wrong: String?
        var right: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            words = c.text(.words)
            note = c.text(.note)
            wrong = c.text(.wrong)
            right = c.text(.right)
        }
    }

    struct CommonError: Codable, Equatable {
        var wrong: String?
        var right: String?
        var note: String?
        var exWrong: String?
        var exRight: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            wrong = c.text(.wrong)
            right = c.text(.right)
            note = c.text(.note)
            exWrong = c.text(.exWrong)
            exRight = c.text(.exRight)
        }
    }

    struct BreakdownPart: Codable, Equatable {
        var part: String
        var type: String?
        var gloss: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            part = try c.requiredText(.part)
            type = c.text(.type)
            gloss = c.text(.gloss)
        }
    }

    struct Related: Codable, Equatable {
        var word: String
        var note: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            word = try c.requiredText(.word)
            note = c.text(.note)
        }
    }

    /// 常用的搭配排前面，同一個搭配只留一次
    var allCollocations: [Collocation] {
        var seen = Set<String>()
        let all = meanings.flatMap(\.collocations).filter { seen.insert($0.en.lowercased()).inserted }
        return all.filter { $0.star == true } + all.filter { $0.star != true }
    }
}

// MARK: - 片語

struct PhraseDetail: Codable, Equatable {
    var p: String
    var zh: String?
    var pos: String?
    var group: String?
    /// 1 最常考
    var tier: Int?
    /// 用法
    var use: String?
    var ex: String?
    var exZh: String?
    /// 容易混淆的說法
    var mix: String?
    /// 出現過的學測年度（「103 105 106」）
    var years: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        p = try c.requiredText(.p)
        zh = c.text(.zh)
        pos = c.text(.pos)
        group = c.text(.group)
        tier = c.lenient(.tier)
        use = c.text(.use)
        ex = c.text(.ex)
        exZh = c.text(.exZh)
        mix = c.text(.mix)
        years = c.text(.years)
    }
}

// MARK: - 相似字對比

struct SimilarPair: Codable, Equatable {
    struct Sentence: Codable, Equatable {
        var en: String
        var zh: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            en = try c.requiredText(.en)
            zh = c.text(.zh)
        }
    }

    var a: String
    var b: String
    var aZh: String?
    var bZh: String?
    var diff: String?
    var points: [String]
    var tip: String?
    var exA: Sentence?
    var exB: Sentence?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        a = try c.requiredText(.a)
        b = try c.requiredText(.b)
        aZh = c.text(.aZh)
        bZh = c.text(.bZh)
        diff = c.text(.diff)
        points = c.list(.points)
        tip = c.text(.tip)
        exA = c.lenient(.exA)
        exB = c.lenient(.exB)
    }
}
