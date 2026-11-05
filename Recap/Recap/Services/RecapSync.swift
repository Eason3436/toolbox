import CryptoKit
import Foundation
import Security

enum SyncError: LocalizedError {
    case notConfigured
    case unauthorized
    case claimedByOther
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "還沒連上 Supabase。"
        case .unauthorized: "Supabase 拒絕了這支手機（Token 不符），請到設定重新連線。"
        case .claimedByOther: "這個 Supabase 專案已經綁定別的裝置。要重新綁定，請 Claude 清空 recap_owner 資料表後再連一次。"
        case .server(let code, let message): "Supabase 錯誤 \(code)：\(message)"
        }
    }
}

/// 把逐字稿與 AI 摘要同步到使用者自己的 Supabase，claude.ai 用官方 Supabase 連接器讀取；
/// Claude 寫進 claude_notes 的筆記再下載回 App。
/// 權限：每個請求帶 x-recap-token，資料表的 RLS 只讓持有這個 Token 的人讀寫。
@MainActor
enum RecapSync {
    private static let defaults = UserDefaults.standard
    /// 已上傳內容的雜湊（id → hash），內容變了才重傳
    private static var uploaded: [String: String] {
        get { defaults.dictionary(forKey: "syncUploaded") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "syncUploaded") }
    }

    static var lastSync: Date? { defaults.object(forKey: "syncLast") as? Date }
    static var lastError: String? { defaults.string(forKey: "syncError") }
    private static var running = false

    // MARK: - 連線（第一次綁定）

    /// 產生私人 Token，向專案「認領」；認領過的專案只接受同一個 Token。
    static func connect(url: String, apiKey: String) async throws {
        let settings = AppSettings.shared
        let token = settings.syncToken.isEmpty ? randomToken() : settings.syncToken
        let data = try await request("POST", path: "rpc/recap_claim", json: ["token": token], url: url, apiKey: apiKey, token: token)
        let ok = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        guard ok else { throw SyncError.claimedByOther }
        settings.syncServerURL = url
        settings.syncAPIKey = apiKey
        settings.syncToken = token
        settings.syncEnabled = true
        uploaded = [:]
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 同步

    /// 上傳最近幾天有文字的錄音與課堂，下載 Claude 的筆記。
    @discardableResult
    static func run(days: Int = 7) async -> String {
        let settings = AppSettings.shared
        guard settings.canSync else { return SyncError.notConfigured.localizedDescription }
        guard !running else { return "同步中…" }
        running = true
        defer { running = false }
        let store = RecapStore.shared
        do {
            var rows: [[String: Any]] = []
            var hashes: [String: String] = [:]
            for key in store.dayKeys.prefix(days) {
                let record = store.day(key)
                for segment in record.segments where segment.hasText && segment.status != .recorded {
                    rows.append(segmentRow(segment, day: key))
                }
                for lecture in record.lectures where lecture.end != nil && !lecture.lines.isEmpty {
                    rows.append(lectureRow(lecture, day: key))
                }
            }
            let known = uploaded
            rows = rows.filter { row in
                let id = row["id"] as? String ?? ""
                let hash = hashOf(row)
                hashes[id] = hash
                return known[id] != hash
            }
            // 一次最多 50 筆
            var start = 0
            while start < rows.count {
                let batch = Array(rows[start..<min(rows.count, start + 50)])
                _ = try await request("POST", path: "recap_items?on_conflict=id", jsonArray: batch,
                                      prefer: "resolution=merge-duplicates,return=minimal")
                var done = uploaded
                for row in batch { if let id = row["id"] as? String { done[id] = hashes[id] } }
                uploaded = done
                start += 50
            }
            let pulled = try await pullNotes()
            defaults.set(Date.now, forKey: "syncLast")
            defaults.removeObject(forKey: "syncError")
            let message = "已同步：上傳 \(rows.count) 筆，Claude 筆記 \(pulled) 筆更新。"
            appLog.info("\(message)")
            return message
        } catch {
            defaults.set(error.localizedDescription, forKey: "syncError")
            appLog.error("同步失敗：\(error.localizedDescription)")
            return "同步失敗：\(error.localizedDescription)"
        }
    }

    private static func hashOf(_ row: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func segmentRow(_ segment: Segment, day: String) -> [String: Any] {
        [
            "id": segment.id.uuidString,
            "kind": "segment",
            "day": day,
            "starts_at": iso.string(from: segment.start),
            "ends_at": iso.string(from: segment.end),
            "title": segment.title.map { $0 as Any } ?? NSNull(),
            "subject": NSNull(),
            "transcript": segment.bestTranscript ?? "",
            "ai_points": segment.points,
            "exam_points": [String](),
            "todos": segment.todos,
        ]
    }

    private static func lectureRow(_ lecture: Lecture, day: String) -> [String: Any] {
        let subject: Any = {
            guard let subject = lecture.subject, subject != .general else { return NSNull() }
            return subject.title
        }()
        return [
            "id": lecture.id.uuidString,
            "kind": "lecture",
            "day": day,
            "starts_at": iso.string(from: lecture.start),
            "ends_at": iso.string(from: lecture.end ?? lecture.start),
            "title": lecture.displayTitle,
            "subject": subject,
            // 校正好的全文 Claude 讀起來最準
            "transcript": lecture.refinedTranscript ?? lecture.sourceText,
            "ai_points": lecture.summary?.keyPoints ?? [],
            "exam_points": lecture.summary?.examPoints ?? [],
            "todos": lecture.summary?.todos ?? [],
        ]
    }

    // MARK: - 下載 Claude 的筆記

    private static func pullNotes() async throws -> Int {
        let since = defaults.string(forKey: "syncNotesSince") ?? "1970-01-01T00:00:00Z"
        let path = "claude_notes?select=target,item_id,day,markdown,updated_at&order=updated_at.asc&updated_at=gt.\(since.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? since)"
        let data = try await request("GET", path: path)
        guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return 0 }
        let store = RecapStore.shared
        var count = 0
        var newest = since
        for item in items {
            if let updated = item["updated_at"] as? String, updated > newest { newest = updated }
            guard let markdown = item["markdown"] as? String, !markdown.isEmpty else { continue }
            if let itemID = item["item_id"] as? String, let uuid = UUID(uuidString: itemID) {
                if var lecture = store.lecture(uuid) {
                    lecture.claudeNotes = markdown
                    store.upsertLecture(lecture)
                    count += 1
                } else if let key = store.dayKeys.first(where: { store.day($0).segments.contains { $0.id == uuid } }) {
                    store.updateSegment(uuid, in: key) { $0.claudeNotes = markdown }
                    count += 1
                }
            } else if let day = item["day"] as? String {
                store.update(day) { $0.claudeRecap = markdown }
                count += 1
            }
        }
        defaults.set(newest, forKey: "syncNotesSince")
        return count
    }

    // MARK: - HTTP（Supabase REST）

    private static func request(_ method: String, path: String, json: [String: Any]? = nil, jsonArray: [[String: Any]]? = nil,
                                prefer: String? = nil, url: String? = nil, apiKey: String? = nil, token: String? = nil) async throws -> Data {
        let settings = AppSettings.shared
        var root = (url ?? settings.syncServerURL).trimmingCharacters(in: .whitespacesAndNewlines)
        while root.hasSuffix("/") { root.removeLast() }
        if root.hasSuffix("/rest/v1") { root = String(root.dropLast(8)) }
        let key = (apiKey ?? settings.syncAPIKey).trimmingCharacters(in: .whitespacesAndNewlines)
        let token = token ?? settings.syncToken
        guard !key.isEmpty, !token.isEmpty, let endpoint = URL(string: root + "/rest/v1/" + path), endpoint.scheme == "https" else {
            throw SyncError.notConfigured
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue(key, forHTTPHeaderField: "apikey")
        // 新版 publishable key（sb_publishable_…）不是 JWT，不能放 Authorization
        if !key.hasPrefix("sb_") { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.setValue(token, forHTTPHeaderField: "x-recap-token")
        if let prefer { request.setValue(prefer, forHTTPHeaderField: "Prefer") }
        if json != nil || jsonArray != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json ?? jsonArray ?? [])
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return data
        case 401, 403: throw SyncError.unauthorized
        default: throw SyncError.server(status, String(data: data.prefix(300), encoding: .utf8) ?? "")
        }
    }
}
