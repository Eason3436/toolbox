import AppIntents
import Foundation
import UniformTypeIdentifiers

/// 「收錄最新截圖」：給捷徑用，可綁定到背面輕點或動作按鈕。
/// 捷徑做法：「截取螢幕畫面」→「收錄最新截圖」（把截圖傳進來，或不傳就收錄相簿最新一張）。
struct CaptureLatestScreenshotIntent: AppIntent {
    static let title: LocalizedStringResource = "收錄最新截圖"
    static let description = IntentDescription("把剛截的圖（或相簿裡最新的一張截圖）送進 Screenshots，並馬上開始 AI 分析。")
    static let openAppWhenRun = false

    @Parameter(title: "截圖", description: "可以接「截取螢幕畫面」的結果；不填就收錄相簿裡最新的一張截圖。", supportedContentTypes: [.image])
    var image: IntentFile?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let services = AppServices.shared
        let library = services.library
        library.refreshAccess()
        guard library.access == .full || library.access == .limited else {
            return .result(dialog: "請先打開 Screenshots 並允許取用照片。")
        }
        if let image {
            _ = try await library.saveToLibraryAndAnalyze(imageData: image.data)
            return .result(dialog: "已收錄，正在分析。")
        }
        // 剛截的圖可能還在寫入相簿，最多等幾秒
        let id = await library.captureLatest(newerThan: Date.now.addingTimeInterval(-20))
        return .result(dialog: id == nil ? "相簿裡找不到截圖。" : "已收錄最新截圖，正在分析。")
    }
}

/// 「搜尋截圖」：打開 App 並帶入關鍵字。
struct SearchScreenshotsIntent: AppIntent {
    static let title: LocalizedStringResource = "搜尋截圖"
    static let description = IntentDescription("用關鍵字搜尋截圖中的標題、摘要與文字。")
    static let openAppWhenRun = true

    @Parameter(title: "關鍵字")
    var query: String

    @MainActor
    func perform() async throws -> some IntentResult {
        AppServices.shared.router.search(query)
        return .result()
    }
}

/// 「問截圖」：用一句話問截圖內容，直接回答。
struct AskScreenshotsIntent: AppIntent {
    static let title: LocalizedStringResource = "問截圖"
    static let description = IntentDescription("例如「上次截的那家拉麵店叫什麼？」，會在裝置上搜尋截圖並回答。")
    static let openAppWhenRun = false

    @Parameter(title: "問題")
    var question: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let result = await AskService.ask(question, container: AppServices.shared.container)
        return .result(value: result.answer, dialog: IntentDialog(stringLiteral: result.answer))
    }
}

struct ScreenshotsShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CaptureLatestScreenshotIntent(),
            phrases: [
                "用 \(.applicationName) 收錄最新截圖",
                "\(.applicationName) 收錄截圖",
            ],
            shortTitle: "收錄最新截圖",
            systemImageName: "camera.viewfinder"
        )
        AppShortcut(
            intent: SearchScreenshotsIntent(),
            phrases: ["在 \(.applicationName) 搜尋截圖"],
            shortTitle: "搜尋截圖",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: AskScreenshotsIntent(),
            phrases: ["問 \(.applicationName)", "用 \(.applicationName) 問截圖"],
            shortTitle: "問截圖",
            systemImageName: "sparkles"
        )
    }
}
