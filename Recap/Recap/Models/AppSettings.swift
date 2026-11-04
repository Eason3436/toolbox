import Foundation
import Observation

/// 使用者設定（存在 UserDefaults）。
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    /// 全天模式每段幾分鐘
    var segmentMinutes: Int { didSet { defaults.set(segmentMinutes, forKey: "segmentMinutes") } }
    /// 全天模式的辨識語言
    var transcriptionLocale: String { didSet { defaults.set(transcriptionLocale, forKey: "transcriptionLocale") } }
    /// 課堂模式：上課用的語言
    var lectureSourceLocale: String { didSet { defaults.set(lectureSourceLocale, forKey: "lectureSourceLocale") } }
    /// 課堂模式：翻譯成
    var translationTarget: String { didSet { defaults.set(translationTarget, forKey: "translationTarget") } }
    /// 幾乎沒人聲的段落不轉文字
    var skipSilence: Bool { didSet { defaults.set(skipSilence, forKey: "skipSilence") } }
    /// 轉好文字後刪掉全天錄音的音檔（省空間）
    var deleteAudioAfterTranscribe: Bool { didSet { defaults.set(deleteAudioAfterTranscribe, forKey: "deleteAudioAfterTranscribe") } }
    /// 錄音檔保留幾天（0 = 永久保留）；過期只刪音檔，文字稿與摘要保留
    var audioRetentionDays: Int { didSet { defaults.set(audioRetentionDays, forKey: "audioRetentionDays") } }
    /// 在排程時段內打開 App 時自動開始錄音
    var autoStartInSchedule: Bool { didSet { defaults.set(autoStartInSchedule, forKey: "autoStartInSchedule") } }
    /// 排程開始時發通知
    var scheduleNotifications: Bool { didSet { defaults.set(scheduleNotifications, forKey: "scheduleNotifications") } }
    var schedules: [ScheduleRule] {
        didSet {
            if let data = try? JSONEncoder().encode(schedules) { defaults.set(data, forKey: "schedules") }
        }
    }
    /// 自訂詞彙（人名、術語），提高辨識準確度
    var vocabulary: [String] { didSet { defaults.set(vocabulary, forKey: "vocabulary") } }
    /// 錄音時加強人聲、降低背景雜音
    var voiceProcessing: Bool { didSet { defaults.set(voiceProcessing, forKey: "voiceProcessing") } }
    /// 轉完文字後用 AI 校正錯字
    var aiCorrection: Bool { didSet { defaults.set(aiCorrection, forKey: "aiCorrection") } }
    /// 課堂畫面只顯示翻譯
    var lectureShowSource: Bool { didSet { defaults.set(lectureShowSource, forKey: "lectureShowSource") } }

    private init() {
        defaults.register(defaults: [
            "segmentMinutes": 5,
            "transcriptionLocale": "zh-TW",
            "lectureSourceLocale": "en-US",
            "translationTarget": "zh-Hant-TW",
            "skipSilence": true,
            "deleteAudioAfterTranscribe": false,
            "autoStartInSchedule": true,
            "audioRetentionDays": 7,
            "scheduleNotifications": true,
            "lectureShowSource": true,
            "voiceProcessing": true,
            "aiCorrection": true,
        ])
        segmentMinutes = defaults.integer(forKey: "segmentMinutes")
        transcriptionLocale = defaults.string(forKey: "transcriptionLocale") ?? "zh-TW"
        lectureSourceLocale = defaults.string(forKey: "lectureSourceLocale") ?? "en-US"
        translationTarget = defaults.string(forKey: "translationTarget") ?? "zh-Hant-TW"
        skipSilence = defaults.bool(forKey: "skipSilence")
        deleteAudioAfterTranscribe = defaults.bool(forKey: "deleteAudioAfterTranscribe")
        autoStartInSchedule = defaults.bool(forKey: "autoStartInSchedule")
        audioRetentionDays = defaults.integer(forKey: "audioRetentionDays")
        scheduleNotifications = defaults.bool(forKey: "scheduleNotifications")
        lectureShowSource = defaults.bool(forKey: "lectureShowSource")
        vocabulary = defaults.stringArray(forKey: "vocabulary") ?? []
        voiceProcessing = defaults.bool(forKey: "voiceProcessing")
        aiCorrection = defaults.bool(forKey: "aiCorrection")
        if let data = defaults.data(forKey: "schedules"),
           let rules = try? JSONDecoder().decode([ScheduleRule].self, from: data) {
            schedules = rules
        } else {
            schedules = []
        }
    }

    /// 現在落在哪一條排程裡（回傳排程與結束時間）。
    func activeSchedule(at date: Date = .now) -> (rule: ScheduleRule, end: Date)? {
        for rule in schedules {
            if let end = rule.windowEnd(containing: date) { return (rule, end) }
        }
        return nil
    }
}
