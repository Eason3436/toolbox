import Testing
import Foundation
@testable import EnRecall

@MainActor
struct AssistantRequestTests {
    @Test func toolDeclarationsDecode() {
        #expect(ToolRegistry.declarations.count == 12)
        #expect(ToolRegistry.names.contains("report_image_content"))
        #expect(ToolRegistry.names.contains("make_pdf"))
        #expect(!ToolRegistry.names.contains("check_inbox"))
        let addWords = ToolRegistry.declarations.first { $0["name"]?.string == "add_words" }
        #expect(addWords?["input_schema"]?["required"]?.strings == ["deck", "words"])
    }

    @Test func requestShape() {
        let request = RequestBuilder.request(messages: [["role": "user", "content": [["type": "text", "text": "嗨"]]]], effort: "medium")
        #expect(request["model"]?.string == "claude-opus-5-5")
        #expect(request["output_config"]?["effort"]?.string == "medium")
        #expect(request["thinking"]?["type"]?.string == "adaptive")
        #expect(request["cache_control"]?["type"]?.string == "ephemeral")
        #expect(request["tools"]?.array?.count == 12)
    }

    @Test func systemPromptAndToolsStayFixed() {
        let a = RequestBuilder.request(messages: [["role": "user", "content": "嗨"]], effort: "medium")
        let b = RequestBuilder.request(messages: [["role": "user", "content": "再見"]], effort: "high")
        #expect(a["system"] == b["system"])
        #expect(a["tools"] == b["tools"])
    }

    @Test func modelContentIsSentBackUnchanged() throws {
        let raw = #"[{"type":"thinking","thinking":"","signature":"abc=="},{"type":"tool_use","id":"toolu_1","name":"lookup_words","input":{"words":["run"]}}]"#
        let content = try JSONDecoder().decode([JSONValue].self, from: Data(raw.utf8))
        let messages = RequestBuilder.messages(history: [.model(content)], messages: [])
        #expect(messages.first?["role"]?.string == "assistant")
        #expect(messages.first?["content"]?.array == content)
    }

    @Test func toolResultShape() {
        let ok = RequestBuilder.toolResult(id: "toolu_1", result: ["ok": true])
        #expect(ok["type"]?.string == "tool_result")
        #expect(ok["tool_use_id"]?.string == "toolu_1")
        #expect(ok["is_error"] == nil)
        let failed = RequestBuilder.toolResult(id: "toolu_2", result: .error("找不到"))
        #expect(failed["is_error"]?.bool == true)
    }
}

@MainActor
struct AssistantSessionTests {
    @Test func resetsAfterThirtyMinutesAway() {
        let session = ChatSession(previewMessages: [ChatMessage(role: .user, text: "hi")])
        let start = Date()
        session.didEnterBackground(at: start)
        session.willEnterForeground(at: start.addingTimeInterval(29 * 60))
        #expect(!session.isEmpty)
        session.didEnterBackground(at: start)
        session.willEnterForeground(at: start.addingTimeInterval(31 * 60))
        #expect(session.isEmpty)
    }

    /// 圖片在同一個請求裡照送（前面的對話不能改）；請求結束才換成文字，之前的思考區塊一起拿掉
    @Test func imageIsRetiredAfterTheRequest() throws {
        let message = ChatMessage(role: .user, text: "加單字", imageData: [Data([9])], thumbnails: [Data([9])])
        let session = ChatSession(previewMessages: [message])
        let modelTurn = try JSONDecoder().decode([JSONValue].self, from: Data(
            #"[{"type":"thinking","thinking":"","signature":"s"},{"type":"tool_use","id":"t1","name":"report_image_content","input":{"transcript":"absolute"}}]"#.utf8))
        session.loadHistory([.user(message.id), .model(modelTurn)])

        let id = session.recordRecognition(transcript: "absolute", imageType: "handwritten", uncertain: [])
        #expect(id == message.id)
        #expect(RequestBuilder.imageCount(session.currentMessages) == 1)
        // 同一張圖不能再記一次
        #expect(session.recordRecognition(transcript: "x", imageType: nil, uncertain: []) == nil)

        session.retireRecognizedImages()
        let sent = session.currentMessages
        #expect(RequestBuilder.imageCount(sent) == 0)
        let firstText = sent.first?["content"]?.array?.first?["text"]?.string
        #expect(firstText?.hasPrefix("[先前圖片內容：") == true)
        let assistant = sent.last?["content"]?.array ?? []
        #expect(!assistant.contains { $0["type"]?.string == "thinking" })
        #expect(assistant.contains { $0["type"]?.string == "tool_use" })
    }

    @Test func historyWithoutImagesKeepsThinking() throws {
        let message = ChatMessage(role: .user, text: "我最近背得怎樣？")
        let session = ChatSession(previewMessages: [message])
        let modelTurn = try JSONDecoder().decode([JSONValue].self, from: Data(
            #"[{"type":"thinking","thinking":"","signature":"s"},{"type":"text","text":"好"}]"#.utf8))
        session.loadHistory([.user(message.id), .model(modelTurn)])
        session.retireRecognizedImages()
        #expect(session.currentMessages.last?["content"]?.array == modelTurn)
    }
}

@MainActor
struct AssistantWordToolTests {
    private func index() -> LibraryIndex {
        let index = LibraryIndex()
        index.load(entries: [
            .init(id: "w:ability", word: "ability", pos: "n.", zh: "能力", example: "Amy has the ability.", exampleZh: "Amy 有能力。"),
            .init(id: "w:record", word: "record", pos: "n. / v.", zh: "n. 紀錄\nv. 記錄", example: nil, exampleZh: nil),
            .init(id: "p:rely on sb/sth", word: "rely on sb/sth", pos: "動詞片語", zh: "依賴", example: nil, exampleZh: nil),
            .init(id: "p:look out (for sb/sth)", word: "look out (for sb/sth)", pos: nil, zh: "小心", example: nil, exampleZh: nil),
        ])
        return index
    }

    @Test func phraseCore() {
        #expect(PhraseKey.core("rely on sb/sth") == "rely on")
        #expect(PhraseKey.core("look out (for sb/sth)") == "look out")
        #expect(PhraseKey.core("so … that …") == "so that")
    }

    @Test func matchOrder() {
        let index = index()
        #expect(index.match(" Ability ").map(\.id) == ["w:ability"])
        #expect(index.match("rely on").map(\.id) == ["p:rely on sb/sth"])
        #expect(index.match("look out").map(\.id) == ["p:look out (for sb/sth)"])
        #expect(index.match("photosynthesis").isEmpty)
    }

    @Test func resolveUsesLibraryAndRejectsMissingChinese() {
        let words: [JSONValue] = [
            ["word": "ability", "zh": "亂寫", "example": "My own sentence."],
            ["word": "Ability"],
            ["word": "Ran"],
            ["word": "photosynthesis", "pos": "n.", "zh": "光合作用"],
            ["word": "  "],
        ]
        let result = WordTools.resolve(words, index: index())
        #expect(result.items.count == 2)
        #expect(result.items[0].libraryWordID == "w:ability")
        #expect(result.items[0].zh == "能力")
        #expect(result.items[0].example == "Amy has the ability.")
        #expect(result.items[1].libraryWordID == nil)
        #expect(result.items[1].zh == "光合作用")
        #expect(result.rejected.map(\.reason) == ["缺少中文解釋", "單字格式不正確"])
    }

    @Test func memoryDots() {
        #expect(Memory.dots(nil) == "新字")
        #expect(Memory.dots(0.01) == "●○○○○")
        #expect(Memory.dots(0.42) == "●●●○○")
        #expect(Memory.dots(1) == "●●●●●")
    }
}

@MainActor
struct AssistantPatternToolTests {
    @Test func anchorKeyUsesBaseForms() {
        #expect(PatternTools.id(["It was not until", "that"]) == "pt:it is not until|that")
        #expect(PatternTools.id(["it IS not  until", "that"]) == "pt:it is not until|that")
        #expect(PatternTools.normalizeAnchor("he has had") == "he have have")
    }

    @Test func validatesDetail() {
        let good: JSONValue = [
            "pattern": "It is not until + 時間 + that + S + V", "zh": "直到…才…",
            "anchors": ["it is not until", "that"],
            "slots": [["slot": "時間", "accepts": "時間名詞", "examples": ["midnight", "1990"]]],
            "examples": [["en": "It was not until midnight that he slept.", "zh": "直到半夜他才睡。"],
                         ["en": "It is not until we lose health that we value it."]],
            "extra": "會被拿掉",
        ]
        guard case .success(let detail) = PatternTools.validate(good) else {
            Issue.record("應該通過")
            return
        }
        #expect(detail.anchors == ["it is not until", "that"])

        var missingSlots = good.object ?? [:]
        missingSlots["slots"] = .array([])
        if case .success = PatternTools.validate(.object(missingSlots)) { Issue.record("沒有 slots 不能通過") }

        var badAnchor = good.object ?? [:]
        badAnchor["anchors"] = ["直到"]
        if case .success = PatternTools.validate(.object(badAnchor)) { Issue.record("anchor 只能有英文") }
    }
}
