import ActivityKit
import Foundation

/// 錄音中的即時動態（鎖定畫面＋動態島）。App 與 Widget 共用。
struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// 這次錄音開始的時間（用來顯示計時）
        var startedAt: Date
        var isPaused: Bool
        /// 課堂模式：最新一句中文翻譯；全天模式：目前狀態文字
        var line: String?
        /// 已存下的段數
        var segmentCount: Int
        /// 自動停止的時間（排程或指定時長）
        var stopAt: Date?
    }

    /// "allDay" 或 "lecture"
    var mode: String

    var isLecture: Bool { mode == "lecture" }
}
