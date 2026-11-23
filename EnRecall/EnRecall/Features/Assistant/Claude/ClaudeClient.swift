import Foundation

/// 一次 Messages API 的回覆
struct ClaudeResponse: Sendable {
    /// assistant 這一輪的 content，原樣保存（含 thinking 區塊和 signature），下一輪原封不動送回
    let content: [JSONValue]
    let stopReason: String?
    let usage: AssistantUsage?

    var toolUses: [(id: String, name: String, input: JSONValue)] {
        content.compactMap { block in
            guard block["type"]?.string == "tool_use", let id = block["id"]?.string,
                  let name = block["name"]?.string else { return nil }
            return (id, name, block["input"] ?? .object([:]))
        }
    }

    /// 給使用者看的文字（thinking 不算）
    var text: String {
        content.filter { $0["type"]?.string == "text" }
            .compactMap { $0["text"]?.string }
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// usage（這次對話累計）
struct AssistantUsage: Equatable, Sendable {
    /// 沒有命中快取的輸入
    var input = 0
    var cacheRead = 0
    var cacheWrite = 0
    /// 含思考
    var output = 0

    init() {}

    init?(_ json: JSONValue?) {
        guard let json else { return nil }
        input = json["input_tokens"]?.int ?? 0
        cacheRead = json["cache_read_input_tokens"]?.int ?? 0
        cacheWrite = json["cache_creation_input_tokens"]?.int ?? 0
        output = json["output_tokens"]?.int ?? 0
    }

    static func + (a: AssistantUsage, b: AssistantUsage) -> AssistantUsage {
        var sum = AssistantUsage()
        sum.input = a.input + b.input
        sum.cacheRead = a.cacheRead + b.cacheRead
        sum.cacheWrite = a.cacheWrite + b.cacheWrite
        sum.output = a.output + b.output
        return sum
    }
}

enum AssistantError: LocalizedError, Equatable {
    /// 後端還沒設定、或還沒輸入下載密碼
    case notConfigured
    /// 下載密碼不對
    case unauthorized
    /// 額度或帳單問題（兩把 key 都不能用）
    case quotaExhausted
    /// 太多請求、伺服器忙
    case busy
    case network
    case server(String)
    /// 模型拒絕回答
    case refusal
    /// 回覆太長被截斷
    case truncated

    var errorDescription: String? {
        switch self {
        case .notConfigured: "助理要先在設定 › 單字商店輸入下載密碼"
        case .unauthorized: "下載密碼不對，請到設定 › 單字商店重新輸入"
        case .quotaExhausted: "AI 額度已用完"
        case .busy: "AI 現在比較忙，等一下再試"
        case .network: "連不上網路，再試一次"
        case .server(let message): message
        case .refusal: "這個請求沒辦法處理，換個說法試試"
        case .truncated: "要做的事太多，回覆被截斷了。請把需求拆小再試"
        }
    }

    /// 可以按「重試」的錯誤
    var isRetryable: Bool {
        switch self {
        case .busy, .network, .server: true
        case .notConfigured, .unauthorized, .quotaExhausted, .refusal, .truncated: false
        }
    }
}

/// 經過 iOS 後端的 Edge Function `claude-proxy` 呼叫 Claude Messages API（API key 不在 App 裡）。
/// 驗證跟單字商店一樣：下載密碼＋這台手機的配對碼。代理只轉送白名單裡的模型和 beta
struct ClaudeClient: Sendable {
    /// 代理會接受的 beta：refusal 時自動換模型、history 被改時丟掉思考區塊而不是整個請求失敗
    static let betas = ["server-side-fallback-2026-07-01", "thinking-binding-controls-2026-08-01"]

    func send(_ request: JSONValue) async throws -> ClaudeResponse {
        let data = try await post(request, retryRegister: true)
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw AssistantError.server("回覆格式不對，再試一次") }
        let stopReason = json["stop_reason"]?.string
        if stopReason == "refusal" { throw AssistantError.refusal }
        let content = json["content"]?.array ?? []
        let response = ClaudeResponse(content: content, stopReason: stopReason, usage: AssistantUsage(json["usage"]))
        // 截斷的工具呼叫不能執行（參數可能不完整）
        if stopReason == "max_tokens", !response.toolUses.isEmpty { throw AssistantError.truncated }
        if content.isEmpty { throw AssistantError.server("沒有收到回覆，再試一次") }
        return response
    }

    private func post(_ request: JSONValue, retryRegister: Bool) async throws -> Data {
        guard let base = AppConfig.supabaseURL, StoreAccess.hasPassword, let code = PairingCodeStore.load() else {
            throw AssistantError.notConfigured
        }
        var urlRequest = URLRequest(url: base.appending(path: "functions/v1/claude-proxy"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = AssistantConfig.requestTimeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        urlRequest.setValue("Bearer \(AppConfig.supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(StoreAccess.password, forHTTPHeaderField: "x-store-password")
        urlRequest.setValue(code, forHTTPHeaderField: "x-device-code")
        let body: JSONValue = ["request": request, "betas": .array(Self.betas.map(JSONValue.string))]
        urlRequest.httpBody = body.jsonData
        AssistantLog.request(request)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: urlRequest)
        } catch {
            throw AssistantError.network
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        let code429 = json?["error"]?["code"]?.string
        switch status {
        case 200..<300:
            return data
        case 401, 403:
            // 配對碼可能還沒註冊（第一次打開就沒網路）：註冊後再試一次
            if retryRegister, (try? await SupabaseRPC.call("ios_register_device", code: code)) != nil {
                return try await post(request, retryRegister: false)
            }
            throw AssistantError.unauthorized
        case 402:
            throw AssistantError.quotaExhausted
        case 429 where code429 == "quota_exhausted":
            throw AssistantError.quotaExhausted
        case 429, 503, 529:
            throw AssistantError.busy
        default:
            let message = json?["error"]?["message"]?.string
            throw AssistantError.server(message.map { "AI 回傳錯誤：\($0)" } ?? "AI 暫時沒有回應（\(status)），再試一次")
        }
    }
}

/// 只在 Debug 印出送出的內容（驗證「辨識後不再送圖片」用），不印圖片本身
enum AssistantLog {
    static func request(_ request: JSONValue) {
        #if DEBUG
        let messages = request["messages"]?.array ?? []
        let images = messages.reduce(0) { count, message in
            count + (message["content"]?.array ?? []).filter { $0["type"]?.string == "image" }.count
        }
        print("[Assistant] messages=\(messages.count) images=\(images)")
        #endif
    }
}
