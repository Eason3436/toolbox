import CryptoKit
import Foundation

enum SyncError: LocalizedError {
    case notConfigured
    case unauthorized
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "還沒設定同步伺服器網址和 Token。"
        case .unauthorized: "同步伺服器拒絕了 Token，請到設定重新貼上。"
        case .server(let code, let message): "同步伺服器錯誤 \(code)：\(message)"
        }
    }
}

/// 把逐字稿同步到自己的 Recap MCP 伺服器（Cloudflare Worker），讓 claude.ai 讀得到；
/// 再把 Claude 寫回的摘要／課堂筆記下載回來。
@MainActor
enum RecapSync {
    private static let defaults = UserDefaults.standard
    /// 已上傳內容的雜湊（id → hash），內容變了才重傳
    private static var uploaded: [String: String] {
        get { defaults.dictionary(forKey: "syncUploaded") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "syncUploaded") }
    }
    /// 全天錄音的 type 值：伺服器規格只寫了 class，先試 allday，被拒就換下一個並記住
    private static let allDayTypes = ["allday", "all_day", "segment", "day"]
    private static var allDayType: String {
        get { defaults.string(forKey: "syncAllDayType") ?? allDayTypes[0] }
        set { defaults.set(newValue, forKey: "syncAllDayType") }
    }

    static var lastSync: Date? { defaults.object(forKey: "syncLast") as? Date }
    static var lastError: String? { defaults.string(forKey: "syncError") }
    private static var running = false

    /// 上傳最近幾天有文字的錄音與課堂，下載 Claude 的回寫。
    @discardableResult
    static func run(days: Int = 7) async -> String {
        let settings = AppSettings.shared
        guard settings.canSync else { return SyncError.notConfigured.localizedDescription }
        guard !running else { return "同步中…" }
        running = true
        defer { running = false }
        let store = RecapStore.shared
        var sent = 0
        var pulled = 0
        do {
            for key in store.dayKeys.prefix(days) {
                let record = store.day(key)
                for segment in record.segments where segment.hasText && segment.status != .recorded {
                    if try await upload(body: segmentBody(segment, day: key), id: segment.id.uuidString, allDay: true) { sent += 1 }
                }
                for lecture in record.lectures where lecture.end != nil && !lecture.lines.isEmpty {
                    if try await upload(body: lectureBody(lecture, day: key), id: lecture.id.uuidString, allDay: false) { sent += 1 }
                }
                pulled += try await pullSummaries(day: key)
            }
            defaults.set(Date.now, forKey: "syncLast")
            defaults.removeObject(forKey: "syncError")
            let message = "已同步：上傳 \(sent) 筆，Claude 回寫 \(pulled) 筆。"
            appLog.info("\(message)")
            return message
        } catch {
            defaults.set(error.localizedDescription, forKey: "syncError")
            appLog.error("同步失敗：\(error.localizedDescription)")
            return "同步失敗：\(error.localizedDescription)"
        }
    }

    /// 只測連線與 Token
    static func test(url: String, token: String) async throws {
        _ = try await request("GET", path: "api/days", base: url, token: token)
    }

    // MARK: - 上傳

    private static func segmentBody(_ segment: Segment, day: String) -> [String: Any] {
        let text = segment.bestTranscript ?? ""
        var chunks: [[String: Any]]
        if let windows = segment.aligned, !windows.isEmpty, segment.correctedTranscript == nil {
            chunks = windows.enumerated().map { i, w in
                let end = i + 1 < windows.count ? windows[i + 1].offset : segment.duration
                return ["start": w.offset, "end": max(w.offset, end), "text": w.primary]
            }
        } else {
            // 一般錄音沒有逐句時間，整段當一塊
            chunks = [["start": 0, "end": segment.duration, "text": text]]
        }
        chunks = chunks.filter { !(($0["text"] as? String) ?? "").isEmpty }
        return [
            "id": segment.id.uuidString,
            "day": day,
            "type": allDayType,
            "class_name": NSNull(),
            "starts_at_ms": ms(segment.start),
            "ends_at_ms": ms(segment.end),
            "audio_object_key": NSNull(),
            "transcript": ["chunks": chunks, "plain_text": text],
        ]
    }

    private static func lectureBody(_ lecture: Lecture, day: String) -> [String: Any] {
        let end = lecture.end ?? lecture.start
        let total = end.timeIntervalSince(lecture.start)
        let lines = lecture.lines.sorted { $0.offset < $1.offset }
        let chunks: [[String: Any]] = lines.enumerated().map { i, line in
            let next = i + 1 < lines.count ? lines[i + 1].offset : total
            return ["start": line.offset, "end": max(line.offset, next), "text": line.source]
        }
        let name: String = {
            if let subject = lecture.subject, subject != .general { return subject.title }
            return lecture.displayTitle
        }()
        return [
            "id": lecture.id.uuidString,
            "day": day,
            "type": "class",
            "class_name": name,
            "starts_at_ms": ms(lecture.start),
            "ends_at_ms": ms(end),
            "audio_object_key": NSNull(),
            // 校正好的全文放 plain_text，Claude 讀這份最準
            "transcript": ["chunks": chunks, "plain_text": lecture.refinedTranscript ?? lecture.sourceText],
        ]
    }

    /// 內容沒變就不重傳；回傳是否真的有上傳
    private static func upload(body: [String: Any], id: String, allDay: Bool) async throws -> Bool {
        var hashed = body
        hashed["type"] = nil
        let data = try JSONSerialization.data(withJSONObject: hashed, options: [.sortedKeys])
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard uploaded[id] != hash else { return false }
        var payload = body
        do {
            _ = try await request("POST", path: "api/segments", json: payload)
        } catch SyncError.server(let code, _) where allDay && (code == 400 || code == 422) {
            // type 值不被接受：換下一個試
            var accepted = false
            for candidate in allDayTypes where candidate != allDayType {
                payload["type"] = candidate
                if (try? await request("POST", path: "api/segments", json: payload)) != nil {
                    allDayType = candidate
                    accepted = true
                    break
                }
            }
            guard accepted else { throw SyncError.server(code, "伺服器不接受全天錄音的 type") }
        }
        uploaded[id] = hash
        return true
    }

    // MARK: - 下載 Claude 的回寫

    private static func pullSummaries(day: String) async throws -> Int {
        let data = try await request("GET", path: "api/summaries", query: [URLQueryItem(name: "day", value: day)])
        let json = try JSONSerialization.jsonObject(with: data)
        let items: [[String: Any]] = (json as? [[String: Any]])
            ?? ((json as? [String: Any])?["summaries"] as? [[String: Any]])
            ?? ((json as? [String: Any])?["items"] as? [[String: Any]])
            ?? []
        let store = RecapStore.shared
        var count = 0
        for item in items {
            guard let markdown = (item["markdown"] ?? item["content"] ?? item["text"]) as? String, !markdown.isEmpty else { continue }
            let kind = item["kind"] as? String ?? ""
            let segmentID = (item["segment_id"] ?? item["session_id"]) as? String
            if let segmentID, let uuid = UUID(uuidString: segmentID) {
                if var lecture = store.lecture(uuid) {
                    if lecture.claudeNotes != markdown { lecture.claudeNotes = markdown; store.upsertLecture(lecture); count += 1 }
                } else if store.day(day).segments.contains(where: { $0.id == uuid }) {
                    var changed = false
                    store.updateSegment(uuid, in: day) {
                        if $0.claudeNotes != markdown { $0.claudeNotes = markdown; changed = true }
                    }
                    if changed { count += 1 }
                }
            } else if kind == "day" || segmentID == nil {
                if store.day(day).claudeRecap != markdown {
                    store.update(day) { $0.claudeRecap = markdown }
                    count += 1
                }
            }
        }
        return count
    }

    // MARK: - HTTP

    private static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    private static func request(_ method: String, path: String, query: [URLQueryItem] = [], json: [String: Any]? = nil,
                                base: String? = nil, token: String? = nil) async throws -> Data {
        let settings = AppSettings.shared
        let baseText = (base ?? settings.syncServerURL).trimmingCharacters(in: .whitespacesAndNewlines)
        let token = (token ?? settings.syncToken).trimmingCharacters(in: .whitespacesAndNewlines)
        // 使用者可能貼 …/mcp，去掉
        var root = baseText.hasSuffix("/") ? String(baseText.dropLast()) : baseText
        if root.hasSuffix("/mcp") { root = String(root.dropLast(4)) }
        guard !token.isEmpty, var components = URLComponents(string: root + "/" + path), components.scheme == "https" || components.host == "127.0.0.1" else {
            throw SyncError.notConfigured
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw SyncError.notConfigured }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
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
