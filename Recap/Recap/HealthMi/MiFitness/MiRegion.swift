import Foundation

/// 小米健康雲區域配置。不同區域使用不同的 API 域名和時區。
enum MiRegion: String, CaseIterable, Identifiable, Sendable {
    case cn, ru, de, i2, sg, us

    var id: String { rawValue }

    /// API 基礎域名。中國區直接用 hlth.io.mi.com，其他區域加字首。
    var baseURL: String {
        switch self {
        case .cn: return "https://hlth.io.mi.com"
        default: return "https://\(rawValue).hlth.io.mi.com"
        }
    }

    /// 該區域的本地時區（用於計算日邊界）。
    var timeZone: TimeZone {
        switch self {
        case .cn, .i2, .sg: return TimeZone(secondsFromGMT: 8 * 3600)!
        case .ru: return TimeZone(secondsFromGMT: 3 * 3600)!
        case .de: return TimeZone(secondsFromGMT: 1 * 3600)!
        case .us: return TimeZone(secondsFromGMT: -8 * 3600)!
        }
    }

    var displayName: String {
        switch self {
        case .cn: return "中國大陸"
        case .ru: return "俄羅斯"
        case .de: return "歐洲"
        case .i2: return "國際"
        case .sg: return "新加坡"
        case .us: return "美國"
        }
    }

    /// 當前選中的區域（持久化到 UserDefaults，預設中國大陸）。
    static var current: MiRegion {
        get {
            let raw = UserDefaults.standard.string(forKey: Self.storageKey) ?? "cn"
            return MiRegion(rawValue: raw) ?? .cn
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.storageKey)
        }
    }

    private static let storageKey = "mi_region"
}
