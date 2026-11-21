import Foundation
import UIKit

/// Info.plist 裡由 CI 注入的設定（見 Config/App.xcconfig）
enum AppConfig {
    static var googleClientID: String? {
        guard let v = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String,
              v.hasSuffix(".apps.googleusercontent.com") else { return nil }
        return v
    }

    /// TMDB API Key：在 App 的「設定」輸入，存在鑰匙圈（不編進 IPA，公開的 Release 裡看不到）
    static var tmdbAPIKey: String? {
        get {
            guard let v = Keychain.string("tmdbAPIKey")?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
            return v
        }
        set { Keychain.set(newValue?.trimmingCharacters(in: .whitespacesAndNewlines), for: "tmdbAPIKey") }
    }

    static var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        return "\(v)（\(b)）"
    }
}

extension UIApplication {
    /// 目前最上層的 view controller（Google 登入要用它來顯示網頁）
    @MainActor var topViewController: UIViewController? {
        let window = connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
