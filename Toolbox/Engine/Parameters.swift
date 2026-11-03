import Foundation

/// 參數值：數字、開關或文字。功能包 JSON 也用同一種格式。
enum ParamValue: Codable, Hashable, Sendable {
    case number(Double)
    case bool(Bool)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }

    var doubleValue: Double? {
        switch self {
        case .number(let value): return value
        case .bool(let value): return value ? 1 : 0
        case .string(let value): return Double(value)
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let value): return value
        case .number(let value): return value != 0
        case .string(let value): return ["true", "1", "yes"].contains(value.lowercased())
        }
    }

    var stringValue: String {
        switch self {
        case .string(let value): return value
        case .bool(let value): return value ? "true" : "false"
        case .number(let value):
            return value.rounded() == value ? String(Int(value)) : String(value)
        }
    }
}

struct ParamOption: Codable, Hashable, Sendable {
    var value: String
    var label: String
}

/// 一個參數的說明，App 會依此自動產生原生的設定畫面。
struct ParameterSpec: Codable, Hashable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable {
        case choice, number, toggle, text
    }

    var key: String
    var title: String
    var kind: Kind
    var options: [ParamOption]?
    var minValue: Double?
    var maxValue: Double?
    var step: Double?
    var unit: String?
    var placeholder: String?
    var footer: String?
    var defaultValue: ParamValue
    /// 只有在其他參數等於指定值時才顯示，例如 ["mode": "size"]。
    var showIf: [String: String]?

    var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key, title, kind, options, step, unit, placeholder, footer, showIf
        case minValue = "min"
        case maxValue = "max"
        case defaultValue = "default"
    }

    static func choice(_ key: String, _ title: String, _ options: [(String, String)],
                       default value: String, footer: String? = nil,
                       showIf: [String: String]? = nil) -> ParameterSpec {
        ParameterSpec(key: key, title: title, kind: .choice,
                      options: options.map { ParamOption(value: $0.0, label: $0.1) },
                      minValue: nil, maxValue: nil, step: nil, unit: nil, placeholder: nil,
                      footer: footer, defaultValue: .string(value), showIf: showIf)
    }

    static func number(_ key: String, _ title: String, range: ClosedRange<Double>, step: Double,
                       default value: Double, unit: String? = nil, footer: String? = nil,
                       showIf: [String: String]? = nil) -> ParameterSpec {
        ParameterSpec(key: key, title: title, kind: .number, options: nil,
                      minValue: range.lowerBound, maxValue: range.upperBound, step: step, unit: unit,
                      placeholder: nil, footer: footer, defaultValue: .number(value), showIf: showIf)
    }

    static func toggle(_ key: String, _ title: String, default value: Bool, footer: String? = nil,
                       showIf: [String: String]? = nil) -> ParameterSpec {
        ParameterSpec(key: key, title: title, kind: .toggle, options: nil,
                      minValue: nil, maxValue: nil, step: nil, unit: nil, placeholder: nil,
                      footer: footer, defaultValue: .bool(value), showIf: showIf)
    }

    static func text(_ key: String, _ title: String, default value: String, placeholder: String? = nil,
                     footer: String? = nil, showIf: [String: String]? = nil) -> ParameterSpec {
        ParameterSpec(key: key, title: title, kind: .text, options: nil,
                      minValue: nil, maxValue: nil, step: nil, unit: nil, placeholder: placeholder,
                      footer: footer, defaultValue: .string(value), showIf: showIf)
    }

    func isVisible(with values: [String: ParamValue]) -> Bool {
        guard let showIf else { return true }
        for (key, expected) in showIf {
            let actual = values[key]?.stringValue ?? ""
            let allowed = expected.split(separator: "|").map(String.init)
            if !allowed.contains(actual) { return false }
        }
        return true
    }
}

struct Params: Sendable {
    var values: [String: ParamValue]

    func double(_ key: String, _ fallback: Double) -> Double { values[key]?.doubleValue ?? fallback }
    func int(_ key: String, _ fallback: Int) -> Int { Int(values[key]?.doubleValue ?? Double(fallback)) }
    func bool(_ key: String, _ fallback: Bool) -> Bool { values[key]?.boolValue ?? fallback }
    func string(_ key: String, _ fallback: String) -> String { values[key]?.stringValue ?? fallback }

    static func defaults(for specs: [ParameterSpec]) -> [String: ParamValue] {
        var result: [String: ParamValue] = [:]
        for spec in specs { result[spec.key] = spec.defaultValue }
        return result
    }
}

/// 時間字串：「90」、「1:30」、「1:02:03.5」都可以。
enum TimeText {
    static func seconds(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }

    static func list(_ text: String) -> [Double] {
        text.split(whereSeparator: { ",，、; ".contains($0) })
            .compactMap { seconds(String($0)) }
            .sorted()
    }

    static func string(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--" }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
