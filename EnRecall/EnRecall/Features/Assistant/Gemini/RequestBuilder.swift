import Foundation

/// 把對話紀錄組成 generateContent 的 body。規則（規劃書第 4 節）：
/// - 系統提示、工具清單固定放最前面
/// - 使用者的圖片只在還沒辨識時送；辨識過就換成「[先前圖片內容：…]」文字，舊圖片絕不重送
/// - 模型回傳的 parts 原樣送回（含 thoughtSignature）
enum RequestBuilder {
    static func contents(history: [HistoryItem], messages: [ChatMessage]) -> [JSONValue] {
        let byID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return history.compactMap { item -> JSONValue? in
            switch item {
            case .user(let id):
                guard let message = byID[id] else { return nil }
                let parts = userParts(message)
                return parts.isEmpty ? nil : ["role": "user", "parts": .array(parts)]
            case .model(let parts):
                return ["role": "model", "parts": .array(parts)]
            case .toolResults(let parts):
                return ["role": "user", "parts": .array(parts)]
            }
        }
    }

    static func userParts(_ message: ChatMessage) -> [JSONValue] {
        var parts: [JSONValue] = []
        if !message.imageData.isEmpty {
            for data in message.imageData {
                parts.append(["inlineData": ["mimeType": "image/jpeg", "data": .string(data.base64EncodedString())]])
            }
        } else if let recognized = message.recognizedText {
            parts.append(["text": .string("[先前圖片內容：\n\(recognized)\n]")])
        } else if message.hasImages {
            parts.append(["text": "[先前的圖片沒有辨識內容]"])
        }
        if let text = message.text, !text.isEmpty {
            parts.append(["text": .string(text)])
        }
        return parts
    }

    static func hasImages(_ contents: [JSONValue]) -> Bool {
        contents.contains { content in (content["parts"]?.array ?? []).contains { $0["inlineData"] != nil } }
    }

    static func request(contents: [JSONValue]) -> JSONValue {
        let images = hasImages(contents)
        var config: [String: JSONValue] = [
            "thinkingConfig": ["thinkingLevel": .string(images ? AssistantConfig.thinkingLevelWithImage : AssistantConfig.thinkingLevel)],
        ]
        if images { config["mediaResolution"] = .string(AssistantConfig.imageResolution) }
        return [
            "systemInstruction": ["parts": [["text": .string(SystemPrompt.text)]]],
            "tools": [["functionDeclarations": .array(ToolRegistry.declarations)]],
            "toolConfig": ["functionCallingConfig": ["mode": "AUTO"]],
            "contents": .array(contents),
            "generationConfig": .object(config),
        ]
    }

    /// 工具結果
    static func functionResponse(name: String, id: String?, result: JSONValue) -> JSONValue {
        var response: [String: JSONValue] = ["name": .string(name), "response": result]
        if let id { response["id"] = .string(id) }
        return ["functionResponse": .object(response)]
    }
}
