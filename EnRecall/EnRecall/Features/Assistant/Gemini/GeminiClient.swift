import Foundation

/// 一次 generateContent 的結果
struct GeminiResponse: Sendable {
    /// 模型這一輪回傳的 parts，原樣保存（含 thoughtSignature），下一輪原封不動送回
    let parts: [JSONValue]
    let finishReason: String?
    let usage: GeminiUsage?

    var functionCalls: [(name: String, args: JSONValue, id: String?)] {
        parts.compactMap { part in
            guard let call = part["functionCall"], let name = call["name"]?.string else { return nil }
            return (name, call["args"] ?? .object([:]), call["id"]?.string)
        }
    }

    /// 給使用者看的文字（思考摘要不算）
    var text: String {
        parts.filter { $0["thought"]?.bool != true }
            .compactMap { $0["text"]?.string }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// usageMetadata
struct GeminiUsage: Equatable, Sendable {
    var prompt = 0
    var cached = 0
    var output = 0
    var thoughts = 0
    var total = 0

    init() {}

    init?(_ json: JSONValue?) {
        guard let json else { return nil }
        prompt = json["promptTokenCount"]?.int ?? 0
        cached = json["cachedContentTokenCount"]?.int ?? 0
        output = json["candidatesTokenCount"]?.int ?? 0
        thoughts = json["thoughtsTokenCount"]?.int ?? 0
        total = json["totalTokenCount"]?.int ?? (prompt + output + thoughts)
    }

    static func + (a: GeminiUsage, b: GeminiUsage) -> GeminiUsage {
        var sum = GeminiUsage()
        sum.prompt = a.prompt + b.prompt
        sum.cached = a.cached + b.cached
        sum.output = a.output + b.output
        sum.thoughts = a.thoughts + b.thoughts
        sum.total = a.total + b.total
        return sum
    }
}

enum GeminiError: LocalizedError, Equatable {
    /// 後端還沒設定、或還沒輸入下載密碼
    case notConfigured
    /// 下載密碼不對
    case unauthorized
    /// 兩把 key 都額度不足
    case quotaExhausted
    case network
    case server(String)
    /// 模型沒回東西（被擋掉等）
    case empty(String?)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "助理要先在設定 › 單字商店輸入下載密碼"
        case .unauthorized: "下載密碼不對，請到設定 › 單字商店重新輸入"
        case .quotaExhausted: "本月 AI 額度已用完"
        case .network: "連不上網路，再試一次"
        case .server(let message): message
        case .empty(let reason):
            reason == "SAFETY" || reason == "PROHIBITED_CONTENT" ? "這個請求被擋下來了，換個說法試試" : "沒有收到回覆，再試一次"
        }
    }

    /// 可以按「重試」的錯誤
    var isRetryable: Bool {
        switch self {
        case .network, .server, .empty: true
        case .notConfigured, .unauthorized, .quotaExhausted: false
        }
    }
}

/// 經過 iOS 後端的 Edge Function `gemini-proxy` 呼叫 Gemini（API key 不在 App 裡）。
/// 驗證跟單字商店一樣：下載密碼＋這台手機的配對碼
struct GeminiClient: Sendable {
    var model: String

    func generate(_ request: JSONValue) async throws -> GeminiResponse {
        let data = try await send(request, retryRegister: true)
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw GeminiError.empty(nil) }
        let candidate = json["candidates"]?.array?.first
        let parts = candidate?["content"]?["parts"]?.array ?? []
        let finish = candidate?["finishReason"]?.string
        if parts.isEmpty {
            throw GeminiError.empty(finish ?? json["promptFeedback"]?["blockReason"]?.string)
        }
        return GeminiResponse(parts: parts, finishReason: finish, usage: GeminiUsage(json["usageMetadata"]))
    }

    private func send(_ request: JSONValue, retryRegister: Bool) async throws -> Data {
        guard let base = AppConfig.supabaseURL, StoreAccess.hasPassword, let code = PairingCodeStore.load() else {
            throw GeminiError.notConfigured
        }
        var urlRequest = URLRequest(url: base.appending(path: "functions/v1/gemini-proxy"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = AssistantConfig.requestTimeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        urlRequest.setValue("Bearer \(AppConfig.supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(StoreAccess.password, forHTTPHeaderField: "x-store-password")
        urlRequest.setValue(code, forHTTPHeaderField: "x-device-code")
        let body: JSONValue = ["model": .string(model), "request": request]
        urlRequest.httpBody = body.jsonData
        AssistantLog.request(model: model, request: request)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: urlRequest)
        } catch {
            throw GeminiError.network
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300:
            return data
        case 401, 403:
            // 配對碼可能還沒註冊（第一次打開就沒網路）：註冊後再試一次
            if retryRegister, (try? await SupabaseRPC.call("ios_register_device", code: code)) != nil {
                return try await send(request, retryRegister: false)
            }
            throw GeminiError.unauthorized
        case 429:
            throw GeminiError.quotaExhausted
        default:
            let json = try? JSONDecoder().decode(JSONValue.self, from: data)
            let message = json?["error"]?["message"]?.string
            throw GeminiError.server(message.map { "AI 回傳錯誤：\($0)" } ?? "AI 暫時沒有回應（\(status)），再試一次")
        }
    }
}

/// 只在 Debug 印出送出的內容（驗證「第二輪之後不含圖片」用），不印圖片本身
enum AssistantLog {
    static func request(model: String, request: JSONValue) {
        #if DEBUG
        let contents = request["contents"]?.array ?? []
        let images = contents.reduce(0) { count, content in
            count + (content["parts"]?.array ?? []).filter { $0["inlineData"] != nil }.count
        }
        print("[Assistant] \(model) contents=\(contents.count) images=\(images)")
        #endif
    }
}
