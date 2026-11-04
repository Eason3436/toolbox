import AppIntents
import Foundation

/// 「開始全天錄音」：AudioRecordingIntent 可以從捷徑自動化在背景直接開麥克風（不用打開 App）。
/// 排程的做法：捷徑 → 自動化 → 特定時間 → 立即執行 → 「開始全天錄音」。
struct StartAllDayRecordingIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "開始全天錄音"
    static let description = IntentDescription("在背景開始錄音，之後自動轉文字並整理成今日 Recap。")

    @Parameter(title: "錄幾分鐘", description: "留空：在排程時段內會錄到時段結束，否則一直錄到你停止。")
    var minutes: Int?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await AppModel.shared.recorder.start(mode: .allDay, duration: minutes.map { TimeInterval($0 * 60) }, source: .shortcut)
        if let stopAt = AppModel.shared.recorder.stopAt {
            return .result(dialog: "開始錄音，會錄到 \(stopAt.formatted(date: .omitted, time: .shortened))。")
        }
        return .result(dialog: "開始錄音。")
    }
}

/// 「開始課堂模式」：即時轉文字＋翻譯。
struct StartLectureIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "開始課堂模式"
    static let description = IntentDescription("開始錄這堂課，即時轉文字並翻成中文，下課後整理重點。")

    @Parameter(title: "錄幾分鐘", description: "留空：在排程時段內會錄到時段結束，否則一直錄到你停止。")
    var minutes: Int?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await AppModel.shared.recorder.start(mode: .lecture, duration: minutes.map { TimeInterval($0 * 60) }, source: .shortcut)
        AppModel.shared.router.tab = .lecture
        return .result(dialog: "課堂模式開始。")
    }
}

struct StopRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "停止錄音"
    static let description = IntentDescription("停止 Recap 正在進行的錄音。")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let recorder = AppModel.shared.recorder
        guard recorder.isActive else { return .result(dialog: "目前沒有在錄音。") }
        await recorder.stop()
        return .result(dialog: "已停止錄音，打開 App 時會整理成 Recap。")
    }
}

/// 「今日 Recap」：回答今天的總結（需要 Apple Intelligence）。
struct TodayRecapIntent: AppIntent {
    static let title: LocalizedStringResource = "今日 Recap"
    static let description = IntentDescription("告訴你今天錄到的重點。")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = AppModel.shared
        let record = model.store.day(DayKey.today)
        if let recap = record.recap {
            var text = "\(recap.title)。\(recap.overview)"
            if !recap.todos.isEmpty { text += " 待辦：\(recap.todos.joined(separator: "、"))。" }
            return .result(dialog: "\(text)")
        }
        if record.segments.isEmpty && record.lectures.isEmpty {
            return .result(dialog: "今天還沒有錄音。")
        }
        model.queue.regenerateRecap(DayKey.today)
        return .result(dialog: "今天的 Recap 還在整理中，打開 Recap 看看。")
    }
}

struct RecapShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartAllDayRecordingIntent(),
            phrases: ["用 \(.applicationName) 開始錄音", "\(.applicationName) 開始錄音"],
            shortTitle: "開始錄音",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: StartLectureIntent(),
            phrases: ["用 \(.applicationName) 錄這堂課", "\(.applicationName) 課堂模式"],
            shortTitle: "課堂模式",
            systemImageName: "captions.bubble"
        )
        AppShortcut(
            intent: StopRecordingIntent(),
            phrases: ["\(.applicationName) 停止錄音"],
            shortTitle: "停止錄音",
            systemImageName: "stop.circle"
        )
        AppShortcut(
            intent: TodayRecapIntent(),
            phrases: ["\(.applicationName) 今天的重點", "看 \(.applicationName) 今日 Recap"],
            shortTitle: "今日 Recap",
            systemImageName: "sparkles"
        )
    }
}
