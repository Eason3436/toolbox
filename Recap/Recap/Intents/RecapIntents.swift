import AppIntents
import Foundation
import SwiftUI

/// 「開始全天錄音」：AudioRecordingIntent 可以從捷徑自動化在背景直接開麥克風（不用打開 App）。
/// 排程的做法：捷徑 → 自動化 → 特定時間 → 立即執行 → 「開始全天錄音」。
struct StartAllDayRecordingIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "開始全天錄音"
    static let description = IntentDescription("在背景開始錄音，之後自動轉文字並整理成今日 Recap。")

    @Parameter(title: "錄幾分鐘", description: "留空：在排程時段內會錄到時段結束，否則一直錄到你停止。")
    var minutes: Int?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        do {
            try await AppModel.shared.recorder.start(mode: .allDay, duration: minutes.map { TimeInterval($0 * 60) }, source: .shortcut)
        } catch {
            throw RecapIntentError.from(error)
        }
        if let stopAt = AppModel.shared.recorder.stopAt {
            return .result(dialog: "開始錄音，會錄到 \(stopAt.formatted(date: .omitted, time: .shortened))。")
        }
        return .result(dialog: "開始錄音。")
    }
}

/// 「開始上課」：可指定科目（不指定就由 AI 下課後判斷），即時轉文字＋翻譯。
struct StartLectureIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "開始上課"
    static let description = IntentDescription("開始錄這堂課，即時轉文字，下課後整理重點和老師說會考的地方。")

    @Parameter(title: "科目", description: "不指定的話，下課後由 AI 判斷是什麼課。")
    var subject: SchoolSubject?

    @Parameter(title: "錄幾分鐘", description: "留空：在排程時段內會錄到時段結束，否則一直錄到你停止。")
    var minutes: Int?

    static var parameterSummary: some ParameterSummary {
        Summary("開始上 \(\.$subject) 課") {
            \.$minutes
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = AppModel.shared
        let recorder = model.recorder
        if recorder.isActive, recorder.mode == .allDay {
            try await requestConfirmation(result: .result(dialog: "現在正在全天錄音，要先停掉、改錄這堂課嗎？"))
        }
        let picked = subject == .general ? nil : subject
        do {
            try await recorder.start(mode: .lecture, duration: minutes.map { TimeInterval($0 * 60) }, source: .shortcut, subject: picked)
        } catch {
            throw RecapIntentError.from(error)
        }
        model.router.tab = .lecture
        let chosen = recorder.lecture?.lecture.subject ?? .general
        let name = chosen == .general ? "這堂課" : (chosen.isSeminar ? "講座" : "\(chosen.title)課")
        return .result(dialog: "\(name)開始錄音，下課跟我說「停止錄音」。")
    }
}

struct PauseRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "暫停錄音"
    static let description = IntentDescription("暫停 Recap 的錄音，之後可以繼續。")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let recorder = AppModel.shared.recorder
        guard recorder.state == .recording || recorder.state == .interrupted else { throw RecapIntentError.notRecording }
        recorder.pause()
        return .result(dialog: "已暫停，說「繼續錄音」就會接著錄。")
    }
}

/// 繼續錄音要重新打開麥克風，所以是 AudioRecordingIntent。
struct ResumeRecordingIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "繼續錄音"
    static let description = IntentDescription("接著錄剛才暫停或被打斷的錄音。")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let recorder = AppModel.shared.recorder
        guard recorder.isActive else { throw RecapIntentError.notRecording }
        guard recorder.state == .paused || recorder.state == .interrupted else { throw RecapIntentError.notPaused }
        await recorder.resume(notifyOnFailure: false)
        guard recorder.state == .recording else {
            throw RecapIntentError.failed("麥克風還被別的 App 佔用，等一下再試。")
        }
        return .result(dialog: "繼續錄音。")
    }
}

struct StopRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "停止錄音"
    static let description = IntentDescription("停止 Recap 正在進行的錄音。")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let recorder = AppModel.shared.recorder
        guard recorder.isActive else { throw RecapIntentError.notRecording }
        let wasLecture = recorder.mode == .lecture
        if wasLecture {
            try await requestConfirmation(result: .result(dialog: "要結束這堂課嗎？"))
        }
        await recorder.stop()
        return .result(dialog: wasLecture ? "下課了，打開 Recap 時會整理重點。" : "已停止錄音，打開 Recap 時會整理成 Recap。")
    }
}

/// 「今日 Recap」：回答今天的總結。
struct TodayRecapIntent: AppIntent {
    static let title: LocalizedStringResource = "今日 Recap"
    static let description = IntentDescription("告訴你今天錄到的重點。")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let model = AppModel.shared
        let record = model.store.day(DayKey.today)
        if record.recap != nil {
            let entity = DayRecapEntity(record: record)
            var spoken = "\(entity.title)。\(entity.overview)"
            if !entity.todos.isEmpty { spoken += " 待辦：\(entity.todos.joined(separator: "、"))。" }
            return .result(value: entity.fullText, dialog: "\(spoken)")
        }
        if record.segments.isEmpty {
            return .result(value: "今天還沒有錄音。", dialog: "今天還沒有錄音。")
        }
        model.queue.regenerateRecap(DayKey.today)
        return .result(value: "今天的 Recap 還在整理中。", dialog: "今天的 Recap 還在整理中，打開 Recap 看看。")
    }
}

/// 「最近 N 分鐘重點」：直接在 Siri 裡唸出來；整理太久就請使用者打開 App 看。
struct QuickRecapIntent: AppIntent {
    static let title: LocalizedStringResource = "最近幾分鐘的重點"
    static let description = IntentDescription("把最近幾分鐘錄到的內容馬上整理成重點。")
    static let openAppWhenRun = false

    @Parameter(title: "分鐘數", default: 15)
    var minutes: Int

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let model = AppModel.shared
        let quick = model.quickRecap
        let wanted = max(1, min(minutes, 240))
        let work = Task { @MainActor in await quick.run(minutes: wanted) }
        // Siri 等不了太久：25 秒內沒好就改到 App 裡看
        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await work.value; return true }
            group.addTask { try? await Task.sleep(for: .seconds(25)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        guard finished else {
            throw needsToContinueInForegroundError("還在整理，要打開 Recap 看結果嗎？") {
                model.router.showQuickRecap = true
            }
        }
        switch quick.state {
        case .done:
            guard let digest = quick.digest else { throw RecapIntentError.failed("沒有整理出內容。") }
            let points = digest.points.prefix(3)
            let spoken = "\(digest.title)。" + points.joined(separator: "。")
            let full = "最近 \(wanted) 分鐘：\(digest.title)\n" + digest.points.map { "・\($0)" }.joined(separator: "\n")
                + (digest.todos.isEmpty ? "" : "\n待辦：\n" + digest.todos.map { "・\($0)" }.joined(separator: "\n"))
            return .result(value: full, dialog: "\(spoken)")
        case .failed(let message):
            throw RecapIntentError.failed(message)
        default:
            throw RecapIntentError.failed("沒有整理出內容。")
        }
    }
}

/// 「打開課堂筆記」
struct OpenLectureIntent: OpenIntent {
    static let title: LocalizedStringResource = "打開課堂筆記"
    static let description = IntentDescription("打開某一堂課的筆記畫面。")

    @Parameter(title: "課堂")
    var target: LectureEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        guard RecapStore.shared.lecture(target.id) != nil else { throw RecapIntentError.lectureNotFound }
        let router = AppModel.shared.router
        router.tab = .lecture
        router.lecturePath = NavigationPath([LectureRoute(id: target.id)])
        return .result()
    }
}

/// 「把待辦加到提醒事項」：先確認再加。
struct AddTodoToRemindersIntent: AppIntent {
    static let title: LocalizedStringResource = "待辦加到提醒事項"
    static let description = IntentDescription("把 Recap 或課堂筆記裡的一個待辦加到「提醒事項」，提到日期會自動設成期限。")

    @Parameter(title: "待辦")
    var todo: TodoEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await requestConfirmation(result: .result(dialog: "要把「\(todo.text)」加到提醒事項嗎？"))
        do {
            try await CalendarActions.addReminder(todo.text, notes: "來自 Recap：\(todo.source)")
        } catch {
            throw RecapIntentError.from(error)
        }
        if let due = todo.dueDate {
            return .result(dialog: "已加到提醒事項，期限 \(due.formatted(.dateTime.month().day()))。")
        }
        return .result(dialog: "已加到提醒事項。")
    }
}

struct RecapShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartLectureIntent(),
            phrases: [
                "用 \(.applicationName) 錄這堂課",
                "\(.applicationName) 開始上課",
                "\(.applicationName) 開始上 \(\.$subject) 課",
            ],
            shortTitle: "開始上課",
            systemImageName: "graduationcap"
        )
        AppShortcut(
            intent: StartAllDayRecordingIntent(),
            phrases: ["用 \(.applicationName) 開始錄音", "\(.applicationName) 開始錄音"],
            shortTitle: "開始錄音",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: PauseRecordingIntent(),
            phrases: ["\(.applicationName) 暫停錄音"],
            shortTitle: "暫停錄音",
            systemImageName: "pause.circle"
        )
        AppShortcut(
            intent: ResumeRecordingIntent(),
            phrases: ["\(.applicationName) 繼續錄音"],
            shortTitle: "繼續錄音",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: StopRecordingIntent(),
            phrases: ["\(.applicationName) 停止錄音"],
            shortTitle: "停止錄音",
            systemImageName: "stop.circle"
        )
        AppShortcut(
            intent: QuickRecapIntent(),
            phrases: ["\(.applicationName) 剛剛講了什麼", "\(.applicationName) 最近 15 分鐘重點"],
            shortTitle: "剛剛的重點",
            systemImageName: "clock.arrow.circlepath"
        )
        AppShortcut(
            intent: TodayRecapIntent(),
            phrases: ["\(.applicationName) 今天的重點", "看 \(.applicationName) 今日 Recap"],
            shortTitle: "今日 Recap",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: AskRecapIntent(),
            phrases: ["問 \(.applicationName)", "\(.applicationName) 幫我查"],
            shortTitle: "問 Recap",
            systemImageName: "questionmark.bubble"
        )
        AppShortcut(
            intent: OpenLectureIntent(),
            phrases: ["打開 \(.applicationName) 的 \(\.$target)", "\(.applicationName) 打開課堂筆記"],
            shortTitle: "課堂筆記",
            systemImageName: "book"
        )
    }
}
