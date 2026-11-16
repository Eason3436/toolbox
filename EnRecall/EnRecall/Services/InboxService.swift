import Foundation
import SwiftData
import Observation

/// Claude 連接器：配對碼註冊、從收件匣領字。網路失敗一律安靜略過，下次打開 App 再試
@MainActor
@Observable
final class InboxService {
    enum Status: Equatable {
        case notConfigured
        case idle
        case syncing
        case connected
        case offline
    }

    private(set) var code: String?
    private(set) var status: Status
    private(set) var lastCheck: Date?
    private let isPreview: Bool
    private var lastAttempt: Date?

    init() {
        isPreview = false
        status = AppConfig.isBackendConfigured ? .idle : .notConfigured
        guard AppConfig.isBackendConfigured else { return }
        if let saved = PairingCodeStore.load() {
            code = saved
        } else {
            let fresh = PairingCodeStore.generate()
            PairingCodeStore.save(fresh)
            code = fresh
        }
    }

    /// 預覽用：不碰 Keychain 和網路
    init(previewCode: String?) {
        isPreview = true
        code = previewCode
        status = previewCode == nil ? .notConfigured : .connected
        lastCheck = previewCode == nil ? nil : Date().addingTimeInterval(-120)
    }

    var connectorURL: URL? {
        guard let code else { return nil }
        if isPreview {
            return URL(string: "https://example.supabase.co/functions/v1/enrecall-mcp/\(code)")
        }
        return AppConfig.connectorURL(code: code)
    }

    // MARK: 同步

    /// 註冊配對碼（順便更新 last_seen）→ 領取收件匣 → 匯入。
    /// 領取的同時伺服器就刪掉了，所以先寫進本機暫存檔，匯入存檔成功才清掉
    func sync(context: ModelContext, force: Bool = false) async -> ImportResult? {
        guard !isPreview, !AppConfig.isRunningTests, AppConfig.isBackendConfigured, let code, status != .syncing else { return nil }
        if !force, let lastAttempt, Date().timeIntervalSince(lastAttempt) < 15 { return nil }
        lastAttempt = Date()
        status = .syncing

        var result = ImportResult()
        // 上次領了但沒匯入成功的（例如匯入到一半 App 被關掉）
        if let imported = try? importPending(context: context) {
            result.merge(imported)
        }

        do {
            try await SupabaseRPC.call("ios_register_device", code: code)
            let data = try await SupabaseRPC.call("ios_claim_inbox", code: code)
            let items = try JSONDecoder().decode([InboxItem].self, from: data)
            if !items.isEmpty {
                PendingInbox.save(items)
                if let imported = try importPending(context: context) {
                    result.merge(imported)
                }
            }
            status = .connected
            lastCheck = Date()
        } catch {
            status = .offline
        }
        return result
    }

    private func importPending(context: ModelContext) throws -> ImportResult? {
        guard let pending = PendingInbox.load(), !pending.isEmpty else { return nil }
        let imported = try InboxImporter.importItems(pending, into: context)
        PendingInbox.clear()
        return imported
    }

    // MARK: 學習紀錄

    /// 上次上傳的時間（成功才記）
    private(set) var lastUpload: Date?
    private var isUploading = false

    /// 把學習紀錄（牌組、學過的卡、最近 90 天的複習）傳給後端，Claude 的連接器才看得到成效。
    /// 預設 10 分鐘內不重傳；複習完關掉時用 force。後端還沒有這個 RPC 時安靜失敗
    func uploadSnapshot(context: ModelContext, force: Bool = false) async {
        guard !isPreview, !AppConfig.isRunningTests, AppConfig.isBackendConfigured, let code, !isUploading else { return }
        guard UserDefaults.standard.object(forKey: SettingsKey.shareStats) as? Bool ?? true else { return }
        if !force, let lastUpload, Date().timeIntervalSince(lastUpload) < 600 { return }
        isUploading = true
        defer { isUploading = false }
        do {
            let snapshot = try StudySnapshot.make(context: context)
            let body = try StudySnapshot.requestBody(code: code, snapshot: snapshot)
            try await SupabaseRPC.call("ios_push_snapshot", body: body)
            lastUpload = Date()
        } catch {
            // 下次再試
        }
    }

    /// 換一組新的配對碼：舊的網址立刻失效
    func regenerate() async -> Bool {
        guard !isPreview, AppConfig.isBackendConfigured else { return false }
        let fresh = PairingCodeStore.generate()
        do {
            if let old = code {
                try await SupabaseRPC.call("ios_unregister_device", code: old)
            }
            try await SupabaseRPC.call("ios_register_device", code: fresh)
        } catch {
            status = .offline
            return false
        }
        PairingCodeStore.save(fresh)
        code = fresh
        status = .connected
        lastCheck = Date()
        return true
    }
}

// MARK: - Supabase RPC（只用 URLSession，不加 supabase-swift）

enum SupabaseRPC {
    @discardableResult
    static func call(_ function: String, code: String) async throws -> Data {
        try await call(function, body: try JSONEncoder().encode(["p_code": code]))
    }

    /// body：RPC 參數的 JSON（例如 {"p_code": …, "p_payload": {…}}）
    @discardableResult
    static func call(_ function: String, body: Data) async throws -> Data {
        guard let base = AppConfig.supabaseURL else { throw URLError(.badURL) }
        var request = URLRequest(url: base.appending(path: "rest/v1/rpc/\(function)"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(AppConfig.supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

// MARK: - 已領取、還沒匯入的暫存

enum PendingInbox {
    private static var url: URL {
        URL.applicationSupportDirectory.appending(path: "inbox-pending.json")
    }

    static func load() -> [InboxItem]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([InboxItem].self, from: data)
    }

    static func save(_ items: [InboxItem]) {
        var all = load() ?? []
        all.append(contentsOf: items)
        try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(all).write(to: url, options: .atomic)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
