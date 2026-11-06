import AppIntents
import Foundation
import HealthKit

/// 免費開發者帳號拿不到 HealthKit 權限，改由「捷徑」的「記錄健康樣本」寫進 Apple 健康：
/// 這個動作只負責從小米抓資料、轉成數值，並記住上次給到哪裡，避免重複寫入。
enum MiHealthKind: String, AppEnum, CaseIterable {
    case steps, distance, activeEnergy, heartRate, restingHeartRate, spo2, respiratoryRate, hrv, weight, bodyFat, sleep

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "小米健康資料類型"
    static let caseDisplayRepresentations: [MiHealthKind: DisplayRepresentation] = [
        .steps: "步數",
        .distance: "步行與跑步距離",
        .activeEnergy: "活動能量",
        .heartRate: "心率",
        .restingHeartRate: "靜止心率",
        .spo2: "血氧",
        .respiratoryRate: "呼吸速率",
        .hrv: "心率變異性",
        .weight: "體重",
        .bodyFat: "體脂肪率",
        .sleep: "睡眠",
    ]

    var title: String {
        switch self {
        case .steps: "步數"
        case .distance: "步行與跑步距離"
        case .activeEnergy: "活動能量"
        case .heartRate: "心率"
        case .restingHeartRate: "靜止心率"
        case .spo2: "血氧"
        case .respiratoryRate: "呼吸速率"
        case .hrv: "心率變異性"
        case .weight: "體重"
        case .bodyFat: "體脂肪率"
        case .sleep: "睡眠"
        }
    }

    var syncType: SyncDataType {
        switch self {
        case .steps, .distance, .activeEnergy: .dailyActivity
        case .heartRate, .restingHeartRate: .heartRate
        case .spo2: .spo2
        case .respiratoryRate: .respiratoryRate
        case .hrv: .hrv
        case .weight, .bodyFat: .bodyMeasurements
        case .sleep: .sleep
        }
    }

    /// 對應的 HealthKit 類型與捷徑裡用的單位（百分比給 0–100，捷徑的欄位就是這樣填）
    var quantity: (id: HKQuantityTypeIdentifier, unit: HKUnit, scale: Double, text: String)? {
        switch self {
        case .steps: (.stepCount, .count(), 1, "步")
        case .distance: (.distanceWalkingRunning, .meterUnit(with: .kilo), 1, "公里")
        case .activeEnergy: (.activeEnergyBurned, .kilocalorie(), 1, "大卡")
        case .heartRate: (.heartRate, .count().unitDivided(by: .minute()), 1, "次/分")
        case .restingHeartRate: (.restingHeartRate, .count().unitDivided(by: .minute()), 1, "次/分")
        case .spo2: (.oxygenSaturation, .percent(), 100, "%")
        case .respiratoryRate: (.respiratoryRate, .count().unitDivided(by: .minute()), 1, "次/分")
        case .hrv: (.heartRateVariabilitySDNN, .secondUnit(with: .milli), 1, "毫秒")
        case .weight: (.bodyMass, .gramUnit(with: .kilo), 1, "公斤")
        case .bodyFat: (.bodyFatPercentage, .percent(), 100, "%")
        case .sleep: nil
        }
    }

    /// 一天一筆的總量，今天還沒過完就先不給，免得之後少算
    var isDailyTotal: Bool { self == .steps || self == .distance || self == .activeEnergy }
}

enum MiSleepStage: String, AppEnum, CaseIterable {
    case asleep, inBed, awake, core, deep, rem
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "睡眠階段"
    static let caseDisplayRepresentations: [MiSleepStage: DisplayRepresentation] = [
        .asleep: "睡眠時間（淺眠＋深眠＋REM）", .inBed: "床上時間", .awake: "清醒",
        .core: "只有淺眠", .deep: "只有深眠", .rem: "只有 REM",
    ]
    /// 捷徑的「記錄健康樣本」只有清醒、床上時間、睡眠時間三種，淺眠／深眠／REM 要合併成「睡眠時間」
    func matches(_ stage: String) -> Bool {
        switch self {
        case .asleep: ["核心", "深層", "快速動眼"].contains(stage)
        default: title == stage
        }
    }
    var title: String {
        switch self {
        case .asleep: "睡眠時間"
        case .inBed: "在床上"
        case .core: "核心"
        case .deep: "深層"
        case .rem: "快速動眼"
        case .awake: "清醒"
        }
    }
}

/// 給捷徑用的一筆資料。
struct MiHealthSample: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "小米健康樣本"

    @Property(title: "數值") var value: Double
    @Property(title: "單位") var unit: String
    @Property(title: "開始時間") var start: Date
    @Property(title: "結束時間") var end: Date
    @Property(title: "睡眠階段") var stage: String

    init() {
        value = 0
        unit = ""
        start = .now
        end = .now
        stage = ""
    }

    init(value: Double, unit: String, start: Date, end: Date, stage: String = "") {
        self.value = value
        self.unit = unit
        self.start = start
        self.end = end
        self.stage = stage
    }

    var displayRepresentation: DisplayRepresentation {
        let time = start.formatted(date: .abbreviated, time: .shortened)
        if !stage.isEmpty { return DisplayRepresentation(title: "\(stage)", subtitle: "\(time)") }
        let number = value.formatted(.number.precision(.fractionLength(0...2)))
        return DisplayRepresentation(title: "\(number) \(unit)", subtitle: "\(time)")
    }
}

enum MiShortcutError: Error, CustomLocalizedStringResourceConvertible {
    case notSignedIn
    case failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notSignedIn: "還沒登入小米帳號，請先到 Recap → 設定 → 小米健康同步 登入。"
        case .failed(let message): "抓取小米資料失敗：\(message)"
        }
    }
}

struct GetMiHealthSamplesIntent: AppIntent {
    static let title: LocalizedStringResource = "取得小米健康資料"
    static let description = IntentDescription("從小米運動健康抓資料，搭配「重複每一項目」和「記錄健康樣本」寫進 Apple 健康。預設只給上次之後的新資料，不會重複。")

    @Parameter(title: "資料類型")
    var kind: MiHealthKind

    @Parameter(title: "只給新資料", default: true)
    var onlyNew: Bool

    @Parameter(title: "最多往回抓幾天", description: "第一次想補舊資料可以設大一點，最多 365 天。", default: 7)
    var days: Int

    @Parameter(title: "睡眠階段", description: "資料類型是睡眠時才用得到：只給這個階段，配合「記錄健康樣本」選同一個階段。")
    var sleepStage: MiSleepStage?

    static var parameterSummary: some ParameterSummary {
        Summary("取得小米的 \(\.$kind)") {
            \.$sleepStage
            \.$onlyNew
            \.$days
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[MiHealthSample]> {
        let samples = try await MiShortcutExport.samples(kind: kind, days: max(1, min(days, 365)), onlyNew: onlyNew,
                                                         sleepStage: kind == .sleep ? sleepStage : nil)
        return .result(value: samples)
    }
}

enum MiShortcutExport {
    private static func cursorKey(_ kind: MiHealthKind, _ stage: MiSleepStage?) -> String {
        "mi_shortcut_cursor_\(kind.rawValue)" + (stage.map { "_\($0.rawValue)" } ?? "")
    }

    static func resetCursors() {
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("mi_shortcut_cursor_") {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    static func samples(kind: MiHealthKind, days: Int, onlyNew: Bool, sleepStage: MiSleepStage? = nil) async throws -> [MiHealthSample] {
        guard let credential = CredentialStore.load() else { throw MiShortcutError.notSignedIn }
        let objects: [HKObject]
        do {
            let engine = SyncEngine()
            try await engine.connect(userId: credential.userId, passToken: credential.passToken)
            objects = try await engine.fetchObjects(type: kind.syncType, days: days)
        } catch {
            throw MiShortcutError.failed(error.localizedDescription)
        }

        let todayStart = Calendar.current.startOfDay(for: .now)
        var result: [MiHealthSample] = []
        if let q = kind.quantity {
            let wanted = HKQuantityType(q.id)
            for case let sample as HKQuantitySample in objects where sample.quantityType == wanted {
                if kind.isDailyTotal, sample.endDate > todayStart { continue }
                let value = sample.quantity.doubleValue(for: q.unit) * q.scale
                result.append(MiHealthSample(value: (value * 100).rounded() / 100, unit: q.text,
                                             start: sample.startDate, end: sample.endDate))
            }
            if kind == .heartRate { result = averaged(result, minutes: 10) }
        } else {
            for case let sample as HKCategorySample in objects where sample.categoryType == HKCategoryType(.sleepAnalysis) {
                let stage: String = switch HKCategoryValueSleepAnalysis(rawValue: sample.value) {
                case .inBed: "在床上"
                case .awake: "清醒"
                case .asleepDeep: "深層"
                case .asleepREM: "快速動眼"
                default: "核心"
                }
                if let sleepStage, !sleepStage.matches(stage) { continue }
                result.append(MiHealthSample(value: sample.endDate.timeIntervalSince(sample.startDate) / 60, unit: "分鐘",
                                             start: sample.startDate, end: sample.endDate, stage: stage))
            }
        }
        result.sort { $0.start < $1.start }

        if onlyNew {
            let key = cursorKey(kind, sleepStage)
            if let cursor = UserDefaults.standard.object(forKey: key) as? Date { result = result.filter { $0.start > cursor } }
            if let newest = result.map(\.start).max() {
                UserDefaults.standard.set(newest, forKey: key)
            }
        }
        return result
    }

    /// 心率一分鐘一筆太多，捷徑跑不動；每 10 分鐘取平均。
    private static func averaged(_ samples: [MiHealthSample], minutes: Int) -> [MiHealthSample] {
        let bucket = TimeInterval(minutes * 60)
        let groups = Dictionary(grouping: samples) { floor($0.start.timeIntervalSince1970 / bucket) }
        return groups.keys.sorted().compactMap { key in
            guard let items = groups[key], !items.isEmpty else { return nil }
            let avg = items.map(\.value).reduce(0, +) / Double(items.count)
            let start = Date(timeIntervalSince1970: key * bucket)
            return MiHealthSample(value: avg.rounded(), unit: items[0].unit, start: start, end: start.addingTimeInterval(bucket))
        }
    }
}
