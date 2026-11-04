import AppIntents
import Foundation

/// 即時動態上的按鈕。LiveActivityIntent 會在 App 的程序裡執行，App 啟動時會把實際動作接上。
enum LiveActivityActions {
    @MainActor static var stop: (() async -> Void)?
    @MainActor static var pause: (() async -> Void)?
    @MainActor static var resume: (() async -> Void)?
}

struct PauseFromActivityIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "暫停錄音"
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        await LiveActivityActions.pause?()
        return .result()
    }
}

/// 繼續錄音：同時是 AudioRecordingIntent，系統才允許從背景重新打開麥克風。
struct ResumeFromActivityIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "繼續錄音"
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        await LiveActivityActions.resume?()
        return .result()
    }
}

struct StopFromActivityIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "停止錄音"
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        await LiveActivityActions.stop?()
        return .result()
    }
}

enum RecapURL {
    /// 打開 App 並整理最近 N 分鐘
    static func quick(minutes: Int) -> URL { URL(string: "recap://quick?minutes=\(minutes)")! }
    static let open = URL(string: "recap://open")!
}
