import Foundation
import Security

/// 配對碼存在 Keychain：SideStore 續簽、覆蓋安裝都還在，Claude 那邊的連接器網址不用重設
enum PairingCodeStore {
    private static let service = "com.eason3436.enrecall.pairing"
    private static let account = "pairing-code"
    /// 伺服器規定 A-Z a-z 0-9（見 EnRecall/supabase/DEPLOY.md 5.2）
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")

    static func generate(length: Int = 24) -> String {
        var rng = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet.randomElement(using: &rng) ?? "a" })
    }

    static func isValid(_ code: String) -> Bool {
        (16...128).contains(code.count) && code.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    static func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let code = String(data: data, encoding: .utf8),
              isValid(code) else { return nil }
        return code
    }

    @discardableResult
    static func save(_ code: String) -> Bool {
        SecItemDelete(baseQuery as CFDictionary)
        var query = baseQuery
        query[kSecValueData as String] = Data(code.utf8)
        // 背景（例如捷徑）也能讀
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
