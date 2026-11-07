import SwiftUI
import Charts

// MARK: - 折線圖（帳戶餘額、總資產）

struct RangeButtons: View {
    @Binding var range: PriceRange
    var body: some View {
        HStack(spacing: 6) {
            ForEach(PriceRange.allCases) { r in
                Button {
                    withAnimation(.snappy) { range = r }
                } label: {
                    Text(r.label)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(range == r ? Color(.tertiarySystemFill) : .clear, in: .capsule)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// 可拖曳查看數值的折線圖卡片
struct ValueLineCard: View {
    var title: String
    var points: [ValuePoint]
    var currency: String = Prefs.mainCurrency
    var hidden: Bool = false
    var loading: Bool = false
    /// 台股習慣：漲紅跌綠
    var risingRed: Bool = false
    @Binding var range: PriceRange

    @State private var selected: ValuePoint?

    var body: some View {
        let first = points.first?.value ?? 0
        let last = points.last?.value ?? 0
        let change = last - first
        let ratio = abs(first) > 0.005 ? change / abs(first) : nil
        let up = risingRed ? HeatColor.red : HeatColor.green
        let down = risingRed ? HeatColor.green : HeatColor.red
        let color: Color = change >= 0 ? up : down
        let lo = points.map(\.value).min() ?? 0
        let hi = points.map(\.value).max() ?? 1
        let pad = max((hi - lo) * 0.15, 1)

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selected.map { DateText.short($0.date) } ?? title)
                        .font(.headline)
                        .contentTransition(.opacity)
                    if let selected {
                        MoneyText(value: selected.value, currency: currency, hidden: hidden,
                                  font: .title3.weight(.semibold), rollsOnAppear: false)
                    } else {
                        HStack(spacing: 4) {
                            Text(Money.format(change, currency: currency, hidden: hidden, signed: true))
                            if let ratio { Text("(\(ratio >= 0 ? "+" : "")\(Money.percent(ratio, digits: 1)))") }
                        }
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(points.count > 1 ? color : .secondary)
                        .contentTransition(.numericText(value: change))
                    }
                }
                Spacer()
                if loading { ProgressView() }
            }
            .animation(.snappy, value: selected)

            Chart {
                ForEach(points) { p in
                    AreaMark(x: .value("日期", p.date), yStart: .value("低", lo - pad), yEnd: .value("值", p.value))
                        .foregroundStyle(LinearGradient(colors: [color.opacity(0.22), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("日期", p.date), y: .value("值", p.value))
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .interpolationMethod(.monotone)
                }
                if let s = selected {
                    RuleMark(x: .value("選取", s.date)).foregroundStyle(.secondary.opacity(0.5))
                    PointMark(x: .value("日期", s.date), y: .value("值", s.value)).foregroundStyle(color).symbolSize(80)
                } else if let l = points.last {
                    PointMark(x: .value("日期", l.date), y: .value("值", l.value)).foregroundStyle(color).symbolSize(60)
                }
            }
            .chartYScale(domain: (lo - pad)...(hi + pad))
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                    AxisValueLabel(format: .dateTime.month().day())
                }
            }
            .chartOverlay { proxy in
                Rectangle().fill(.clear).contentShape(.rect)
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            if let d = proxy.value(atX: g.location.x, as: Date.self) {
                                selected = points.min { abs($0.date.timeIntervalSince(d)) < abs($1.date.timeIntervalSince(d)) }
                            }
                        }
                        .onEnded { _ in withAnimation(.snappy) { selected = nil } })
            }
            .frame(height: 170)
            .opacity(points.count > 1 ? 1 : 0.3)
            .animation(.easeInOut(duration: 0.35), value: points)
            .sensoryFeedback(.selection, trigger: selected?.date)

            RangeButtons(range: $range)
        }
        .cardStyle()
    }
}

// MARK: - 分類圓餅圖

struct CategorySlice: Identifiable, Equatable {
    var id: String
    var name: String
    var color: Color
    var total: Double
}

/// 支出／收入的分類比例（甜甜圈圖）
struct CategoryDonutCard: View {
    var entries: [Entry]
    var currency: String = Prefs.mainCurrency
    var hidden: Bool = false
    var title: String = "分類比例"
    @Binding var income: Bool

    @State private var selectedAngle: Double?

    private var slices: [CategorySlice] {
        let kind: EntryKind = income ? .income : .expense
        let list = entries.filter { $0.kind == kind }
        let grouped = Dictionary(grouping: list) { $0.category?.main.id.uuidString ?? "none" }
        return grouped.map { key, items in
            let c = items.first?.category?.main
            return CategorySlice(id: key, name: c?.name ?? "未分類", color: c?.color ?? .gray,
                                 total: items.reduce(0) { $0 + $1.amount })
        }
        .sorted { $0.total > $1.total }
    }

    var body: some View {
        let data = slices
        let total = data.reduce(0) { $0 + $1.total }
        let picked = pickedSlice(data)

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Picker("", selection: $income) {
                    Text("支出").tag(false)
                    Text("收入").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 130)
            }

            if data.isEmpty {
                Text(income ? "這段期間沒有收入" : "這段期間沒有支出")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                HStack(spacing: 18) {
                    Chart(data) { s in
                        SectorMark(angle: .value("金額", s.total), innerRadius: .ratio(0.62), angularInset: 1.5)
                            .cornerRadius(4)
                            .foregroundStyle(s.color)
                            .opacity(picked == nil || picked?.id == s.id ? 1 : 0.35)
                    }
                    .chartAngleSelection(value: $selectedAngle)
                    .chartBackground { _ in
                        VStack(spacing: 2) {
                            Text(picked?.name ?? (income ? "總收入" : "總支出"))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            MoneyText(value: picked?.total ?? total, currency: currency, hidden: hidden,
                                      font: .subheadline.weight(.bold), rollsOnAppear: false)
                                .lineLimit(1).minimumScaleFactor(0.6)
                        }
                        .padding(.horizontal, 22)
                    }
                    .frame(width: 150, height: 150)
                    .sensoryFeedback(.selection, trigger: picked?.id)

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(data.prefix(6)) { s in
                            HStack(spacing: 8) {
                                Circle().fill(s.color).frame(width: 9, height: 9)
                                Text(s.name).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(Money.percent(total > 0 ? s.total / total : 0))
                                    .monospacedDigit().foregroundStyle(.secondary)
                            }
                            .font(.subheadline)
                            .opacity(picked == nil || picked?.id == s.id ? 1 : 0.4)
                        }
                        if data.count > 6 {
                            Text("其他 \(data.count - 6) 類").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .animation(.snappy, value: picked?.id)
            }
        }
        .cardStyle()
        .animation(.snappy, value: income)
    }

    private func pickedSlice(_ data: [CategorySlice]) -> CategorySlice? {
        guard let a = selectedAngle else { return nil }
        var acc = 0.0
        for s in data {
            acc += s.total
            if a <= acc { return s }
        }
        return nil
    }
}
