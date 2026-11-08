import Foundation
import Security

// MARK: - 目前用哪個 AI

/// 摘要、追問、校正用哪個模型。任意執行緒都能讀（設定變更時由 AppSettings 寫入）。
enum AIConfig {
    enum Provider: String, CaseIterable, Identifiable, Sendable {
        case apple
        case gemini
        case muse
        var id: String { rawValue }
        var title: String {
            switch self {
            case .apple: "Apple Intelligence（裝置上）"
            case .gemini: "Google Gemini（雲端）"
            case .muse: "Muse（同步後由 Muse 整理）"
            }
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _provider: Provider = .apple
    nonisolated(unsafe) private static var _model = GeminiClient.defaultModel
    nonisolated(unsafe) private static var _apiKey = ""

    static func update(provider: Provider, model: String, apiKey: String) {
        lock.lock(); defer { lock.unlock() }
        _provider = provider
        _model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        _apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var provider: Provider { lock.lock(); defer { lock.unlock() }; return _provider }
    static var model: String { lock.lock(); defer { lock.unlock() }; return _model.isEmpty ? GeminiClient.defaultModel : _model }
    static var apiKey: String { lock.lock(); defer { lock.unlock() }; return _apiKey }

    /// 選了 Gemini 而且有填 API Key
    static var usesGemini: Bool { provider == .gemini && !apiKey.isEmpty }

    /// 選了 Muse：筆記、摘要、Recap 都交給 Muse，App 裡的 AI 只做小事（判斷科目、標題、檢查辨識品質）
    static var usesMuse: Bool { provider == .muse }

    /// 顯示用名稱（整理摘要與筆記的是誰）
    static var engineName: String { usesGemini ? "Gemini" : (usesMuse ? "Muse" : "Apple Intelligence") }
}

// MARK: - Gemini API

enum GeminiError: LocalizedError {
    case badKey
    case quota
    case blocked(String)
    case server(Int, String)
    case busy
    case empty

    var errorDescription: String? {
        switch self {
        case .badKey: "Gemini API Key 無效，請到設定重新貼上。"
        case .quota: "Gemini 用量達到上限（免費額度每分鐘／每天有限制），稍後再試。"
        case .blocked(let reason): "Gemini 拒絕回答（\(reason)）。"
        case .server(let code, let message): "Gemini 錯誤 \(code)：\(message)"
        case .busy: "Gemini 伺服器現在太忙（503），備用模型也忙，稍後會自動再試。"
        case .empty: "Gemini 沒有回傳內容。"
        }
    }
}

struct GeminiModelInfo: Identifiable, Hashable, Sendable {
    var id: String
    var displayName: String
    var inputLimit: Int
}

enum GeminiClient {
    /// 「-latest」別名會自動跟著 Google 換成最新版，不會因為舊型號下架而失效。
    static let defaultModel = "gemini-flash-latest"

    struct Recommendation: Identifiable, Hashable {
        var id: String
        var title: String
        var detail: String
    }

    static let recommended: [Recommendation] = [
        Recommendation(id: "gemini-flash-latest", title: "Gemini Flash（推薦）", detail: "速度和品質平衡，摘要、追問都夠用，免費額度也比較多。"),
        Recommendation(id: "gemini-pro-latest", title: "Gemini Pro", detail: "最聰明，課堂筆記和複雜追問最好；比較慢，免費額度很少。"),
        Recommendation(id: "gemini-flash-lite-latest", title: "Gemini Flash-Lite", detail: "最快最省，適合大量逐字稿校正和每段摘要。"),
    ]

    private static let base = URL(string: "https://generativelanguage.googleapis.com/v1beta/")!

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// 產生純文字回應。429／5xx 會稍等重試；選的模型太忙或額度用完時，自動改用其他推薦模型。
    static func generate(system: String, prompt: String, model: String = AIConfig.model, apiKey: String = AIConfig.apiKey, temperature: Double = 0.3, googleSearch: Bool = false) async throws -> String {
        let chosen = model.hasPrefix("models/") ? String(model.dropFirst(7)) : model
        let backups = recommended.map(\.id).filter { $0 != chosen }
        var lastError: Error = GeminiError.busy
        for (index, name) in ([chosen] + backups).enumerated() {
            do {
                return try await generateOnce(system: system, prompt: prompt, model: name, apiKey: apiKey, temperature: temperature, googleSearch: googleSearch, retries: index == 0 ? 2 : 1)
            } catch GeminiError.server(let code, _) where code >= 500 {
                lastError = GeminiError.busy
            } catch GeminiError.quota {
                lastError = GeminiError.quota
            }
        }
        throw lastError
    }

    private static func generateOnce(system: String, prompt: String, model: String, apiKey: String, temperature: Double, googleSearch: Bool, retries: Int) async throws -> String {
        let name = model.hasPrefix("models/") ? String(model.dropFirst(7)) : model
        var request = URLRequest(url: base.appending(path: "models/\(name):generateContent"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let categories = ["HARM_CATEGORY_HARASSMENT", "HARM_CATEGORY_HATE_SPEECH", "HARM_CATEGORY_SEXUALLY_EXPLICIT", "HARM_CATEGORY_DANGEROUS_CONTENT"]
        var body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            "generationConfig": ["temperature": temperature],
            // 這是使用者自己的私人錄音，日常對話很容易被誤判，所以放寬
            "safetySettings": categories.map { ["category": $0, "threshold": "BLOCK_NONE"] },
        ]
        // 讓模型可以上網查證（事實查核用）
        if googleSearch { body["tools"] = [["google_search": [String: Any]()]] }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var attempt = 0
        while true {
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 { return try parse(data) }
            let message = errorMessage(data)
            if (status == 429 || status >= 500), attempt < retries {
                attempt += 1
                try await Task.sleep(for: .seconds(attempt == 1 ? 4 : 15))
                continue
            }
            switch status {
            case 400 where message.localizedCaseInsensitiveContains("api key"), 401, 403: throw GeminiError.badKey
            case 429: throw GeminiError.quota
            default: throw GeminiError.server(status, message)
            }
        }
    }

    private static func parse(_ data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GeminiError.empty }
        if let feedback = json["promptFeedback"] as? [String: Any], let reason = feedback["blockReason"] as? String {
            throw GeminiError.blocked(reason)
        }
        guard let candidate = (json["candidates"] as? [[String: Any]])?.first else { throw GeminiError.empty }
        let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        // 思考過程（thought）不要
        let text = parts.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
        if text.isEmpty {
            let reason = candidate["finishReason"] as? String ?? "未知"
            throw reason == "STOP" ? GeminiError.empty : GeminiError.blocked(reason)
        }
        return text
    }

    private static func errorMessage(_ data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        return String(data: data.prefix(200), encoding: .utf8) ?? ""
    }

    /// 向 Google 取得這把 Key 能用的模型（只列能產生文字的 Gemini）。
    static func listModels(apiKey: String) async throws -> [GeminiModelInfo] {
        var result: [GeminiModelInfo] = []
        var pageToken: String?
        repeat {
            var components = URLComponents(url: base.appending(path: "models"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "pageSize", value: "200")] + (pageToken.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
            var request = URLRequest(url: components.url!)
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                if status == 400 || status == 401 || status == 403 { throw GeminiError.badKey }
                throw GeminiError.server(status, errorMessage(data))
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            for model in json["models"] as? [[String: Any]] ?? [] {
                guard let name = model["name"] as? String else { continue }
                let id = name.hasPrefix("models/") ? String(name.dropFirst(7)) : name
                let methods = model["supportedGenerationMethods"] as? [String] ?? []
                let skip = ["tts", "image", "embedding", "live", "audio", "aqa", "robotics", "computer-use", "veo", "imagen"]
                guard id.hasPrefix("gemini"), methods.contains("generateContent"), !skip.contains(where: { id.contains($0) }) else { continue }
                result.append(GeminiModelInfo(id: id, displayName: model["displayName"] as? String ?? id, inputLimit: model["inputTokenLimit"] as? Int ?? 0))
            }
            pageToken = json["nextPageToken"] as? String
        } while pageToken?.isEmpty == false
        return result.sorted { $0.id > $1.id }
    }
}

// MARK: - Keychain

enum Keychain {
    private static let service = "com.eason3436.recap"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        // 背景整理（螢幕鎖定、充電中）也要讀得到
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}
