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
                GeometryReader { geo in
                    let plot = proxy.plotFrame.map { geo[$0] } ?? .zero
                    ZStack(alignment: .topLeading) {
                        Rectangle().fill(.clear).contentShape(.rect)
                            .gesture(DragGesture(minimumDistance: 0)
                                .onChanged { g in
                                    let x = g.location.x - plot.minX
                                    if let d = proxy.value(atX: x, as: Date.self) {
                                        selected = points.min { abs($0.date.timeIntervalSince(d)) < abs($1.date.timeIntervalSince(d)) }
                                    }
                                }
                                .onEnded { _ in withAnimation(.easeOut(duration: 0.2)) { selected = nil } })
                        // 圓點畫在圖表外層：放手時在原地縮小消失，最後一點的圓點原地出現，不會飛來飛去
                        if let s = selected, let pos = chartPoint(of: s, proxy: proxy, plot: plot) {
                            ChartDot(color: color, size: 13).position(pos)
                                .transition(.scale(scale: 0.3).combined(with: .opacity))
                                .id("sel")
                        } else if let l = points.last, let pos = chartPoint(of: l, proxy: proxy, plot: plot) {
                            ChartDot(color: color, size: 10).position(pos)
                                .transition(.scale(scale: 0.3).combined(with: .opacity))
                                .id("last")
                        }
                    }
                    .allowsHitTesting(true)
                }
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

private func chartPoint(of p: ValuePoint, proxy: ChartProxy, plot: CGRect) -> CGPoint? {
    guard let x = proxy.position(forX: p.date), let y = proxy.position(forY: p.value) else { return nil }
    return CGPoint(x: plot.minX + x, y: plot.minY + y)
}

/// 折線圖上的小圓點（白邊）
struct ChartDot: View {
    var color: Color
    var size: CGFloat
    var body: some View {
        Circle().fill(color)
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
            .shadow(color: color.opacity(0.4), radius: 4)
            .allowsHitTesting(false)
    }
}

// MARK: - 分類圓餅圖

struct CategorySlice: Identifiable, Equatable {
    var id: String
    var name: String
    var symbol: String = "tag.fill"
    var color: Color
    var total: Double
    var count: Int = 0
}

/// 支出／收入的分類比例（甜甜圈圖）。點一塊會凸出來，下面顯示子分類和交易
struct CategoryDonutCard: View {
    var entries: [Entry]
    var currency: String = Prefs.mainCurrency
    var hidden: Bool = false
    var title: String = "分類比例"
    @Binding var income: Bool

    @State private var selectedID: String?
    @State private var showAllTx = false
    @State private var opened: Entry?

    private var kindEntries: [Entry] {
        let kind: EntryKind = income ? .income : .expense
        return entries.filter { $0.kind == kind }
    }

    private static func key(_ e: Entry) -> String { e.category?.main.id.uuidString ?? "none" }

    private var slices: [CategorySlice] {
        let grouped = Dictionary(grouping: kindEntries) { Self.key($0) }
        return grouped.map { key, items in
            let c = items.first?.category?.main
            return CategorySlice(id: key, name: c?.name ?? "未分類", symbol: c?.symbol ?? "questionmark",
                                 color: c?.color ?? .gray,
                                 total: items.reduce(0) { $0 + $1.amount }, count: items.count)
        }
        .sorted { $0.total > $1.total }
    }

    var body: some View {
        let data = slices
        let total = data.reduce(0) { $0 + $1.total }
        let picked = data.first { $0.id == selectedID }

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
                donut(data, total: total, picked: picked)
                    .frame(height: 230)
                    .frame(maxWidth: .infinity)

                legend(data, total: total, picked: picked)

                if let picked {
                    CategoryBreakdown(slice: picked, share: total > 0 ? picked.total / total : 0,
                                      entries: kindEntries.filter { Self.key($0) == picked.id },
                                      income: income, currency: currency, hidden: hidden,
                                      showAll: $showAllTx, opened: $opened) {
                        select(nil)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .cardStyle()
        .animation(.snappy, value: income)
        .animation(.spring(duration: 0.4, bounce: 0.25), value: selectedID)
        .sensoryFeedback(.selection, trigger: selectedID)
        .onChange(of: income) { selectedID = nil }
        .sheet(item: $opened) { EntryDetailView(entry: $0) }
    }

    private func select(_ id: String?) {
        showAllTx = false
        selectedID = (id == selectedID) ? nil : id
    }

    private func donut(_ data: [CategorySlice], total: Double, picked: CategorySlice?) -> some View {
        Chart(data) { s in
            let on = picked?.id == s.id
            SectorMark(angle: .value("金額", s.total),
                       innerRadius: .ratio(0.58),
                       outerRadius: .ratio(on ? 1.0 : 0.88),
                       angularInset: 1.5)
                .cornerRadius(5)
                .foregroundStyle(s.color)
                .opacity(picked == nil || on ? 1 : 0.4)
                .annotation(position: .overlay) {
                    if on && total > 0 {
                        Text(Money.percent(s.total / total))
                            .font(.caption.weight(.bold)).monospacedDigit()
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Palette.onDarkButton, in: .capsule)
                            .foregroundStyle(Palette.onDarkButtonText)
                            .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                    }
                }
        }
        .chartLegend(.hidden)
        .chartBackground { _ in
            VStack(spacing: 2) {
                if let picked {
                    Image(systemName: picked.symbol).font(.title3).foregroundStyle(picked.color)
                        .contentTransition(.symbolEffect(.replace))
                }
                Text(picked?.name ?? (income ? "總收入" : "總支出"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                MoneyText(value: picked?.total ?? total, currency: currency, hidden: hidden,
                          font: .headline.weight(.bold), rollsOnAppear: false)
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            .padding(.horizontal, 60)
        }
        .chartOverlay { _ in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(.rect)
                    .onTapGesture { loc in
                        tap(at: loc, size: geo.size, data: data, total: total)
                    }
            }
        }
    }

    /// 由點的位置算出點到哪一塊（從 12 點方向順時針）
    private func tap(at p: CGPoint, size: CGSize, data: [CategorySlice], total: Double) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let dx = p.x - c.x, dy = p.y - c.y
        let r = min(size.width, size.height) / 2
        let dist = (dx * dx + dy * dy).squareRoot()
        guard dist <= r * 1.05, dist >= r * 0.5, total > 0 else { select(nil); return }
        var angle = atan2(dx, -dy)
        if angle < 0 { angle += 2 * .pi }
        let value = angle / (2 * .pi) * total
        var acc = 0.0
        for s in data {
            acc += s.total
            if value <= acc { select(s.id); return }
        }
    }

    private func legend(_ data: [CategorySlice], total: Double, picked: CategorySlice?) -> some View {
        let shown = picked == nil ? Array(data.prefix(6)) : data
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(shown) { s in
                Button { select(s.id) } label: {
                    HStack(spacing: 10) {
                        Circle().fill(s.color).frame(width: 10, height: 10)
                        Text(s.name).lineLimit(1)
                        Text("\(s.count) 筆").font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Text(Money.format(s.total, currency: currency, hidden: hidden))
                            .monospacedDigit()
                        Text(Money.percent(total > 0 ? s.total / total : 0))
                            .monospacedDigit().foregroundStyle(.secondary)
                            .frame(minWidth: 40, alignment: .trailing)
                    }
                    .font(.subheadline)
                    .padding(.vertical, 6).padding(.horizontal, 8)
                    .background(picked?.id == s.id ? s.color.opacity(0.15) : .clear,
                                in: .rect(cornerRadius: 10, style: .continuous))
                    .contentShape(.rect)
                    .opacity(picked == nil || picked?.id == s.id ? 1 : 0.45)
                }
                .buttonStyle(.plain)
            }
            if picked == nil && data.count > 6 {
                Text("其他 \(data.count - 6) 類，點圓餅圖可查看").font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            }
        }
    }
}

/// 選到某個分類時，下面顯示的子分類拆解與交易
private struct CategoryBreakdown: View {
    var slice: CategorySlice
    var share: Double
    var entries: [Entry]
    var income: Bool
    var currency: String
    var hidden: Bool
    @Binding var showAll: Bool
    @Binding var opened: Entry?
    var onClose: () -> Void

    private struct Sub: Identifiable {
        var id: String, name: String, symbol: String, color: Color, total: Double, count: Int
    }

    private var subs: [Sub] {
        let grouped = Dictionary(grouping: entries) { e -> String in
            guard let c = e.category, c.isSub else { return "main" }
            return c.id.uuidString
        }
        return grouped.map { key, items in
            let c = items.first?.category
            let isMain = key == "main"
            return Sub(id: key, name: isMain ? "\(slice.name)（未細分）" : (c?.name ?? "未分類"),
                       symbol: isMain ? slice.symbol : (c?.symbol ?? slice.symbol),
                       color: isMain ? slice.color : (c?.color ?? slice.color),
                       total: items.reduce(0) { $0 + $1.amount }, count: items.count)
        }
        .sorted { $0.total > $1.total }
    }

    var body: some View {
        let list = subs
        let sorted = entries.sorted { $0.date > $1.date }
        let shown = showAll ? sorted : Array(sorted.prefix(5))
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            HStack(spacing: 12) {
                CategoryIcon(symbol: slice.symbol, color: slice.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(slice.name).font(.headline)
                    Text("\(Money.percent(share)) \(income ? "流入" : "流出")・\(slice.count) 筆")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                MoneyText(value: slice.total, currency: currency, hidden: hidden,
                          font: .headline, rollsOnAppear: false)
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.caption.weight(.bold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
            }

            if list.count > 1 || list.first?.id != "main" {
                VStack(spacing: 10) {
                    ForEach(list) { s in
                        VStack(spacing: 5) {
                            HStack(spacing: 8) {
                                Image(systemName: s.symbol).font(.caption).foregroundStyle(s.color).frame(width: 18)
                                Text(s.name).font(.subheadline).lineLimit(1)
                                Text("\(s.count) 筆").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text(Money.format(s.total, currency: currency, hidden: hidden))
                                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                                Text(Money.percent(slice.total > 0 ? s.total / slice.total : 0))
                                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                    .frame(minWidth: 36, alignment: .trailing)
                            }
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.secondary.opacity(0.15))
                                    Capsule().fill(s.color)
                                        .frame(width: max(4, g.size.width * (slice.total > 0 ? s.total / slice.total : 0)))
                                }
                            }
                            .frame(height: 5)
                        }
                    }
                }
                .padding(12)
                .background(Color(.tertiarySystemGroupedBackground), in: .rect(cornerRadius: 14, style: .continuous))
            }

            VStack(spacing: 4) {
                ForEach(shown) { e in
                    Button { opened = e } label: { EntryRow(entry: e, hidden: hidden, showsDate: true) }
                        .buttonStyle(.plain)
                    if e.id != shown.last?.id { Divider().padding(.leading, 54) }
                }
                if sorted.count > 5 {
                    Button {
                        withAnimation(.snappy) { showAll.toggle() }
                    } label: {
                        Text(showAll ? "收合" : "顯示全部 \(sorted.count) 筆")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 6)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }
        }
    }
}
