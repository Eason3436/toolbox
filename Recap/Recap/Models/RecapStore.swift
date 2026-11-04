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
        update(DayKey.key(for: lecture.start)) { record in
            record.lectures.removeAll { $0.id == lecture.id }
            record.recapDirty = true
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

    /// 刪除 N 天前全天錄音的音檔（文字與摘要保留）。
    func deleteAllDayAudio(olderThan days: Int) -> Int {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: .now) ?? .now
        var count = 0
        for key in dayKeys {
            guard let date = DayKey.date(from: key), date < cutoff else { continue }
            update(key) { record in
                for index in record.segments.indices {
                    if let file = record.segments[index].audioFile {
                        removeAudio(file)
                        record.segments[index].audioFile = nil
                        count += 1
                    }
                }
            }
        }
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

    // MARK: - 讀寫

    private func fileURL(for key: String) -> URL { daysDirectory.appending(path: "\(key).json") }

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
