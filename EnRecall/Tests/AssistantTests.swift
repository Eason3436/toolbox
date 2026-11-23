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
        #expect(addWords?["parametersJsonSchema"]?["required"]?.strings == ["deck", "words"])
    }

    @Test func imageIsSentOnlyUntilRecognized() {
        var message = ChatMessage(role: .user, text: "加單字", imageData: [Data([1, 2, 3])], thumbnails: [Data([1])])
        var contents = RequestBuilder.contents(history: [.user(message.id)], messages: [message])
        #expect(RequestBuilder.hasImages(contents))
        #expect(RequestBuilder.request(contents: contents)["generationConfig"]?["mediaResolution"]?.string == "MEDIA_RESOLUTION_HIGH")

        // report_image_content 之後：圖片換成文字
        message.imageData = []
        message.recognizedText = "absolute\nrecord"
        contents = RequestBuilder.contents(history: [.user(message.id)], messages: [message])
        #expect(!RequestBuilder.hasImages(contents))
        let texts = contents.first?["parts"]?.array?.compactMap { $0["text"]?.string } ?? []
        #expect(texts.first?.hasPrefix("[先前圖片內容：") == true)
        #expect(texts.last == "加單字")
        #expect(RequestBuilder.request(contents: contents)["generationConfig"]?["mediaResolution"] == nil)
    }

    @Test func modelPartsAreSentBackUnchanged() throws {
        let raw = #"[{"functionCall":{"name":"lookup_words","args":{"words":["run"]}},"thoughtSignature":"abc=="},{"text":"好"}]"#
        let parts = try JSONDecoder().decode([JSONValue].self, from: Data(raw.utf8))
        let contents = RequestBuilder.contents(history: [.model(parts)], messages: [])
        #expect(contents.first?["role"]?.string == "model")
        #expect(contents.first?["parts"]?.array == parts)
        #expect(contents.first?["parts"]?.array?.first?["thoughtSignature"]?.string == "abc==")
    }

    @Test func systemPromptAndToolsComeFirstAndStayFixed() {
        let a = RequestBuilder.request(contents: [["role": "user", "parts": [["text": "嗨"]]]])
        let b = RequestBuilder.request(contents: [["role": "user", "parts": [["text": "再見"]]]])
        #expect(a["systemInstruction"] == b["systemInstruction"])
        #expect(a["tools"] == b["tools"])
    }

    @Test func functionResponseShape() {
        let part = RequestBuilder.functionResponse(name: "overview", id: "call-1", result: ["ok": true])
        #expect(part["functionResponse"]?["name"]?.string == "overview")
        #expect(part["functionResponse"]?["id"]?.string == "call-1")
        #expect(part["functionResponse"]?["response"]?["ok"]?.bool == true)
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

    @Test func recognitionReplacesImage() {
        let message = ChatMessage(role: .user, text: "加單字", imageData: [Data([9])], thumbnails: [Data([9])])
        let session = ChatSession(previewMessages: [message])
        let id = session.recordRecognition(transcript: "absolute", imageType: "handwritten", uncertain: [])
        #expect(id == message.id)
        #expect(session.messages.first?.imageData.isEmpty == true)
        #expect(session.messages.first?.recognizedText == "absolute")
        // 沒有新圖片時不能再記
        #expect(session.recordRecognition(transcript: "x", imageType: nil, uncertain: []) == nil)
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
