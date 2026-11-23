import Foundation
import Observation
import SwiftData

/// 助理的對話：訊息、送給模型的紀錄、工具呼叫迴圈、30 分鐘重置。
/// 跟著 App 活著（EnRecallApp 放進 environment），離開聊天頁再回來對話還在
@MainActor
@Observable
final class ChatSession: ToolHost {
    private(set) var messages: [ChatMessage] = []
    /// 執行中：顯示目前的步驟（「查詢單字庫…」）；nil 是閒著
    private(set) var progress: String?
    /// 這次對話累計的用量
    private(set) var usage = GeminiUsage()
    var mode: AssistantMode = .normal

    var isBusy: Bool { progress != nil }

    @ObservationIgnored private var history: [HistoryItem] = []
    /// 原圖（壓縮過）只留在記憶體：精準重新辨識用，不會再送出
    @ObservationIgnored private var originalImages: [UUID: [Data]] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var pending: [UUID: CheckedContinuation<ConfirmDecision, Never>] = [:]
    @ObservationIgnored private var backgroundedAt: Date?
    /// 目前正在寫的那則模型回覆
    @ObservationIgnored private var replyID: UUID?
    /// 這一次執行的代號：重置後舊的迴圈不能再動畫面
    @ObservationIgnored private var runID: UUID?
    @ObservationIgnored var modelContext: ModelContext?

    init() {}

    /// 預覽用
    init(previewMessages: [ChatMessage]) {
        messages = previewMessages
    }

    // MARK: 送出

    func send(text: String, images: [Data] = [], precise: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isBusy, !trimmed.isEmpty || !images.isEmpty else { return }
        let thumbnails = images.compactMap { ImageCompressor.thumbnail($0) }
        let message = ChatMessage(role: .user, text: trimmed.isEmpty ? nil : trimmed, imageData: images, thumbnails: thumbnails)
        if !images.isEmpty { originalImages[message.id] = images }
        messages.append(message)
        history.append(.user(message.id))
        startReply(precise: precise || mode == .precise)
    }

    /// 失敗的那則按「重試」：從目前的紀錄接著跑
    func retry(_ messageID: UUID) {
        guard !isBusy, let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        let precise = messages[index].usedPreciseModel
        if messages[index].cards.isEmpty && (messages[index].text ?? "").isEmpty {
            messages.remove(at: index)
        } else {
            messages[index].error = nil
            messages[index].canRetry = false
        }
        startReply(precise: precise)
    }

    /// 辨識結果卡的「精準重新辨識」：同一張圖改用精準模型再辨識一次
    func rerecognize(_ messageID: UUID) {
        guard !isBusy, let images = originalImages[messageID] else { return }
        send(text: "請用精準模式重新辨識這張圖片，再照我剛剛的需求繼續。", images: images, precise: true)
    }

    /// 辨識結果卡的「修改」：之後送出的就是改過的文字
    func editRecognition(cardID: UUID, transcript: String) {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        for m in messages.indices {
            guard let c = messages[m].cards.firstIndex(where: { $0.id == cardID }),
                  case .recognition(var card) = messages[m].cards[c].kind else { continue }
            card.transcript = text
            card.uncertain = []
            messages[m].cards[c].kind = .recognition(card)
            if let u = messages.firstIndex(where: { $0.id == card.messageID }) {
                messages[u].recognizedText = text
            }
        }
    }

    private func startReply(precise: Bool) {
        var reply = ChatMessage(role: .model)
        reply.usedPreciseModel = precise
        messages.append(reply)
        replyID = reply.id
        progress = "思考中…"
        let run = UUID()
        runID = run
        task = Task { [weak self] in
            await self?.runLoop(model: precise ? AssistantConfig.preciseModel : AssistantConfig.defaultModel, run: run)
        }
    }

    // MARK: 工具呼叫迴圈

    private func runLoop(model: String, run: UUID) async {
        let client = GeminiClient(model: model)
        var rounds = 0
        var errorCounts: [String: Int] = [:]
        defer { finish(run) }

        while !Task.isCancelled {
            let contents = RequestBuilder.contents(history: history, messages: messages)
            progress = RequestBuilder.hasImages(contents) ? "辨識圖片中…" : "思考中…"
            let response: GeminiResponse
            do {
                response = try await client.generate(RequestBuilder.request(contents: contents))
            } catch {
                guard !Task.isCancelled else { return }
                let failure = error as? GeminiError ?? .network
                updateReply { $0.error = failure.errorDescription; $0.canRetry = failure.isRetryable }
                return
            }
            guard !Task.isCancelled else { return }
            if let used = response.usage { usage = usage + used }
            history.append(.model(response.parts))
            appendReplyText(response.text)

            let calls = response.functionCalls
            guard !calls.isEmpty else { return }
            rounds += 1

            var results: [JSONValue] = []
            var tooManyErrors = false
            for call in calls {
                progress = ToolRegistry.progressTitle(call.name)
                let context = ToolContext(modelContext: modelContext ?? AppDatabase.container.mainContext, host: self)
                let result = await ToolExecutor.run(name: call.name, args: call.args, context: context)
                if let message = result["error"]?.string {
                    let key = call.name + "|" + message
                    errorCounts[key, default: 0] += 1
                    if errorCounts[key, default: 0] > AssistantConfig.maxSameErrorRetries { tooManyErrors = true }
                }
                results.append(RequestBuilder.functionResponse(name: call.name, id: call.id, result: result))
                guard !Task.isCancelled else { return }
            }
            history.append(.toolResults(results))

            if tooManyErrors || rounds >= AssistantConfig.maxToolRounds {
                let notice = tooManyErrors ? "同一個步驟一直出錯，先停下來。可以換個說法，或把需求拆小再試一次。"
                    : "步驟太多，請把需求拆小"
                // 補一則模型回覆，下一句才不會接在工具結果後面
                history.append(.model([["text": .string(notice)]]))
                appendReplyText(notice)
                return
            }
        }
    }

    /// 迴圈結束：收掉進度；什麼都沒回的空白回覆拿掉。重置過就不動（已經是新的對話）
    private func finish(_ run: UUID) {
        guard runID == run else { return }
        runID = nil
        progress = nil
        task = nil
        if let replyID, let index = messages.firstIndex(where: { $0.id == replyID }),
           messages[index].text == nil, messages[index].cards.isEmpty, messages[index].error == nil {
            messages.remove(at: index)
        }
    }

    private func updateReply(_ change: (inout ChatMessage) -> Void) {
        guard let replyID, let index = messages.firstIndex(where: { $0.id == replyID }) else { return }
        change(&messages[index])
    }

    private func appendReplyText(_ text: String) {
        guard !text.isEmpty else { return }
        updateReply { message in
            message.text = [message.text, text].compactMap { $0 }.joined(separator: "\n\n")
        }
    }

    // MARK: ToolHost

    func addCard(_ card: ToolCard) {
        updateReply { $0.cards.append(card) }
    }

    func updateCard(_ card: ToolCard) {
        for m in messages.indices {
            if let c = messages[m].cards.firstIndex(where: { $0.id == card.id }) {
                messages[m].cards[c] = card
                return
            }
        }
    }

    func confirm(_ card: ToolCard) async -> (ConfirmDecision, ToolCard) {
        addCard(card)
        progress = "等你確認…"
        let decision = await withCheckedContinuation { continuation in
            pending[card.id] = continuation
        }
        progress = "加入牌組中…"
        let edited = self.card(card.id) ?? card
        if decision == .cancel { updateCard(Self.cancelled(edited)) }
        return (decision, edited)
    }

    func recordRecognition(transcript: String, imageType: String?, uncertain: [String]) -> UUID? {
        guard let index = messages.lastIndex(where: { $0.role == .user && !$0.imageData.isEmpty }) else { return nil }
        messages[index].recognizedText = transcript
        // 之後每一輪（包含這次後面的工具呼叫）都只送文字
        messages[index].imageData = []
        return messages[index].id
    }

    // MARK: 確認卡

    func card(_ id: UUID) -> ToolCard? {
        for message in messages {
            if let card = message.cards.first(where: { $0.id == id }) { return card }
        }
        return nil
    }

    func isAwaiting(_ cardID: UUID) -> Bool { pending[cardID] != nil }

    /// 確認卡上勾選、刪除、編輯
    func editCard(_ cardID: UUID, _ change: (inout ToolCard.Kind) -> Void) {
        guard var card = card(cardID) else { return }
        change(&card.kind)
        updateCard(card)
    }

    func resolve(_ cardID: UUID, _ decision: ConfirmDecision) {
        pending.removeValue(forKey: cardID)?.resume(returning: decision)
    }

    private static func cancelled(_ card: ToolCard) -> ToolCard {
        var card = card
        switch card.kind {
        case .words(var proposal):
            proposal.state = .cancelled
            card.kind = .words(proposal)
        case .patterns(var proposal):
            proposal.state = .cancelled
            card.kind = .patterns(proposal)
        default:
            break
        }
        return card
    }

    // MARK: 重置

    /// 「新對話」或離開超過 30 分鐘
    func reset() {
        task?.cancel()
        for continuation in pending.values { continuation.resume(returning: .cancel) }
        pending = [:]
        task = nil
        messages = []
        history = []
        originalImages = [:]
        usage = GeminiUsage()
        progress = nil
        replyID = nil
        runID = nil
    }

    func didEnterBackground(at date: Date = Date()) {
        backgroundedAt = date
    }

    func willEnterForeground(at date: Date = Date()) {
        defer { backgroundedAt = nil }
        guard let backgroundedAt, date.timeIntervalSince(backgroundedAt) > AssistantConfig.resetAfter else { return }
        reset()
    }

    var isEmpty: Bool { messages.isEmpty }

    /// 測試用：目前會送出的 contents
    var currentContents: [JSONValue] { RequestBuilder.contents(history: history, messages: messages) }
}
