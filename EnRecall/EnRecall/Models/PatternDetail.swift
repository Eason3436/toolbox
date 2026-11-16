import Foundation

/// 句型卡的完整內容。Claude 整理好送進收件匣（MCP add_patterns），
/// 後端的句型庫也存同一份，下次遇到同一個句型直接拿，不用重寫。格式見 supabase/DEPLOY-4.md
struct PatternDetail: Codable, Equatable {
    /// 「It is not until + 時間／子句 + that + S + V」
    var pattern: String
    /// 「直到…才…」
    var zh: String?
    /// 句型裡固定不變的字（例句裡用螢光筆標這些）：["it is not until", "that"]
    var anchors: [String]
    /// 基礎／進階／寫作
    var level: String?
    /// 語氣與場合：「正式，常用於寫作」
    var register: String?
    /// 用法說明
    var explanation: String?
    /// 每個空格可以放什麼
    var slots: [Slot]
    var examples: [Example]
    /// 其他寫法（倒裝、省略、口語版）
    var variations: [Variation]
    var collocations: [Collocation]
    /// 相近句型的比較
    var similar: [Similar]
    var errors: [ErrorItem]
    /// 記法
    var tips: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pattern = try c.requiredText(.pattern)
        zh = c.text(.zh)
        anchors = c.list(.anchors)
        level = c.text(.level)
        register = c.text(.register)
        explanation = c.text(.explanation)
        slots = c.list(.slots)
        examples = c.list(.examples)
        variations = c.list(.variations)
        collocations = c.list(.collocations)
        similar = c.list(.similar)
        errors = c.list(.errors)
        tips = c.text(.tips)
    }

    struct Slot: Codable, Equatable {
        /// 「時間／子句」
        var slot: String
        /// 「時間名詞片語，或 until 後面接完整子句」
        var accepts: String?
        /// 可以放進去的例子
        var examples: [String]

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            slot = try c.requiredText(.slot)
            accepts = c.text(.accepts)
            examples = c.list(.examples)
        }
    }

    struct Example: Codable, Equatable {
        var en: String
        var zh: String?
        /// 出處，例如雜誌名稱和期數（雜誌原句才有）
        var source: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            en = try c.requiredText(.en)
            zh = c.text(.zh)
            source = c.text(.source)
        }
    }

    struct Variation: Codable, Equatable {
        var form: String
        var note: String?
        var en: String?
        var zh: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            form = try c.requiredText(.form)
            note = c.text(.note)
            en = c.text(.en)
            zh = c.text(.zh)
        }
    }

    struct Collocation: Codable, Equatable {
        var en: String
        var zh: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            en = try c.requiredText(.en)
            zh = c.text(.zh)
        }
    }

    struct Similar: Codable, Equatable {
        var pattern: String
        var diff: String?
        var en: String?
        var zh: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            pattern = try c.requiredText(.pattern)
            diff = c.text(.diff)
            en = c.text(.en)
            zh = c.text(.zh)
        }
    }

    struct ErrorItem: Codable, Equatable {
        var wrong: String?
        var right: String?
        var note: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            wrong = c.text(.wrong)
            right = c.text(.right)
            note = c.text(.note)
        }
    }
}
