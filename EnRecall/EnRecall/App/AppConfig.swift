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

    /// 單元測試會把 App 當 host 啟動：這時不要連後端（不然每次 CI 都會註冊一個配對碼）
    static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    static var supabaseURL: URL? {
        isBackendConfigured ? URL(string: "https://\(supabaseHost)") : nil
    }

    /// 給 Claude 連接器用的網址
    static func connectorURL(code: String) -> URL? {
        supabaseURL?.appending(path: "functions/v1/enrecall-mcp/\(code)")
    }

    /// 「0.10.0」：更新日誌比對目前版本用
    static var shortVersion: String { info("CFBundleShortVersionString") }

    static var appVersion: String {
        let short = info("CFBundleShortVersionString")
        let build = info("CFBundleVersion")
        return "\(short) (\(build))"
    }
}
