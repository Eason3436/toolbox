import AppIntents
import Foundation

/// 捷徑動作：把銀行通知全文丟進來，用 Apple Intelligence 拆出商家與金額後記帳
struct LogNotificationIntent: AppIntent {
    static let title: LocalizedStringResource = "從通知記帳"
    static let description = IntentDescription(
        "把銀行、信用卡或電子支付的通知全文交給 Apple Intelligence（在裝置上執行），自動拆出商家、金額與分類，記成一筆帳。",
        categoryName: "記帳"
    )
    static let openAppWhenRun = false

    @Parameter(title: "通知內容", description: "通知的完整文字（標題＋內文）", inputOptions: String.IntentInputOptions(multiline: true))
    var text: String

    @Parameter(title: "帳戶名稱", description: "留空時依卡號末四碼或預設帳戶自動選擇")
    var accountName: String?

    static var parameterSummary: some ParameterSummary {
        Summary("用 Apple Intelligence 把 \(\.$text) 記帳") {
            \.$accountName
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let result = try await NoticeRecorder.record(text: text, accountName: accountName)
        return .result(value: result.summary, dialog: IntentDialog(stringLiteral: result.summary))
    }
}

/// 捷徑動作：已知商家與金額時直接記帳（例如「錢包」交易自動化）
struct QuickAddIntent: AppIntent {
    static let title: LocalizedStringResource = "快速記一筆"
    static let description = IntentDescription("直接用商家與金額記一筆支出，分類會依商家自動判斷。適合搭配「錢包」交易自動化。", categoryName: "記帳")
    static let openAppWhenRun = false

    @Parameter(title: "商家")
    var merchant: String

    @Parameter(title: "金額")
    var amount: Double

    @Parameter(title: "帳戶名稱")
    var accountName: String?

    static var parameterSummary: some ParameterSummary {
        Summary("記一筆 \(\.$merchant) \(\.$amount)") {
            \.$accountName
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let result = try await NoticeRecorder.record(text: merchant, accountName: accountName,
                                                     merchantOverride: merchant, amountOverride: amount)
        return .result(value: result.summary, dialog: IntentDialog(stringLiteral: result.summary))
    }
}

/// 捷徑動作：更新資產報價
struct RefreshQuotesIntent: AppIntent {
    static let title: LocalizedStringResource = "更新資產報價"
    static let description = IntentDescription("抓取股票、ETF、加密貨幣的最新價格與匯率，回傳目前總資產。", categoryName: "資產")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let r = await QuoteService.refreshAll(context: Store.context)
        let total = AssetMath.netWorth()
        var text = "已更新 \(r.updated) 項報價，總資產 \(Money.format(total))"
        if !r.failed.isEmpty { text += "\n更新失敗：\(r.failed.joined(separator: "、"))" }
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

struct LedgerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LogNotificationIntent(),
            phrases: ["用\(.applicationName)從通知記帳", "\(.applicationName)記帳"],
            shortTitle: "從通知記帳",
            systemImageName: "text.badge.plus"
        )
        AppShortcut(
            intent: RefreshQuotesIntent(),
            phrases: ["用\(.applicationName)更新報價"],
            shortTitle: "更新資產報價",
            systemImageName: "chart.line.uptrend.xyaxis"
        )
    }
}
