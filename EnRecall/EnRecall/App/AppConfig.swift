import Foundation

/// 從 Info.plist（值來自 Config/App.xcconfig）讀後端設定
enum AppConfig {
    private static func info(_ key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }

    /// iOS 後端（ios_devices、ios_inbox、enrecall-mcp）
    static let supabaseHost = info("ERSupabaseHost")
    static let supabaseAnonKey = info("ERSupabaseAnonKey")

    /// 後端還沒部署時是 PLACEHOLDER，連接器相關功能先關掉
    static var isBackendConfigured: Bool {
        !supabaseHost.isEmpty && !supabaseHost.contains("PLACEHOLDER")
            && !supabaseAnonKey.isEmpty && !supabaseAnonKey.contains("PLACEHOLDER")
    }

    static var supabaseURL: URL? {
        isBackendConfigured ? URL(string: "https://\(supabaseHost)") : nil
    }

    /// 給 Claude 連接器用的網址
    static func connectorURL(code: String) -> URL? {
        supabaseURL?.appending(path: "functions/v1/enrecall-mcp/\(code)")
    }

    /// 單字商店（EnRecall 專案的公開 Storage，只讀）
    static let storeHost = info("ERStoreHost")

    static var storeBaseURL: URL {
        let host = storeHost.isEmpty ? "<EnRecall 專案 ref>.supabase.co" : storeHost
        return URL(string: "https://\(host)/storage/v1/object/public/packs")!
    }

    static var appVersion: String {
        let short = info("CFBundleShortVersionString")
        let build = info("CFBundleVersion")
        return "\(short) (\(build))"
    }
}
