import Foundation
import HealthKit
import Observation
import SwiftData

enum AppError: LocalizedError {
    case noCredentials
    case healthKitUnavailable

    var errorDescription: String? {
        switch self {
        case .noCredentials: return "未找到小米憑據，請先在設定頁登入。"
        case .healthKitUnavailable: return "當前裝置不支援 HealthKit。"
        }
    }
}

/// 應用全域性狀態（主執行緒）。
@MainActor
@Observable
final class HMAppModel {
    var isConfigured = false
    var connected = false
    var accountID = ""
    var healthKitAuthorized = false
    var isSyncing = false
    var backfillDays = 30
    var statusMessage = ""
    var lastError: String?
    var outcomes: [SyncDataType: SyncOutcome] = [:]
    /// 最近 N 天資料概覽（從 HealthKit 讀回，用於 App 內回顯）。
    var summary: HealthSummary?
    /// 最近 N 天每日趨勢（用於 Charts）。
    var trends: [DailyTrend] = []
    /// 當前正在同步的型別索引和總數（用於進度顯示）。
    var currentSyncIndex: Int = 0
    var totalSyncCount: Int = 0

    /// 同步進度文字，如 "正在同步 3/9"。
    var syncProgressText: String? {
        guard isSyncing, totalSyncCount > 0 else { return nil }
        return "正在同步 \(currentSyncIndex)/\(totalSyncCount)"
    }

    /// 小米憑據是否已過期/無效（需要使用者重新登入獲取新 token）。
    var authNeedsRefresh = false

    /// 已啟用的同步類別（持久化到 UserDefaults，預設全部啟用）。
    var enabledTypes: Set<SyncDataType> = Set(SyncDataType.allCases)

    private var engine: SyncEngine?

    // MARK: - 初始化 / 憑據

    func bootstrap() {
        CredentialStore.migrateIfNeeded()
        loadEnabledTypes()
        if let cred = CredentialStore.load() {
            isConfigured = true
            accountID = mask(cred.userId)
        }
        refreshHealthKitStatus()
    }

    // MARK: - 同步類別開關

    func isTypeEnabled(_ type: SyncDataType) -> Bool {
        enabledTypes.contains(type)
    }

    func setTypeEnabled(_ type: SyncDataType, enabled: Bool) {
        if enabled {
            enabledTypes.insert(type)
        } else {
            enabledTypes.remove(type)
        }
        UserDefaults.standard.set(
            enabledTypes.map(\.rawValue).sorted(),
            forKey: Self.enabledTypesKey
        )
    }

    private static let enabledTypesKey = "enabled_sync_types"

    private func loadEnabledTypes() {
        guard let raw = UserDefaults.standard.array(forKey: Self.enabledTypesKey) as? [String] else {
            return
        }
        let stored = Set(raw.compactMap(SyncDataType.init(rawValue:)))
        if !stored.isEmpty {
            enabledTypes = stored
        }
    }

    func saveCredentials(userId: String, passToken: String) async throws {
        try CredentialStore.save(userId: userId, passToken: passToken)
        let engine = SyncEngine()
        try await engine.connect(userId: userId, passToken: passToken)
        self.engine = engine
        isConfigured = true
        connected = true
        authNeedsRefresh = false
        accountID = mask(userId)
        refreshHealthKitStatus()
    }

    func disconnect(modelContext: ModelContext? = nil) {
        engine = nil
        CredentialStore.delete()
        isConfigured = false
        connected = false
        accountID = ""
        outcomes = [:]
        // 清除同步遊標和壓力記錄，防止切換賬號時新賬號繼承上一個賬號的資料
        if let modelContext {
            SyncStateStore.clearAll(in: modelContext)
            StressStore.clearAll(in: modelContext)
            SyncLogStore.clearAll(in: modelContext)
        }
    }

    // MARK: - HealthKit

    func requestHealthKit() async throws {
        guard HealthKitManager.isAvailable else { throw AppError.healthKitUnavailable }
        try await HealthKitManager.requestAuthorization()
        refreshHealthKitStatus()
    }

    func refreshHealthKitStatus() {
        guard HealthKitManager.isAvailable else {
            healthKitAuthorized = false
            return
        }
        let status = HealthKitManager.healthStore.authorizationStatus(
            for: HKQuantityType(.stepCount)
        )
        healthKitAuthorized = (status == .sharingAuthorized)
    }

    // MARK: - 同步

    /// 讀取最近 N 天健康摘要和趨勢資料用於 App 內回顯。
    func refreshSummary(days: Int = 7) async {
        summary = await HealthKitReader.summary(days: days)
        trends = await HealthKitReader.trendSeries(days: days)
    }

    /// 若存在尚未請求過授權的型別（如後來新增的呼吸頻率），先彈出 HealthKit 授權。
    func ensureHealthKitAuthorization() async {
        guard HealthKitManager.isAvailable else { return }
        let notDetermined = HealthKitManager.typesToShare.contains { type in
            HealthKitManager.healthStore.authorizationStatus(for: type) == .notDetermined
        }
        guard notDetermined else { return }
        do {
            try await HealthKitManager.requestAuthorization()
            refreshHealthKitStatus()
        } catch {
            lastError = "HealthKit 授權失敗：\(error.localizedDescription)"
        }
    }

    /// - Parameters:
    ///   - forceBackfill: 為 true 時忽略增量遊標，按 `backfillDays` 重新回填歷史。
    ///   - isBackground: 是否為後臺同步觸發（失敗時傳送本地通知）。
    func syncAll(modelContext: ModelContext, forceBackfill: Bool = false, isBackground: Bool = false) async {
        isSyncing = true
        lastError = nil
        defer { isSyncing = false }

        // 新增型別（如呼吸頻率）可能還沒授權，先補齊授權，否則寫入會被 HealthKit 拒絕
        await ensureHealthKitAuthorization()
        // 檢查使用者是否在系統設定中撤銷了許可權
        refreshHealthKitStatus()
        guard healthKitAuthorized else {
            lastError = "HealthKit 寫入許可權未授權，請在 設定 → 健康 → 資料訪問 中允許 HealthMi"
            statusMessage = "❌ HealthKit 許可權未授權"
            return
        }

        do {
            try await ensureEngine()
        } catch {
            lastError = error.localizedDescription
            statusMessage = "❌ \(error.localizedDescription)"
            return
        }

        var messages: [String] = []
        let types = SyncDataType.allCases.filter { enabledTypes.contains($0) }
        totalSyncCount = types.count
        currentSyncIndex = 0
        await engine?.clearCache()
        for type in types {
            currentSyncIndex += 1
            // 後臺同步被系統取消時，儘早退出
            if Task.isCancelled { break }
            let highWater = SyncStateStore.state(for: type, in: modelContext)?.lastSyncedEnd
            do {
                if type == .stress {
                    // 壓力資料不走 HealthKit，走 SwiftData
                    let result = try await engine?.syncStress(
                        highWater: highWater, backfillDays: backfillDays,
                        forceBackfill: forceBackfill
                    )
                    if let result {
                        if forceBackfill {
                            StressStore.clearAll(in: modelContext)
                        }
                        let added = StressStore.save(samples: result.samples, in: modelContext)
                        let outcome = SyncOutcome(
                            type: .stress, fetched: result.samples.count,
                            added: added, highWater: result.outcome.highWater
                        )
                        SyncStateStore.record(
                            type: .stress, highWater: outcome.highWater,
                            added: added, in: modelContext
                        )
                        outcomes[.stress] = outcome
                        messages.append("壓力 +\(added)")
                        SyncLogStore.append(
                            type: .stress, fetched: result.samples.count,
                            added: added, success: true, in: modelContext
                        )
                    }
                } else {
                    let outcome = try await engine?.sync(
                        type: type, highWater: highWater, backfillDays: backfillDays,
                        forceBackfill: forceBackfill
                    )
                    if let outcome {
                        SyncStateStore.record(
                            type: type, highWater: outcome.highWater,
                            added: outcome.added, in: modelContext
                        )
                        outcomes[type] = outcome
                        messages.append("\(type.displayName) +\(outcome.added)")
                        SyncLogStore.append(
                            type: type, fetched: outcome.fetched,
                            added: outcome.added, success: true, in: modelContext
                        )
                    }
                }
            } catch {
                let message = "\(type.displayName)：\(Self.describeSyncError(error))"
                lastError = message
                messages.append("\(type.displayName) ❌")
                SyncLogStore.append(
                    type: type, fetched: 0, added: 0,
                    success: false, errorMessage: Self.describeSyncError(error), in: modelContext
                )
            }
        }
        statusMessage = messages.joined(separator: "  ")
        refreshHealthKitStatus()
        // 同步完成後重新整理 App 內資料概覽
        await refreshSummary()
        // 後臺同步失敗時傳送本地通知
        if isBackground, let lastError {
            await NotificationManager.notifySyncFailure(lastError)
        }
    }

    /// 把同步錯誤轉成可讀資訊，健康許可權被拒時給出設定引導。
    private static func describeSyncError(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == HKErrorDomain {
            if nsError.code == HKError.Code.errorAuthorizationDenied.rawValue
                || nsError.code == HKError.Code.errorAuthorizationNotDetermined.rawValue {
                return "健康許可權未允許（請在 設定 → 健康 → 資料訪問 中允許 HealthMi）"
            }
        }
        return error.localizedDescription
    }

    private func ensureEngine() async throws {
        if engine != nil { return }
        guard let cred = CredentialStore.load() else { throw AppError.noCredentials }
        let newEngine = SyncEngine()
        do {
            try await newEngine.connect(userId: cred.userId, passToken: cred.passToken)
            engine = newEngine
            connected = true
            authNeedsRefresh = false
            accountID = mask(cred.userId)
        } catch {
            if Self.isAuthError(error) {
                authNeedsRefresh = true
                lastError = "小米憑據已過期或無效，請更新憑據後重試。"
            }
            throw error
        }
    }

    /// 是否小米登入認證錯誤（passToken 過期 / 無效等）。
    private static func isAuthError(_ error: Error) -> Bool {
        if case MiLoginError.loginRejected = error { return true }
        return false
    }

    // MARK: - 工具

    private func mask(_ value: String) -> String {
        guard value.count > 4 else { return "****" }
        return value.prefix(4) + "****"
    }
}
