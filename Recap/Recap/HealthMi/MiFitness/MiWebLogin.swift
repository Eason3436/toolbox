import Foundation

/// 小米網頁登入的常量與 Cookie 提取邏輯。
///
/// 登入頁與 `MiSessionClient.login` 使用相同的 SID，使用者在小米官方頁面完成
/// 登入（含驗證碼/簡訊二次驗證）後，`account.xiaomi.com` 域會下發 `userId`、
/// `passToken` 等 Cookie；這裡只負責從 WebView 的 Cookie 裡挑出這兩個值，
/// 之後繼續走既有的 token → 會話交換鏈路。
enum MiWebLogin {
    /// 小米官方登入頁（`_json=true` 與 `MiSessionClient.login` 保持一致）。
    static let loginURL = URL(string: "https://account.xiaomi.com/pass/serviceLogin?sid=miothealth")!

    /// 登入成功後需要捕獲的兩個 Cookie 名。
    static let userIdCookie = "userId"
    static let passTokenCookie = "passToken"

    /// 從 WebView 的 Cookie 中提取 `userId` + `passToken`。
    /// - Parameter cookies: `WKHTTPCookieStore.getAllCookies()` 返回的全部 Cookie。
    /// - Returns: 兩個值都存在且非空時返回，否則返回 `nil`（尚未登入成功）。
    static func credentials(from cookies: [HTTPCookie]) -> (userId: String, passToken: String)? {
        let values = Dictionary(
            cookies
                .filter { $0.domain.contains("account.xiaomi.com") }
                .map { ($0.name, $0.value) },
            uniquingKeysWith: { _, last in last }
        )
        guard let userId = values[userIdCookie], !userId.isEmpty,
              let passToken = values[passTokenCookie], !passToken.isEmpty
        else {
            return nil
        }
        return (userId, passToken)
    }
}
