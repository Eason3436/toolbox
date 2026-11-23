import Foundation

/// 依工具名稱分派。每個工具回傳 JSON（成功：資料；失敗：{"error": "原因"}）
@MainActor
enum ToolExecutor {
    static func run(name: String, args raw: JSONValue, context ctx: ToolContext) async -> JSONValue {
        let args = ToolArgs(raw)
        switch name {
        case "report_image_content":
            return reportImage(args, ctx)
        case "lookup_words":
            return await WordTools.lookup(args, ctx)
        case "add_words":
            return await WordTools.add(args, ctx)
        case "get_words":
            return await WordTools.get(args, ctx)
        case "list_words":
            return LearningTools.listWords(args, ctx)
        case "lookup_patterns":
            return PatternTools.lookup(args, ctx)
        case "add_patterns":
            return await PatternTools.add(args, ctx)
        case "list_patterns":
            return PatternTools.list(args, ctx)
        case "overview":
            return LearningTools.overview(args, ctx)
        case "analyze_learning":
            return LearningTools.analyze(args, ctx)
        case "read_docs":
            guard let docName = args.string("name"), let text = AssistantDocs.text(docName) else {
                return ["available": .array(AssistantDocs.available.map(JSONValue.string))]
            }
            return ["name": .string(docName), "content": .string(text)]
        case "make_pdf":
            return await PDFTools.make(args, ctx)
        default:
            return .error("沒有「\(name)」這個工具。可以用的：\(ToolRegistry.names.sorted().joined(separator: "、"))")
        }
    }

    private static func reportImage(_ args: ToolArgs, _ ctx: ToolContext) -> JSONValue {
        guard let transcript = args.string("transcript") else { return .error("transcript 不能是空的") }
        let uncertain = args.strings("uncertain")
        guard let messageID = ctx.host.recordRecognition(transcript: transcript, imageType: args.string("image_type"), uncertain: uncertain) else {
            return .error("這次沒有新的圖片，不用呼叫 report_image_content")
        }
        ctx.host.addCard(ToolCard(kind: .recognition(RecognitionCard(
            messageID: messageID, transcript: transcript, imageType: args.string("image_type"), uncertain: uncertain
        ))))
        return ["ok": true, "message": "已記下圖片內容，之後的步驟用這份文字"]
    }
}
