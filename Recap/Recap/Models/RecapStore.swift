import Foundation
import Observation
import os

let appLog = Logger(subsystem: "com.eason3436.recap", category: "app")

/// 所有資料：每天一個 JSON 檔（Documents/Days），音檔在 Documents/Recordings。
@MainActor
@Observable
final class RecapStore {
    static let shared = RecapStore()

    private(set) var days: [String: DayRecord] = [:]

    let daysDirectory: URL
    let recordingsDirectory: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        daysDirectory = docs.appending(path: "Days", directoryHint: .isDirectory)
        recordingsDirectory = docs.appending(path: "Recordings", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: daysDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        loadAll()
    }

    /// 新的在前。
    var dayKeys: [String] { days.keys.sorted(by: >) }

    func day(_ key: String) -> DayRecord { days[key] ?? DayRecord(dayKey: key) }

    var allLectures: [Lecture] {
        days.values.flatMap(\.lectures).sorted { $0.start > $1.start }
    }

    // MARK: - 修改

    func update(_ key: String, _ change: (inout DayRecord) -> Void) {
        var record = day(key)
        change(&record)
        days[key] = record
        save(record)
    }

    func addSegment(_ segment: Segment) {
        update(DayKey.key(for: segment.start)) { $0.segments.append(segment); $0.segments.sort { $0.start < $1.start } }
    }

    func updateSegment(_ id: UUID, in key: String, _ change: (inout Segment) -> Void) {
        update(key) { record in
            guard let index = record.segments.firstIndex(where: { $0.id == id }) else { return }
            change(&record.segments[index])
        }
    }

    func upsertLecture(_ lecture: Lecture) {
        update(DayKey.key(for: lecture.start)) { record in
            if let index = record.lectures.firstIndex(where: { $0.id == lecture.id }) {
                record.lectures[index] = lecture
            } else {
                record.lectures.append(lecture)
                record.lectures.sort { $0.start < $1.start }
            }
        }
    }

    func lecture(_ id: UUID) -> Lecture? {
        for record in days.values {
            if let lecture = record.lectures.first(where: { $0.id == id }) { return lecture }
        }
        return nil
    }

    func deleteLecture(_ lecture: Lecture) {
        for part in lecture.audioParts { removeAudio(part.file) }
        SiriIndex.remove(lecture: lecture.id)
        update(DayKey.key(for: lecture.start)) { record in
            record.lectures.removeAll { $0.id == lecture.id }
        }
    }

    func deleteSegment(_ segment: Segment) {
        if let file = segment.audioFile { removeAudio(file) }
        update(DayKey.key(for: segment.start)) { record in
            record.segments.removeAll { $0.id == segment.id }
            record.recapDirty = true
        }
    }

    func deleteDay(_ key: String) {
        let record = day(key)
        for segment in record.segments { if let file = segment.audioFile { removeAudio(file) } }
        for lecture in record.lectures { for part in lecture.audioParts { removeAudio(part.file) } }
        days[key] = nil
        try? FileManager.default.removeItem(at: fileURL(for: key))
        try? FileManager.default.removeItem(at: recordingsDirectory.appending(path: key))
    }

    /// 刪除超過 N 天的錄音檔（全天錄音與課堂都算），只留文字稿與摘要。
    /// 還沒轉成文字的段落、還在上課的課堂不會刪。回傳刪掉的檔案數。
    @discardableResult
    func purgeAudio(olderThan days: Int) -> Int {
        guard days > 0 else { return 0 }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        var count = 0
        for key in dayKeys {
            let record = day(key)
            let hasOldSegment = record.segments.contains { $0.audioFile != nil && $0.end < cutoff && $0.status != .recorded }
            let hasOldLecture = record.lectures.contains { ($0.end ?? .distantFuture) < cutoff && !$0.audioParts.isEmpty }
            guard hasOldSegment || hasOldLecture else { continue }
            update(key) { record in
                for index in record.segments.indices {
                    let segment = record.segments[index]
                    guard let file = segment.audioFile, segment.end < cutoff, segment.status != .recorded else { continue }
                    removeAudio(file)
                    record.segments[index].audioFile = nil
                    count += 1
                }
                for index in record.lectures.indices {
                    guard let end = record.lectures[index].end, end < cutoff else { continue }
                    for part in record.lectures[index].audioParts {
                        removeAudio(part.file)
                        count += 1
                    }
                    record.lectures[index].audioParts = []
                }
            }
        }
        if count > 0 { appLog.info("已刪除 \(count) 個過期錄音檔") }
        return count
    }

    // MARK: - 音檔

    func audioURL(_ relative: String) -> URL { recordingsDirectory.appending(path: relative) }

    func removeAudio(_ relative: String) {
        try? FileManager.default.removeItem(at: audioURL(relative))
    }

    /// 新音檔的位置，例如 2026-11-04/093000-allDay.m4a
    nonisolated static func newAudioRelativePath(start: Date, tag: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HHmmss"
        return "\(DayKey.key(for: start))/\(f.string(from: start))-\(tag)-\(UUID().uuidString.prefix(4)).m4a"
    }

    var storageBytes: Int64 {
        guard let enumerator = FileManager.default.enumerator(at: recordingsDirectory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// 各類資料佔用的空間（給儲存空間頁的長條圖）
    struct StorageUsage: Sendable, Equatable {
        var allDayAudio: Int64 = 0
        var lectureAudio: Int64 = 0
        var text: Int64 = 0
        var memory: Int64 = 0
        var total: Int64 { allDayAudio + lectureAudio + text + memory }
    }

    func storageUsage() async -> StorageUsage {
        let lectureFiles = Set(days.values.flatMap { $0.lectures.flatMap { $0.audioParts.map(\.file) } })
        let recordings = recordingsDirectory
        let daysDir = daysDirectory
        return await Task.detached(priority: .utility) {
            var usage = StorageUsage()
            func size(_ url: URL) -> Int64 { Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            let base = recordings.standardizedFileURL.path
            if let e = FileManager.default.enumerator(at: recordings, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let url as URL in e {
                    var rel = url.standardizedFileURL.path
                    if rel.hasPrefix(base) { rel.removeFirst(base.count) }
                    while rel.hasPrefix("/") { rel.removeFirst() }
                    if lectureFiles.contains(rel) || rel.contains("import-") || rel.contains("lecture") {
                        usage.lectureAudio += size(url)
                    } else {
                        usage.allDayAudio += size(url)
                    }
                }
            }
            if let e = FileManager.default.enumerator(at: daysDir, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let url as URL in e { usage.text += size(url) }
            }
            let docs = daysDir.deletingLastPathComponent()
            usage.memory = size(docs.appending(path: "learned-terms.json"))
            return usage
        }.value
    }

    // MARK: - 讀寫

    private func fileURL(for key: String) -> URL { daysDirectory.appending(path: "\(key).json") }

    /// 還原備份後重新讀取所有紀錄。
    func reloadFromDisk() {
        days = [:]
        loadAll()
    }

    private func loadAll() {
        let files = (try? FileManager.default.contentsOfDirectory(at: daysDirectory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        for file in files where file.pathExtension == "json" {
            do {
                let record = try decoder.decode(DayRecord.self, from: Data(contentsOf: file))
                days[record.dayKey] = record
            } catch {
                appLog.error("讀取 \(file.lastPathComponent) 失敗：\(error.localizedDescription)")
            }
        }
    }

    private func save(_ record: DayRecord) {
        do {
            let data = try JSONEncoder().encode(record)
            try data.write(to: fileURL(for: record.dayKey), options: .atomic)
        } catch {
            appLog.error("儲存 \(record.dayKey) 失敗：\(error.localizedDescription)")
        }
    }
}
