import Foundation
import SwiftData
import SwiftUI

/// 資料匯出：按天彙總最近 N 天資料，生成 CSV。
enum DataExporter {
    /// 匯出最近 N 天的每日資料為 CSV 字串。
    static func exportCSV(days: Int, trends: [DailyTrend], stressRecords: [StressRecord]) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = .current

        var lines: [String] = []
        // CSV 表頭
        lines.append("日期,步數,平均心率,睡眠分鐘,平均HRV(ms),平均壓力")
        // 按天合併壓力資料
        let stressByDay = Dictionary(grouping: stressRecords, by: {
            Calendar.current.startOfDay(for: $0.timestamp)
        }).mapValues { records in
            Double(records.map(\.stressScore).reduce(0, +)) / Double(records.count)
        }

        for trend in trends.sorted(by: { $0.date < $1.date }) {
            let dateStr = dateFormatter.string(from: trend.date)
            let steps = trend.stepCount.map { Int($0) }.map(String.init) ?? ""
            let hr = trend.avgHeartRate.map { String(format: "%.0f", $0) } ?? ""
            let sleep = trend.sleepMinutes.map { String(format: "%.0f", $0) } ?? ""
            let hrv = trend.avgHRV.map { String(format: "%.0f", $0) } ?? ""
            let stress = stressByDay[Calendar.current.startOfDay(for: trend.date)].map { String(format: "%.0f", $0) } ?? ""
            lines.append("\(dateStr),\(steps),\(hr),\(sleep),\(hrv),\(stress)")
        }
        return lines.joined(separator: "\n")
    }

    /// 將 CSV 寫入臨時檔案，返回檔案 URL。
    static func writeCSV(_ csv: String, filename: String = "HealthMi_Export.csv") -> URL? {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(filename)
        do {
            try csv.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL
        } catch {
            return nil
        }
    }
}
