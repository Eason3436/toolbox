import Foundation
import os

enum MiAPIError: LocalizedError {
    case notConnected
    case api(code: Int, message: String?)
    case paginationLimit
    case cursorLoop
    case invalidResponse(String)
    case network(Error)
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "尚未登入小米服務"
        case .api(let code, let message):
            return "小米 API 錯誤（code=\(code)）：\(message ?? "未知")"
        case .paginationLimit:
            return "分頁超過安全上限"
        case .cursorLoop:
            return "分頁遊標迴圈，已終止"
        case .invalidResponse(let detail):
            return "響應解析失敗：\(detail)"
        case .network(let error):
            return "網路錯誤：\(error.localizedDescription)"
        case .http(let code):
            return "HTTP 錯誤：\(code)"
        }
    }

    /// 是否可重試（網路錯誤、429/5xx 類 HTTP 錯誤）。
    var isRetriable: Bool {
        switch self {
        case .network: return true
        case .http(let code): return code == 429 || (500...599).contains(code)
        default: return false
        }
    }

    /// 是否認證錯誤（passToken 過期/無效，code=70016），不可重試。
    var isAuthError: Bool {
        if case .api(let code, _) = self, code == 70016 { return true }
        return false
    }
}

/// 小米健康雲資料客戶端。Swift 移植自 `mi_fitness_cloud.MiFitnessCloudAdapter`。
///
/// 行為要點（與 Python 完全一致）：
/// - 用 Cookie 登入換取 `ssecurity` 與重定向會話 Cookie；
/// - 每個請求體用 `signed_nonce = SHA256(ssecurity||nonce)` 做 RC4 加密 + SHA1 簽名；
/// - 資料介面 `get_fitness_data_by_time` 按 key 分頁拉取；
/// - 運動記錄走獨立的 `get_sport_records_by_time`。
actor MiAPIClient {
    /// 當前區域的時區（用於日邊界計算）。
    static var regionTimeZone: TimeZone { MiRegion.current.timeZone }


    /// 最多重試次數（不含首次請求）。
    private let maxRetries = 3
    /// 分頁請求間隔（納秒），避免高頻請求觸發小米限流。
    private let pageDelayNs: UInt64 = 200_000_000

    private var baseURL: String { MiRegion.current.baseURL }
    private let dataPath = "/app/v1/data/get_fitness_data_by_time"
    private let sportRecordsPath = "/app/v1/data/get_sport_records_by_time"
    private let maxPages = 200

    private var state: MiSessionState?
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        // 與 Python 一致：手動管理 Cookie，不交給 URLSession 的儲存。
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    var isConnected: Bool { state != nil }

    /// 登入並建立會話。
    func connect(userId: String, passToken: String) async throws {
        self.state = try await MiSessionClient.login(userId: userId, passToken: passToken)
    }

    // MARK: - 請求籤名與傳送（對應 Python `_request`）

    /// 按 Python 端字典插入順序（start_time, end_time, key, limit?, next_key?）生成緊湊 JSON，
    /// 保證與已驗證實現逐位元組一致（JSONSerialization 的鍵序不確定，不能使用）。
    static func dataString(
        startTime: Int, endTime: Int, key: String, limit: Int? = nil, nextKey: String? = nil
    ) -> String {
        var s = "{\"start_time\":\(startTime),\"end_time\":\(endTime),\"key\":\"\(key)\""
        if let limit { s += ",\"limit\":\(limit)" }
        if let nextKey { s += ",\"next_key\":\"\(nextKey)\"" }
        s += "}"
        return s
    }

    /// 帶重試的簽名請求：網路錯誤和 429/5xx HTTP 錯誤自動重試，
    /// 認證錯誤（code=70016）不重試直接丟擲。
    private func signedRequest(path: String, dataString: String) async throws -> [String: Any] {
        let retries = maxRetries
        var lastError: Error?
        for attempt in 0...retries {
            if attempt > 0 {
                // 指數退避：1s → 2s → 4s，加 0–200ms 隨機抖動
                let baseDelay = UInt64(pow(2.0, Double(attempt - 1))) * 1_000_000_000
                let jitter = UInt64.random(in: 0...200_000_000)
                AppLog.apiClient.info("重試 \(attempt)/\(retries) path=\(path)")
                try? await Task.sleep(nanoseconds: baseDelay + jitter)
            }
            do {
                return try await signedRequestOnce(path: path, dataString: dataString)
            } catch let error as MiAPIError {
                if error.isAuthError || !error.isRetriable {
                    throw error
                }
                lastError = error
            } catch {
                lastError = error
            }
        }
        throw lastError ?? MiAPIError.invalidResponse("重試耗盡")
    }

    private func signedRequestOnce(path: String, dataString: String) async throws -> [String: Any] {
        guard let state else { throw MiAPIError.notConnected }

        var form: [String: String] = ["data": dataString]
        let nonce = MiCrypto.genNonce()
        let signedNonce = MiCrypto.genSignedNonce(ssecurity: state.ssecurity, nonce: nonce)

        // 第一次簽名只含 data
        form["rc4_hash__"] = MiCrypto.genSignature(
            method: "POST", path: path, values: form, signedNonce: signedNonce
        )

        // 用 RC4 加密 data 與 rc4_hash__，再對加密值簽名
        var encrypted: [String: String] = [:]
        for (key, value) in form {
            let cipher = MiCrypto.rc4Crypt(key: signedNonce, payload: Array(value.utf8))
            encrypted[key] = Data(cipher).base64EncodedString()
        }
        encrypted["signature"] = MiCrypto.genSignature(
            method: "POST", path: path, values: encrypted, signedNonce: signedNonce
        )
        encrypted["_nonce"] = Data(nonce).base64EncodedString()

        var request = URLRequest(url: URL(string: baseURL + path)!)
        request.httpMethod = "POST"
        request.setValue(state.cookies, forHTTPHeaderField: "Cookie")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // Python `urlencode`：值做百分號編碼（Base64 中的 + / = 必須轉義）
        let body = encrypted
            .map { "\($0.key)=\(percentEncode($0.value))" }
            .joined(separator: "&")
        request.httpBody = Data(body.utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MiAPIError.network(error)
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            AppLog.apiClient.error("HTTP \(http.statusCode) path=\(path)")
            throw MiAPIError.http(http.statusCode)
        }
        guard let base64 = String(data: data, encoding: .utf8),
              let cipher = Data(base64Encoded: base64)
        else {
            throw MiAPIError.invalidResponse("響應不是合法 Base64")
        }

        let plain = MiCrypto.rc4Crypt(key: signedNonce, payload: Array(cipher))
        guard let obj = MiJSON.object(from: Data(plain)) else {
            throw MiAPIError.invalidResponse("解密後不是合法 JSON")
        }
        let code = MiJSON.int(obj["code"]) ?? -1
        guard code == 0 else {
            throw MiAPIError.api(code: code, message: MiJSON.string(obj["message"]))
        }
        // 與 Python 一致：返回內層 result 字典（data_list / sport_records 都在裡面）
        return MiJSON.object(from: Data(plain))?["result"] as? [String: Any] ?? [:]
    }

    private func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }

    // MARK: - 分頁拉取

    /// 按 key 拉取某時間區間的資料（對應 `_fetch_key`）。
    func fetchData(key: String, startTime: Int, endTime: Int) async throws -> [MiItem] {
        var items: [MiItem] = []
        var nextKey: String?
        var seen = Set<String>()
        var page = 0
        while true {
            page += 1
            guard page <= maxPages else { throw MiAPIError.paginationLimit }
            let body = Self.dataString(
                startTime: startTime, endTime: endTime, key: key, nextKey: nextKey
            )
            let result = try await signedRequest(path: dataPath, dataString: body)

            if let list = result["data_list"] as? [[String: Any]] {
                items.append(contentsOf: list.map(Self.makeItem))
            }
            let hasMore = MiJSON.bool(result["has_more"]) ?? false
            let cursor = MiJSON.string(result["next_key"])
            if !hasMore || cursor == nil { break }
            if seen.contains(cursor!) { throw MiAPIError.cursorLoop }
            seen.insert(cursor!)
            nextKey = cursor
            // 分頁請求間隔，避免高頻請求觸發小米限流
            try? await Task.sleep(nanoseconds: pageDelayNs)
        }
        return items
    }

    /// 拉取運動記錄（對應 `_fetch_sport_records_by_time`）。
    func fetchSportRecords(startTime: Int, endTime: Int) async throws -> [MiItem] {
        var items: [MiItem] = []
        var nextKey: String?
        var seen = Set<String>()
        var page = 0
        while true {
            page += 1
            guard page <= maxPages else { throw MiAPIError.paginationLimit }
            let body = Self.dataString(
                startTime: startTime, endTime: endTime, key: "sport", limit: 50, nextKey: nextKey
            )
            let result = try await signedRequest(path: sportRecordsPath, dataString: body)

            if let list = result["sport_records"] as? [[String: Any]] {
                items.append(contentsOf: list.map(Self.makeItem))
            }
            let hasMore = MiJSON.bool(result["has_more"]) ?? false
            let cursor = MiJSON.string(result["next_key"])
            if !hasMore || cursor == nil { break }
            if seen.contains(cursor!) { throw MiAPIError.cursorLoop }
            seen.insert(cursor!)
            nextKey = cursor
            // 分頁請求間隔，避免高頻請求觸發小米限流
            try? await Task.sleep(nanoseconds: pageDelayNs)
        }
        return items
    }

    // MARK: - 時間換算（中國區 +08:00）

    /// 某日曆日 00:00:00(+08:00) 的時間戳。
    static func dayStartEpoch(of day: Date) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.regionTimeZone
        let start = cal.startOfDay(for: day)
        return Int(start.timeIntervalSince1970)
    }

    /// 某日曆日 23:59:59(+08:00) 的時間戳。
    static func dayEndEpoch(of day: Date) -> Int {
        dayStartEpoch(of: day) + 86_399
    }

    // MARK: - 原始條目提取

    private static func makeItem(_ raw: [String: Any]) -> MiItem {
        var valueData: Data?
        if let string = raw["value"] as? String {
            valueData = Data(string.utf8)
        } else if let dict = raw["value"] as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: dict) {
            valueData = data
        } else if let arr = raw["value"] as? [Any],
                  let data = try? JSONSerialization.data(withJSONObject: arr) {
            valueData = data
        }
        return MiItem(
            time: MiJSON.int(raw["time"]),
            zoneOffset: MiJSON.int(raw["zone_offset"]),
            zoneName: MiJSON.string(raw["zone_name"]),
            sid: MiJSON.string(raw["sid"]),
            key: MiJSON.string(raw["key"]),
            category: MiJSON.string(raw["category"]),
            valueData: valueData
        )
    }
}
