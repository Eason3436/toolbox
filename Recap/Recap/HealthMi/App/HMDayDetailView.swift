import SwiftData
import SwiftUI

/// 單日詳情頁面：展示某天的所有健康資料。
struct HMDayDetailView: View {
    let trend: DailyTrend
    let stressRecords: [StressRecord]

    private var dayStressRecords: [StressRecord] {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: trend.date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        return stressRecords.filter { $0.timestamp >= dayStart && $0.timestamp < dayEnd }
    }

    private var avgStress: Double? {
        guard !dayStressRecords.isEmpty else { return nil }
        return Double(dayStressRecords.map(\.stressScore).reduce(0, +)) / Double(dayStressRecords.count)
    }

    var body: some View {
        List {
            Section("概覽") {
                dataRow("步數", trend.stepCount.map { "\(Int($0)) 步" })
                dataRow("平均心率", trend.avgHeartRate.map { String(format: "%.0f 次/分", $0) })
                dataRow("睡眠", trend.sleepMinutes.map { String(format: "%.1f 小時", $0 / 60) })
                dataRow("平均 HRV", trend.avgHRV.map { String(format: "%.0f ms", $0) })
                dataRow("平均壓力", avgStress.map { String(format: "%.0f", $0) })
            }

            if !dayStressRecords.isEmpty {
                Section("壓力記錄") {
                    ForEach(dayStressRecords, id: \.persistentModelID) { record in
                        LabeledContent(
                            record.timestamp.formatted(date: .omitted, time: .shortened),
                            value: "\(record.stressScore)"
                        )
                    }
                }
            }
        }
        .navigationTitle(trend.date.formatted(date: .abbreviated, time: .omitted))
    }

    private func dataRow(_ title: String, _ value: String?) -> some View {
        LabeledContent(title) {
            if let value {
                Text(value).foregroundStyle(.primary)
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        }
    }
}
