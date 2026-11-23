import Foundation

/// 把對話紀錄組成 Messages API 的 body。
///
/// Claude 的思考區塊會記住「產生它時前面的對話」，之後送回時前面不能被改（preserved thinking）。所以：
/// - 系統提示、工具清單固定不變（也讓提示快取命中）
/// - 對話只往後加，不改前面；模型回傳的 content 原樣送回（含 thinking 和 signature）
/// - 圖片在同一個請求的工具迴圈裡照送；迴圈結束後才換成「[先前圖片內容：…]」文字，
///   同時把之前所有的思考區塊拿掉（全部拿掉是允許的），下一句起就不再送圖片
enum RequestBuilder {
    static func messages(history: [HistoryItem], messages: [ChatMessage]) -> [JSONValue] {
        let byID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return history.compactMap { item -> JSONValue? in
            switch item {
            case .user(let id):
                guard let message = byID[id] else { return nil }
                let content = userContent(message)
                return content.isEmpty ? nil : ["role": "user", "content": .array(content)]
            case .model(let content):
                return ["role": "assistant", "content": .array(content)]
            case .toolResults(let content):
                return ["role": "user", "content": .array(content)]
            }
        }
    }

    static func userContent(_ message: ChatMessage) -> [JSONValue] {
        var content: [JSONValue] = []
        if !message.imageData.isEmpty {
            for data in message.imageData {
                content.append([
                    "type": "image",
                    "source": ["type": "base64", "media_type": "image/jpeg", "data": .string(data.base64EncodedString())],
                ])
            }
        } else if let recognized = message.recognizedText {
            content.append(["type": "text", "text": .string("[先前圖片內容：\n\(recognized)\n]")])
        } else if message.hasImages {
            content.append(["type": "text", "text": "[先前的圖片沒有辨識內容]"])
        }
        if let text = message.text, !text.isEmpty {
            content.append(["type": "text", "text": .string(text)])
        }
        return content
    }

    static func imageCount(_ messages: [JSONValue]) -> Int {
        messages.reduce(0) { count, message in
            count + (message["content"]?.array ?? []).filter { $0["type"]?.string == "image" }.count
        }
    }

    /// 工具清單：固定不變
    static let tools: [JSONValue] = ToolRegistry.declarations

    static func request(messages: [JSONValue], effort: String) -> JSONValue {
        [
            "model": .string(AssistantConfig.model),
            "max_tokens": .number(Double(AssistantConfig.maxTokens)),
            "system": [["type": "text", "text": .string(SystemPrompt.text)]],
            "tools": .array(tools),
            "messages": .array(messages),
            // 思考一直開著（Opus 5.5 不能關），深度用 effort 控制。
            // 萬一前面的對話被改到，丟掉對不上的思考區塊繼續跑，不要整個請求失敗
            "thinking": ["type": "adaptive", "block_binding": ["prefix_mismatch_behavior": "drop_block"]],
            "output_config": ["effort": .string(effort)],
            // 自動快取到最後一個區塊：系統提示、工具清單、之前的對話下一輪都從快取讀
            "cache_control": ["type": "ephemeral"],
            // 被安全分類器拒絕時，由伺服器自動換一個模型重跑
            "fallbacks": "default",
        ]
    }

    /// 工具結果：同一輪的全部放在同一則 user 訊息
    static func toolResult(id: String, result: JSONValue) -> JSONValue {
        let text = String(decoding: result.jsonData, as: UTF8.self)
        var block: [String: JSONValue] = ["type": "tool_result", "tool_use_id": .string(id), "content": .string(text)]
        if result.isToolError { block["is_error"] = true }
        return .object(block)
    }

    /// 把模型 content 裡的思考區塊拿掉（換掉圖片、修改辨識結果之後用：之前的思考全部丟掉）
    static func strippingThinking(_ content: [JSONValue]) -> [JSONValue] {
        content.filter { block in
            let type = block["type"]?.string
            return type != "thinking" && type != "redacted_thinking"
        }
    }
}
