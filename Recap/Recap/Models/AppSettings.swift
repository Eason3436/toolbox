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
    /// 長時間沒有近距離說話時自動省電（關人聲加強、降位元率）
    var autoPowerSave: Bool { didSet { defaults.set(autoPowerSave, forKey: "autoPowerSave") } }
    /// 近距離說話的判定門檻：0 = 要很近才算、1 = 一般、2 = 稍遠也算
    var powerSaveSensitivity: Int { didSet { defaults.set(powerSaveSensitivity, forKey: "powerSaveSensitivity") } }
    /// 摘要、追問用哪個 AI
    var aiProvider: AIConfig.Provider { didSet { defaults.set(aiProvider.rawValue, forKey: "aiProvider"); syncAI() } }
    var geminiModel: String { didSet { defaults.set(geminiModel, forKey: "geminiModel"); syncAI() } }
    /// 存在鑰匙圈
    var geminiAPIKey: String { didSet { Keychain.write(geminiAPIKey, for: "geminiAPIKey"); syncAI() } }
    /// 中英夾雜：用中、英兩個模型各辨識一次再由 AI 合併
    var mixedLanguage: Bool { didSet { defaults.set(mixedLanguage, forKey: "mixedLanguage") } }
    /// 加入高中上課常用語、各科專有名詞
    var highSchoolMode: Bool { didSet { defaults.set(highSchoolMode, forKey: "highSchoolMode") } }
    /// 學習記憶：記住出現過的術語、參考之前上過的課
    var learningMemory: Bool { didSet { defaults.set(learningMemory, forKey: "learningMemory") } }
    /// 課表（依時間自動選科目）
    var timetable: [TimetableEntry] {
        didSet { if let data = try? JSONEncoder().encode(timetable) { defaults.set(data, forKey: "timetable") } }
    }
    /// 非中文授課（例如英文課）：即時字幕與翻譯
    var lectureForeign: Bool { didSet { defaults.set(lectureForeign, forKey: "lectureForeign") } }
    /// 課堂模式目前的科目
    var lectureSubject: SchoolSubject { didSet { defaults.set(lectureSubject.rawValue, forKey: "lectureSubject") } }
    /// 用 Groq Whisper 重新辨識 AI 覺得轉得不好的段落
    var whisperEnabled: Bool { didSet { defaults.set(whisperEnabled, forKey: "whisperEnabled") } }
    var groqAPIKey: String { didSet { Keychain.write(groqAPIKey, for: "groqAPIKey") } }
    var whisperModel: String { didSet { defaults.set(whisperModel, forKey: "whisperModel") } }
    /// 每天最多送幾分鐘的錄音
    var whisperDailyMinutes: Int { didSet { defaults.set(whisperDailyMinutes, forKey: "whisperDailyMinutes") } }
    var canUseWhisper: Bool { whisperEnabled && !groqAPIKey.isEmpty }
    /// 同步到自己的 Recap MCP 伺服器，讓 Claude 讀得到
    var syncEnabled: Bool { didSet { defaults.set(syncEnabled, forKey: "syncEnabled") } }
    /// Supabase 專案網址（https://xxxx.supabase.co）
    var syncServerURL: String { didSet { defaults.set(syncServerURL, forKey: "syncServerURL") } }
    /// Supabase 的 publishable／anon key（本來就是公開用的）
    var syncAPIKey: String { didSet { defaults.set(syncAPIKey, forKey: "syncAPIKey") } }
    /// App 自己產生、第一次連線時綁定的私人 Token（只存鑰匙圈）
    var syncToken: String { didSet { Keychain.write(syncToken, for: "syncToken") } }
    var canSync: Bool { syncEnabled && !syncServerURL.isEmpty && !syncAPIKey.isEmpty && !syncToken.isEmpty }
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
            "autoPowerSave": true,
            "mixedLanguage": true,
            "highSchoolMode": true,
            "learningMemory": true,
            "lectureForeign": false,
            "powerSaveSensitivity": 1,
            "aiProvider": "apple",
            "geminiModel": GeminiClient.defaultModel,
            "whisperEnabled": false,
            "whisperModel": GroqWhisper.defaultModel,
            "whisperDailyMinutes": 120,
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
        autoPowerSave = defaults.bool(forKey: "autoPowerSave")
        mixedLanguage = defaults.bool(forKey: "mixedLanguage")
        highSchoolMode = defaults.bool(forKey: "highSchoolMode")
        learningMemory = defaults.bool(forKey: "learningMemory")
        lectureForeign = defaults.bool(forKey: "lectureForeign")
        if let data = defaults.data(forKey: "timetable"), let saved = try? JSONDecoder().decode([TimetableEntry].self, from: data) {
            timetable = saved
        } else {
            timetable = []
        }
        lectureSubject = SchoolSubject(rawValue: defaults.string(forKey: "lectureSubject") ?? "") ?? .general
        powerSaveSensitivity = defaults.integer(forKey: "powerSaveSensitivity")
        aiProvider = AIConfig.Provider(rawValue: defaults.string(forKey: "aiProvider") ?? "") ?? .apple
        geminiModel = defaults.string(forKey: "geminiModel") ?? GeminiClient.defaultModel
        geminiAPIKey = Keychain.read("geminiAPIKey") ?? ""
        whisperEnabled = defaults.bool(forKey: "whisperEnabled")
        syncEnabled = defaults.bool(forKey: "syncEnabled")
        syncServerURL = defaults.string(forKey: "syncServerURL") ?? ""
        syncAPIKey = defaults.string(forKey: "syncAPIKey") ?? ""
        syncToken = Keychain.read("syncToken") ?? ""
        groqAPIKey = Keychain.read("groqAPIKey") ?? ""
        whisperModel = defaults.string(forKey: "whisperModel") ?? GroqWhisper.defaultModel
        whisperDailyMinutes = defaults.integer(forKey: "whisperDailyMinutes")
        if let data = defaults.data(forKey: "schedules"),
           let rules = try? JSONDecoder().decode([ScheduleRule].self, from: data) {
            schedules = rules
        } else {
            schedules = []
        }
        syncAI()
    }

    private func syncAI() {
        AIConfig.update(provider: aiProvider, model: geminiModel, apiKey: geminiAPIKey)
    }

    /// 辨識提示詞：自訂詞彙優先，再加上科目術語與上課常用語（太多反而沒效果，限制數量）
    func recognitionVocabulary(subject: SchoolSubject? = nil) -> [String] {
        var words = vocabulary
        // 學過的詞放前面：那是這個使用者真的會聽到的
        words += LearningMemory.shared.vocabulary(for: subject, limit: 60)
        if let subject { words += subject.terms }
        if highSchoolMode, subject?.isSeminar != true { words += SchoolSubject.classroomPhrases }
        var seen = Set<String>()
        return Array(words.filter { seen.insert($0).inserted }.prefix(160))
    }

    /// 中英夾雜時，第二個辨識語言
    func secondaryLocale(for primary: String) -> String? {
        guard mixedLanguage else { return nil }
        return primary.hasPrefix("zh") || primary.hasPrefix("yue") ? "en-US" : (primary.hasPrefix("en") ? "zh-TW" : nil)
    }

    /// 近距離說話的音量門檻（dBFS）
    var nearSpeechThresholdDB: Float { [-30, -37, -44][max(0, min(2, powerSaveSensitivity))] }

    /// 現在落在哪一條排程裡（回傳排程與結束時間）。
    func activeSchedule(at date: Date = .now) -> (rule: ScheduleRule, end: Date)? {
        for rule in schedules {
            if let end = rule.windowEnd(containing: date) { return (rule, end) }
        }
        return nil
    }
}
