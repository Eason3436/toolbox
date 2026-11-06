import Foundation

/// 一次成功登入後的會話憑據（對應 Python `_login_with_token` 得到的欄位）。
struct MiSessionState: Sendable {
    let userId: String
    let passToken: String
    /// 解 Base64 後的 ssecurity 原始位元組，用於派生 RC4 金鑰。
    let ssecurity: [UInt8]
    /// 重定向後收集到的會話 Cookie 串（`name=value; name=value`）。
    let cookies: String
}

enum MiLoginError: LocalizedError {
    case badPayload(String)
    case loginRejected(code: Int?, description: String?)
    case network(Error)

    var errorDescription: String? {
        switch self {
        case .badPayload(let detail):
            return "登入響應格式異常：\(detail)"
        case .loginRejected(let code, let description):
            return "登入被拒絕（code=\(code ?? -1)）：\(description ?? "未知錯誤")"
        case .network(let error):
            return "網路錯誤：\(error.localizedDescription)"
        }
    }
}

/// 登入 HTTP 客戶端（對應 Python `_login_with_token` + `_read_login_payload`）。
enum MiSessionClient {
    private static let loginPrefix = "&&&START&&&"

    /// 用小米賬號 Cookie 換取服務會話。
    /// - Parameters:
    ///   - userId: account.xiaomi.com Cookie 中的 userId
    ///   - passToken: 賬號 Cookie 中的 passToken（有效期短，過期後需重新獲取）
    static func login(userId: String, passToken: String) async throws -> MiSessionState {
        var request = URLRequest(url: URL(string: "https://account.xiaomi.com/pass/serviceLogin?_json=true&sid=miothealth")!)
        request.setValue("userId=\(userId); passToken=\(passToken)", forHTTPHeaderField: "Cookie")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MiLoginError.network(URLError(.badServerResponse))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MiLoginError.loginRejected(code: http.statusCode, description: "HTTP \(http.statusCode)")
        }
        guard let text = String(data: data, encoding: .utf8), text.hasPrefix(loginPrefix) else {
            throw MiLoginError.badPayload("響應缺少 \(loginPrefix) 字首")
        }

        let json = text.dropFirst(loginPrefix.count).data(using: .utf8) ?? Data()
        guard let obj = MiJSON.object(from: json) else {
            throw MiLoginError.badPayload("無法解析 JSON")
        }

        // 若登入被拒，服務端返回 code 而非 passToken
        if let code = MiJSON.int(obj["code"]), code != 0, obj["passToken"] == nil {
            throw MiLoginError.loginRejected(code: code, description: MiJSON.string(obj["description"]))
        }

        guard let newPassToken = MiJSON.string(obj["passToken"]),
              let ssecurityB64 = MiJSON.string(obj["ssecurity"]),
              let ssecurity = Data(base64Encoded: ssecurityB64),
              let location = MiJSON.string(obj["location"])
        else {
            throw MiLoginError.badPayload("缺少 passToken/ssecurity/location")
        }
        let resolvedUserId = MiJSON.string(obj["userId"]) ?? userId

        // 跟隨 location 收集會話 Cookie。
        guard let redirectURL = URL(string: location) else {
            throw MiLoginError.badPayload("location 無法解析為 URL")
        }
        let (_, redirectResponse) = try await URLSession.shared.data(from: redirectURL)
        guard let redirectHTTP = redirectResponse as? HTTPURLResponse else {
            throw MiLoginError.network(URLError(.badServerResponse))
        }

        // 注意：URLSession 會把多個 Set-Cookie 頭合併成一個 ", " 連線的字串，
        // 而 `value(forHTTPHeaderField:)` 只返回第一個。這裡必須解析合併串拿到全部 cookie
        // （否則會丟掉關鍵的 serviceToken，導致後續資料請求被判定未認證）。
        let cookieHeader = (redirectHTTP.allHeaderFields.first {
            ($0.key as? String)?.lowercased() == "set-cookie"
        }?.value as? String) ?? ""

        let cookieParts: [String] = cookieHeader
            .components(separatedBy: ", ")
            .compactMap { chunk in
                let nameValue = chunk.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
                return nameValue.contains("=") ? nameValue : nil
            }
        let cookies = cookieParts.joined(separator: "; ")

        return MiSessionState(
            userId: resolvedUserId,
            passToken: newPassToken,
            ssecurity: Array(ssecurity),
            cookies: cookies
        )
    }
}
