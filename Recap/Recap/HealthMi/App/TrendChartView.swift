import Charts
import SwiftUI

/// 單項趨勢小圖（步數/心率/睡眠/HRV）。
struct TrendChartView: View {
    let title: String
    let unit: String
    let values: [(date: Date, value: Double)]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let latest = values.last?.value {
                    Text(String(format: "%.0f %@", latest, unit))
                        .font(.caption)
                        .foregroundStyle(.primary)
                }
            }
            Chart(values, id: \.date) { item in
                LineMark(
                    x: .value("日期", item.date, unit: .day),
                    y: .value(title, item.value)
                )
                .foregroundStyle(.tint)
                .interpolationMethod(.monotone)
                PointMark(
                    x: .value("日期", item.date, unit: .day),
                    y: .value(title, item.value)
                )
                .foregroundStyle(.tint)
                .symbolSize(12)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { value in
                    if let date = value.as(Date.self) {
                        AxisValueLabel {
                            Text(date, format: .dateTime.day())
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading)
            }
            .frame(height: 120)
        }
    }
}

/// 7 天趨勢圖表區域。
struct TrendChartsSection: View {
    @Environment(HMAppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            TrendChartView(
                title: "步數", unit: "步",
                values: model.trends.compactMap { t in
                    guard let s = t.stepCount else { return nil }
                    return (t.date, s)
                }
            )
            TrendChartView(
                title: "心率", unit: "bpm",
                values: model.trends.compactMap { t in
                    guard let hr = t.avgHeartRate else { return nil }
                    return (t.date, hr)
                }
            )
            TrendChartView(
                title: "睡眠", unit: "分鐘",
                values: model.trends.compactMap { t in
                    guard let s = t.sleepMinutes else { return nil }
                    return (t.date, s)
                }
            )
            TrendChartView(
                title: "HRV", unit: "ms",
                values: model.trends.compactMap { t in
                    guard let h = t.avgHRV else { return nil }
                    return (t.date, h)
                }
            )
        }
    }
}
