import Foundation

enum RecordingMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// 全天錄音：每幾分鐘切一段，之後轉文字、摘要、合併成今日 Recap
    case allDay
    /// 課堂模式：即時轉文字＋即時翻譯，課後產生重點
    case lecture

    var id: String { rawValue }
    var title: String {
        switch self {
        case .allDay: "全天錄音"
        case .lecture: "課堂模式"
        }
    }
}

enum SegmentStatus: String, Codable, Sendable {
    /// 剛錄好，等待轉文字
    case recorded
    /// 轉好文字，等待摘要
    case transcribed
    /// 幾乎沒有人聲，略過
    case silent
    /// 已摘要
    case summarized
    /// 轉文字失敗
    case failed

    var label: String {
        switch self {
        case .recorded: "等待轉文字"
        case .transcribed: "等待摘要"
        case .silent: "安靜，略過"
        case .summarized: "已整理"
        case .failed: "轉文字失敗"
        }
    }
}

/// 全天錄音的一段（預設 5 分鐘）。
struct Segment: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var start: Date
    var end: Date
    /// 相對於 Recordings 資料夾的路徑；刪除音檔後為 nil
    var audioFile: String?
    /// 有人聲的秒數（粗估）
    var voicedSeconds: Double
    var status: SegmentStatus
    var transcript: String?
    var title: String?
    var points: [String] = []
    var todos: [String] = []
    var error: String?

    var duration: TimeInterval { end.timeIntervalSince(start) }
    var hasText: Bool { !(transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// 一天的總整理。
struct DailyRecap: Codable, Hashable, Sendable {
    var title: String
    var overview: String
    var highlights: [String]
    var todos: [String]
    var generatedAt: Date
    /// 產生時用了幾段內容
    var sourceCount: Int
}

/// 課堂模式的一句（原文＋翻譯）。
struct LiveLine: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    /// 距離課堂開始的秒數
    var offset: TimeInterval
    var source: String
    var translation: String?
}

struct LectureSummary: Codable, Hashable, Sendable {
    var title: String
    var overview: String
    var keyPoints: [String]
    var terms: [String]
    var todos: [String]
    var generatedAt: Date
}

struct AudioPart: Codable, Hashable, Sendable {
    var file: String
    var start: Date
    var end: Date
}

/// 一堂課。
struct Lecture: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var start: Date
    var end: Date?
    var sourceLocale: String
    var targetLanguage: String
    var audioParts: [AudioPart] = []
    var lines: [LiveLine] = []
    var summary: LectureSummary?
    var summaryError: String?
    /// 使用者自訂名稱
    var name: String?

    var displayTitle: String {
        if let name, !name.isEmpty { return name }
        if let title = summary?.title, !title.isEmpty { return title }
        return "課堂 \(start.formatted(date: .omitted, time: .shortened))"
    }

    var sourceText: String { lines.map(\.source).joined(separator: "\n") }
    var needsSummary: Bool { end != nil && summary == nil && !lines.isEmpty }
}

/// 一天的資料（存成一個 JSON 檔）。
struct DayRecord: Codable, Sendable {
    var dayKey: String
    var segments: [Segment] = []
    var lectures: [Lecture] = []
    var recap: DailyRecap?
    /// 有新內容，Recap 需要重新產生
    var recapDirty = false

    var date: Date { DayKey.date(from: dayKey) ?? .now }
    var spokenSegments: [Segment] { segments.filter { $0.status != .silent } }
}

enum DayKey {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func key(for date: Date) -> String { formatter.string(from: date) }
    static func date(from key: String) -> Date? { formatter.date(from: key) }
    static var today: String { key(for: .now) }
}

/// 排程：哪幾天的幾點到幾點錄音。
struct ScheduleRule: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String = "上班時間"
    var enabled = true
    var mode: RecordingMode = .allDay
    /// 1 = 星期日 … 7 = 星期六（Calendar.weekday）
    var weekdays: Set<Int> = [2, 3, 4, 5, 6]
    /// 從午夜起算的分鐘
    var startMinute: Int = 9 * 60
    var endMinute: Int = 18 * 60

    var crossesMidnight: Bool { endMinute <= startMinute }

    static func timeText(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }

    var timeRangeText: String {
        "\(Self.timeText(startMinute))–\(Self.timeText(endMinute))\(crossesMidnight ? "（隔天）" : "")"
    }

    var weekdayText: String {
        let names = ["日", "一", "二", "三", "四", "五", "六"]
        if weekdays.count == 7 { return "每天" }
        if weekdays == [2, 3, 4, 5, 6] { return "平日" }
        if weekdays == [1, 7] { return "週末" }
        return weekdays.sorted().map { "週" + names[$0 - 1] }.joined(separator: "、")
    }

    /// 如果 `date` 落在這條排程的時段內，回傳這個時段的結束時間。
    func windowEnd(containing date: Date, calendar: Calendar = .current) -> Date? {
        guard enabled else { return nil }
        let dayStart = calendar.startOfDay(for: date)
        let minute = Int(date.timeIntervalSince(dayStart) / 60)
        let weekday = calendar.component(.weekday, from: date)
        if !crossesMidnight {
            if weekdays.contains(weekday), minute >= startMinute, minute < endMinute {
                return dayStart.addingTimeInterval(TimeInterval(endMinute * 60))
            }
            return nil
        }
        // 跨午夜：今天 start 之後，或昨天開始、今天 end 之前
        if weekdays.contains(weekday), minute >= startMinute {
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
            return tomorrow.addingTimeInterval(TimeInterval(endMinute * 60))
        }
        let yesterdayWeekday = weekday == 1 ? 7 : weekday - 1
        if weekdays.contains(yesterdayWeekday), minute < endMinute {
            return dayStart.addingTimeInterval(TimeInterval(endMinute * 60))
        }
        return nil
    }
}

enum RecapError: LocalizedError {
    case microphoneDenied
    case noInput
    case localeUnsupported(String)
    case speechUnavailable
    case modelUnavailable(String)
    case conversionFailed

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: "沒有麥克風權限。請到「設定 → Recap」打開麥克風。"
        case .noInput: "找不到可用的麥克風。"
        case .localeUnsupported(let id): "這台裝置的語音辨識不支援「\(id)」。請到設定換一個語言。"
        case .speechUnavailable: "這台裝置不支援裝置端語音辨識。"
        case .modelUnavailable(let reason): reason
        case .conversionFailed: "音訊格式轉換失敗。"
        }
    }
}
