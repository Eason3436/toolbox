import Foundation
import Security

/// 單字商店的下載密碼。
///
/// 單字包放在私有的 Storage，App 經過 iOS 後端的 Edge Function `enrecall-packs` 下載，每個請求都要帶這個密碼
/// （規格在 `supabase/DEPLOY-6.md`）。密碼不在程式碼、也不在 IPA 裡：使用者在設定或商店輸入一次，存在 Keychain。
enum StoreAccess {
    private static let service = "com.eason3436.enrecall.store"
    private static let account = "download-password"
    /// Keychain 不能用時（某些側載環境）退回 UserDefaults，只存在這台手機的 App 裡
    private static let fallbackKey = "storeDownloadPassword"

    static var password: String {
        get { readKeychain() ?? UserDefaults.standard.string(forKey: fallbackKey) ?? "" }
        set {
            let value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            deleteKeychain()
            UserDefaults.standard.removeObject(forKey: fallbackKey)
            guard !value.isEmpty else { return }
            if !writeKeychain(value) {
                UserDefaults.standard.set(value, forKey: fallbackKey)
            }
        }
    }

    static var hasPassword: Bool { !password.isEmpty }

    /// 商店檔案的請求：iOS 後端沒設定或還沒輸入密碼時是 nil
    static func request(path: String) -> URLRequest? {
        guard let base = AppConfig.supabaseURL else { return nil }
        let password = password
        guard !password.isEmpty else { return nil }
        var request = URLRequest(url: base.appending(path: "functions/v1/enrecall-packs").appending(path: path))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(AppConfig.supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(password, forHTTPHeaderField: "x-store-password")
        return request
    }

    /// 401／403：密碼錯了（或後端換了密碼）
    static func isDenied(_ response: URLResponse) -> Bool {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return status == 401 || status == 403
    }

    // MARK: Keychain

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func readKeychain() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func writeKeychain(_ value: String) -> Bool {
        var query = baseQuery
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private static func deleteKeychain() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

/// 商店拒絕（密碼不對或沒輸入）
struct StoreDeniedError: Error {}
