import SwiftUI
import SwiftData
import Charts

struct StatsView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Entry.date, order: .reverse) private var entries: [Entry]
    @AppStorage(Prefs.hideAmountsKey) private var hidden = false
    @State private var yearly = false
    @State private var anchor = Date.now
    @State private var selectedAngle: Double?

    private let cal = Calendar.current

    private var interval: DateInterval {
        cal.dateInterval(of: yearly ? .year : .month, for: anchor)!
    }

    private struct CatTotal: Identifiable {
        var id: String
        var name: String
        var color: Color
        var total: Double
    }

    var body: some View {
        let iv = interval
        let inRange = entries.filter { iv.contains($0.date) && $0.kind != .transfer }
        let expenses = inRange.filter { $0.kind == .expense }
        let expense = expenses.reduce(0) { $0 + $1.amount }
        let income = inRange.filter { $0.kind == .income }.reduce(0) { $0 + $1.amount }
        let cats: [CatTotal] = Dictionary(grouping: expenses) { $0.category?.main.id.uuidString ?? "none" }
            .map { k, v in
                let c = v.first?.category?.main
                return CatTotal(id: k, name: c?.name ?? "未分類", color: c?.color ?? .gray, total: v.reduce(0) { $0 + $1.amount })
            }
            .sorted { $0.total > $1.total }
        let selectedCat = selectedCategory(cats)
        let merchants = Dictionary(grouping: expenses) { $0.title }
            .filter { !PayMethod.isPayMethod($0.key) && $0.key != "未命名" }
            .map { (name: $0.key, total: $0.value.reduce(0) { $0 + $1.amount }, count: $0.value.count) }
            .sorted { $0.total > $1.total }
            .prefix(8)
        let buckets = buildBuckets(inRange)
        let trend = (0..<6).reversed().map { i -> (Date, Double, Double) in
            let d = cal.date(byAdding: .month, value: -i, to: anchor)!
            let m = DateText.monthInterval(d)
            let es = entries.filter { m.contains($0.date) }
            return (m.start, es.filter { $0.kind == .expense }.reduce(0) { $0 + $1.amount }, es.filter { $0.kind == .income }.reduce(0) { $0 + $1.amount })
        }

        ScrollView {
            VStack(spacing: 16) {
                NavigationLink { SpendingInsightView() } label: {
                    Label("消費分析", systemImage: "chart.bar.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                .buttonStyle(.glass)
                Picker("", selection: $yearly.animation(.snappy)) {
                    Text("月").tag(false)
                    Text("年").tag(true)
                }
                .pickerStyle(.segmented)

                HStack {
                    Button { withAnimation(.snappy) { anchor = cal.date(byAdding: yearly ? .year : .month, value: -1, to: anchor)! } } label: {
                        Image(systemName: "chevron.left").frame(width: 40, height: 40)
                    }
                    Spacer()
                    Text(title).font(.headline).contentTransition(.numericText())
                    Spacer()
                    Button { withAnimation(.snappy) { anchor = cal.date(byAdding: yearly ? .year : .month, value: 1, to: anchor)! } } label: {
                        Image(systemName: "chevron.right").frame(width: 40, height: 40)
                    }
                }
                .padding(.horizontal, 8)
                .glassEffect(.regular.interactive(), in: .capsule)

                HStack(spacing: 12) {
                    tile("支出", expense, .red)
                    tile("收入", income, .green)
                    tile("結餘", income - expense, income >= expense ? .green : .red)
                }

                // 分類圓餅
                VStack(alignment: .leading, spacing: 12) {
                    Text("支出分類").font(.headline)
                    if cats.isEmpty {
                        Text("沒有支出").foregroundStyle(.secondary)
                    } else {
                        ZStack {
                            Chart(cats) { c in
                                SectorMark(angle: .value("金額", c.total), innerRadius: .ratio(0.62), outerRadius: selectedCat?.id == c.id ? .ratio(1) : .ratio(0.92), angularInset: 1.5)
                                    .foregroundStyle(c.color)
                                    .cornerRadius(5)
                                    .opacity(selectedCat == nil || selectedCat?.id == c.id ? 1 : 0.4)
                            }
                            .chartAngleSelection(value: $selectedAngle)
                            .frame(height: 230)
                            VStack(spacing: 2) {
                                Text(selectedCat?.name ?? "總支出").font(.subheadline).foregroundStyle(.secondary)
                                Text(Money.format(selectedCat?.total ?? expense, hidden: hidden))
                                    .font(.title2.weight(.bold)).monospacedDigit()
                                    .contentTransition(.numericText())
                            }
                            .animation(.snappy, value: selectedCat?.id)
                        }
                        ForEach(cats) { c in
                            HStack {
                                Circle().fill(c.color).frame(width: 10, height: 10)
                                Text(c.name)
                                Spacer()
                                Text(Money.percent(c.total / max(expense, 1))).foregroundStyle(.secondary).monospacedDigit()
                                Text(Money.format(c.total, hidden: hidden)).monospacedDigit().frame(minWidth: 70, alignment: .trailing)
                            }
                            .font(.subheadline)
                        }
                    }
                }
                .cardStyle()

                // 每日／每月支出
                VStack(alignment: .leading, spacing: 12) {
                    Text(yearly ? "每月支出" : "每日支出").font(.headline)
                    Chart(buckets, id: \.0) { b in
                        BarMark(x: .value("日期", b.0, unit: yearly ? .month : .day), y: .value("支出", b.1))
                            .foregroundStyle(Color.red.gradient)
                            .cornerRadius(3)
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                            AxisGridLine()
                            AxisValueLabel(format: yearly ? .dateTime.month(.narrow) : .dateTime.day())
                        }
                    }
                    .frame(height: 180)
                }
                .cardStyle()

                // 近 6 個月收支
                VStack(alignment: .leading, spacing: 12) {
                    Text("近 6 個月").font(.headline)
                    Chart {
                        ForEach(trend, id: \.0) { t in
                            LineMark(x: .value("月", t.0, unit: .month), y: .value("金額", t.1), series: .value("類型", "支出"))
                                .foregroundStyle(.red)
                                .symbol(.circle)
                                .interpolationMethod(.catmullRom)
                            LineMark(x: .value("月", t.0, unit: .month), y: .value("金額", t.2), series: .value("類型", "收入"))
                                .foregroundStyle(.green)
                                .symbol(.circle)
                                .interpolationMethod(.catmullRom)
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .month)) { _ in
                            AxisValueLabel(format: .dateTime.month(.abbreviated))
                        }
                    }
                    .frame(height: 180)
                }
                .cardStyle()

                if !merchants.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("最常花錢的地方").font(.headline)
                        ForEach(Array(merchants.enumerated()), id: \.offset) { i, m in
                            HStack {
                                Text("\(i + 1)").font(.caption.weight(.bold)).foregroundStyle(.secondary).frame(width: 20)
                                Text(m.name).lineLimit(1)
                                Text("\(m.count) 次").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text(Money.format(m.total, hidden: hidden)).monospacedDigit()
                            }
                            .font(.subheadline)
                        }
                    }
                    .cardStyle()
                }
            }
            .padding()
        }
        .background(Palette.background)
        .navigationTitle("統計")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } }
        }
    }

    private var title: String {
        let c = cal.dateComponents([.year, .month], from: anchor)
        return yearly ? "\(String(c.year ?? 2026))年" : "\(String(c.year ?? 2026))年\(c.month ?? 1)月"
    }

    private func tile(_ title: String, _ v: Double, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            MoneyText(value: v, hidden: hidden, font: .headline).foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(padding: 14)
    }

    private func selectedCategory(_ cats: [CatTotal]) -> CatTotal? {
        guard let a = selectedAngle else { return nil }
        var acc = 0.0
        for c in cats {
            acc += c.total
            if a <= acc { return c }
        }
        return nil
    }

    private func buildBuckets(_ list: [Entry]) -> [(Date, Double)] {
        let unit: Calendar.Component = yearly ? .month : .day
        var dict: [Date: Double] = [:]
        for e in list where e.kind == .expense {
            let k = cal.dateInterval(of: unit, for: e.date)!.start
            dict[k, default: 0] += e.amount
        }
        return dict.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
    }
}
