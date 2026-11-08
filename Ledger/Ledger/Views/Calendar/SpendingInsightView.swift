import SwiftUI
import SwiftData
import Charts
import FoundationModels

// MARK: - AI 只產生重點卡片的短句，數字和圖表都在 App 裡算

@Generable(description: "本月消費分析的重點")
struct AISpendingInsight {
    @Guide(description: "一句話總結本月花費，15 字以內，例如「飲食比上月多花兩成」")
    var headline: String
    @Guide(description: "三個重點，每個對應一個分類或商家", .count(3))
    var highlights: [AISpendingHighlight]
    @Guide(description: "一個具體可做的省錢建議，25 字以內")
    var tip: String
}

@Generable
struct AISpendingHighlight {
    @Guide(description: "重點對應的分類或商家名稱，必須照抄資料中的名稱")
    var subject: String
    @Guide(description: "8 字以內的短標題，例如「飲料暴增」「交通變少」")
    var title: String
    @Guide(description: "20 字以內的說明")
    var detail: String
    @Guide(description: "good（變好、省錢）、bad（花太多）或 neutral")
    var tone: String
}

/// 分析結果存起來（每個月一份，一天最多重新分析一次）
struct SavedInsight: Codable, Equatable {
    struct Highlight: Codable, Equatable {
        var subject: String, title: String, detail: String, tone: String
    }
    var headline: String
    var highlights: [Highlight]
    var tip: String
    var createdAt: Date

    init(_ r: AISpendingInsight) {
        headline = r.headline
        highlights = r.highlights.map { Highlight(subject: $0.subject, title: $0.title, detail: $0.detail, tone: $0.tone) }
        tip = r.tip
        createdAt = .now
    }

    static func key(_ month: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: month)
        return "insight-\(c.year ?? 0)-\(c.month ?? 0)"
    }

    static func load(_ month: Date) -> SavedInsight? {
        guard let d = UserDefaults.standard.data(forKey: key(month)) else { return nil }
        return try? JSONDecoder().decode(SavedInsight.self, from: d)
    }

    func save(_ month: Date) {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.key(month)) }
    }
}

struct SpendingInsightView: View {
    @Query(sort: \Entry.date, order: .reverse) private var entries: [Entry]
    @AppStorage(Prefs.hideAmountsKey) private var hidden = false
    @State private var anchor = Date.now
    @State private var insight: SavedInsight?
    @State private var loadingAI = false
    @State private var aiError: String?
    @State private var pickedDay: Int?
    @State private var pieIncome = false

    private let cal = Calendar.current

    /// 發票上的品項，依「品名＋商家」合併
    struct ItemStat: Identifiable {
        var name: String
        var merchant: String
        var quantity: Double
        var total: Double
        var id: String { name + "@" + merchant }
    }

    private struct Cat: Identifiable {
        var id: String, name: String, symbol: String, color: Color, now: Double, prev: Double
        var delta: Double { now - prev }
    }

    var body: some View {
        let month = DateText.monthInterval(anchor)
        let prevMonth = DateText.monthInterval(cal.date(byAdding: .month, value: -1, to: anchor) ?? anchor)
        let now = entries.filter { $0.kind == .expense && month.contains($0.date) }
        let prev = entries.filter { $0.kind == .expense && prevMonth.contains($0.date) }
        let total = now.reduce(0) { $0 + $1.amount }
        let prevTotal = prev.reduce(0) { $0 + $1.amount }
        let cats = categoryCompare(now, prev)
        let days = dailyTotals(now, in: month)
        let avg = days.isEmpty ? 0 : days.map(\.1).reduce(0, +) / Double(max(elapsedDays(month), 1))
        let weekdays = weekdayTotals(now)
        let merchants = topMerchants(now)
        let items: [ItemStat] = Self.itemStats(now)

        ScrollView {
            VStack(spacing: 16) {
                monthSwitcher(month)
                kpiRow(total: total, prevTotal: prevTotal, avg: avg, count: now.count)
                aiCard(cats: cats, merchants: merchants, items: items, total: total, prevTotal: prevTotal)
                CategoryDonutCard(entries: entries.filter { month.contains($0.date) }, hidden: hidden,
                                  title: "分類比例", income: $pieIncome)
                if !cats.isEmpty { categoryCompareCard(cats) }
                if !days.isEmpty { dailyCard(days, avg: avg, monthDays: cal.range(of: .day, in: .month, for: month.start)?.count ?? 31) }
                if !weekdays.isEmpty { weekdayCard(weekdays) }
                if !items.isEmpty { itemCard(items) }
                if !merchants.isEmpty { merchantCard(merchants) }
            }
            .padding()
            .padding(.bottom, 40)
            .animation(.snappy, value: anchor)
        }
        .background(Palette.background)
        .navigationTitle("消費分析")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { StatsView() } label: { Image(systemName: "chart.bar.xaxis") }
                    .accessibilityLabel("月／年統計")
            }
        }
    }

    // MARK: 月份

    private func monthSwitcher(_ month: DateInterval) -> some View {
        HStack {
            Button { anchor = cal.date(byAdding: .month, value: -1, to: anchor) ?? anchor } label: {
                Image(systemName: "chevron.left").frame(width: 34, height: 34)
            }
            .buttonStyle(.glass).buttonBorderShape(.circle)
            Spacer()
            Text(DateText.monthTitle(month.start)).font(.headline).contentTransition(.numericText())
            Spacer()
            Button { anchor = cal.date(byAdding: .month, value: 1, to: anchor) ?? anchor } label: {
                Image(systemName: "chevron.right").frame(width: 34, height: 34)
            }
            .buttonStyle(.glass).buttonBorderShape(.circle)
            .disabled(month.contains(.now))
        }
    }

    // MARK: 指標

    private func kpiRow(total: Double, prevTotal: Double, avg: Double, count: Int) -> some View {
        let change = prevTotal > 0 ? (total - prevTotal) / prevTotal : nil
        return HStack(spacing: 10) {
            kpi("本月支出", Money.format(total, hidden: hidden),
                change.map { "\($0 >= 0 ? "▲" : "▼") \(Money.percent(abs($0))) vs 上月" } ?? "上月無資料",
                (change ?? 0) > 0 ? .red : .green)
            kpi("日均", Money.format(avg, hidden: hidden), "\(count) 筆交易", .secondary)
        }
    }

    private func kpi(_ title: String, _ value: String, _ sub: String, _ subColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            Text(sub).font(.caption.weight(.semibold)).foregroundStyle(subColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: 本月重點（直接用資料算，不讓 AI 寫）

    private struct Fact: Identifiable {
        var id: String
        var symbol: String
        var color: Color
        var title: String
        var detail: String
    }

    private func facts(cats: [Cat], merchants: [(name: String, total: Double, count: Int)], items: [ItemStat],
                       total: Double, prevTotal: Double) -> [Fact] {
        var list: [Fact] = []
        if prevTotal > 0 {
            let diff = total - prevTotal
            let up = diff >= 0
            list.append(Fact(id: "total", symbol: up ? "arrow.up.right" : "arrow.down.right", color: up ? .red : .green,
                             title: up ? "比上月多花 \(Money.format(diff, hidden: hidden))" : "比上月少花 \(Money.format(-diff, hidden: hidden))",
                             detail: "本月 \(Money.format(total, hidden: hidden))，上月 \(Money.format(prevTotal, hidden: hidden))"))
        }
        if let c = cats.filter({ $0.delta > 0 }).max(by: { $0.delta < $1.delta }) {
            list.append(Fact(id: "cat", symbol: c.symbol, color: c.color,
                             title: "\(c.name)增加最多",
                             detail: "多了 \(Money.format(c.delta, hidden: hidden))（上月 \(Money.format(c.prev, hidden: hidden)) → 本月 \(Money.format(c.now, hidden: hidden))）"))
        } else if let c = cats.max(by: { $0.now < $1.now }), c.now > 0 {
            list.append(Fact(id: "cat", symbol: c.symbol, color: c.color,
                             title: "花最多的是\(c.name)",
                             detail: "本月 \(Money.format(c.now, hidden: hidden))，占 \(Money.percent(total > 0 ? c.now / total : 0))"))
        }
        if let m = merchants.max(by: { $0.count < $1.count }), m.count >= 2 {
            list.append(Fact(id: "merchant", symbol: "storefront", color: .blue,
                             title: "最常去\(m.name)",
                             detail: "\(m.count) 次，共 \(Money.format(m.total, hidden: hidden))"))
        }
        if let i = items.max(by: { $0.quantity == $1.quantity ? $0.total < $1.total : $0.quantity < $1.quantity }), i.quantity >= 2 {
            list.append(Fact(id: "item", symbol: "cart", color: .orange,
                             title: "最常買\(i.name)",
                             detail: "在\(i.merchant)買了 \(Self.qtyText(i.quantity)) 個，共 \(Money.format(i.total, hidden: hidden))"))
        }
        return list
    }

    @ViewBuilder
    private func aiCard(cats: [Cat], merchants: [(name: String, total: Double, count: Int)], items: [ItemStat],
                        total: Double, prevTotal: Double) -> some View {
        let list = facts(cats: cats, merchants: merchants, items: items, total: total, prevTotal: prevTotal)
        VStack(alignment: .leading, spacing: 14) {
            Text("本月重點").font(.headline)
            if list.isEmpty {
                Text("這個月還沒有足夠的資料").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(list) { f in
                HStack(spacing: 12) {
                    Image(systemName: f.symbol)
                        .font(.subheadline.weight(.semibold)).foregroundStyle(f.color)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.title).font(.subheadline.weight(.semibold))
                        Text(f.detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .cardStyle()
    }

    private func miniBar(_ ratio: Double, _ color: Color) -> some View {
        GeometryReader { g in
            Capsule().fill(color).frame(width: max(4, g.size.width * ratio))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: 5)
    }

    // MARK: 分類：本月 vs 上月

    private func categoryCompareCard(_ cats: [Cat]) -> some View {
        let top: [Cat] = Array(cats.prefix(6))
        let maxV: Double = top.reduce(1.0) { max($0, $1.now, $1.prev) }
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("分類比較").font(.headline)
                Spacer()
                legendDot(Color.secondary.opacity(0.4), "上月")
                legendDot(Color.primary, "本月")
            }
            ForEach(top) { c in
                compareRow(c, maxV: maxV)
            }
        }
        .cardStyle()
    }

    /// 一個分類一列：名稱和差額在上，本月、上月兩條在下
    private func compareRow(_ c: Cat, maxV: Double) -> some View {
        let up: Bool = c.delta > 0
        let deltaText: String = c.delta == 0 ? "持平" : (up ? "+" : "−") + Money.format(abs(c.delta), hidden: hidden)
        let deltaColor: Color = c.delta == 0 ? Color.secondary : (up ? Color.red : Color.green)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(c.color).frame(width: 8, height: 8)
                Text(c.name).font(.subheadline.weight(.medium))
                Spacer()
                Text(Money.format(c.now, hidden: hidden)).font(.subheadline.weight(.semibold)).monospacedDigit()
                Text(deltaText).font(.caption.weight(.medium)).monospacedDigit().foregroundStyle(deltaColor)
                    .frame(minWidth: 52, alignment: .trailing)
            }
            compareBar(c.now / maxV, c.color)
            compareBar(c.prev / maxV, Color.secondary.opacity(0.3))
        }
    }

    private func compareBar(_ ratio: Double, _ color: Color) -> some View {
        GeometryReader { g in
            Capsule().fill(color)
                .frame(width: ratio > 0 ? max(4, g.size.width * CGFloat(ratio)) : 0)
        }
        .frame(height: 6)
    }

    private func legendDot(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(c).frame(width: 8, height: 8)
            Text(t).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: 每日支出

    private func dailyCard(_ days: [(Int, Double)], avg: Double, monthDays: Int) -> some View {
        let peak: Double = days.map { $0.1 }.max() ?? 0
        let yTop: Double = max(peak, avg, 1) * 1.25
        let xRange: ClosedRange<Double> = 0.5...(Double(monthDays) + 0.5)
        // 花最多的 3 天標上金額（全部都標會擠在一起）
        let labeled: Set<Int> = Set(days.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(3).map { $0.0 })
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("每天花多少").font(.headline)
                Spacer()
                if let d = pickedDay, let v = days.first(where: { $0.0 == d })?.1 {
                    Text("\(d) 日 \(Money.format(v, hidden: hidden))").font(.subheadline.weight(.semibold)).monospacedDigit()
                } else {
                    Text("虛線是日均 \(Money.format(avg, hidden: hidden))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Chart {
                ForEach(days, id: \.0) { d in
                    BarMark(x: .value("日", d.0), y: .value("金額", d.1), width: .fixed(6))
                        .foregroundStyle(d.1 > avg * 1.8 ? Color.orange : Color.accentColor)
                        .opacity(pickedDay == nil || pickedDay == d.0 ? 1 : 0.4)
                        .cornerRadius(3)
                        .annotation(position: .top, spacing: 3) {
                            if pickedDay == nil && labeled.contains(d.0) {
                                Text(Money.format(d.1, hidden: hidden))
                                    .font(.caption2.weight(.semibold)).monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .fixedSize()
                            }
                        }
                }
                RuleMark(y: .value("日均", avg))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(.secondary)
            }
            .chartXSelection(value: $pickedDay)
            // 數字軸上 .ratio 寬度會變成 0，柱子改固定寬度，並固定整個月的範圍
            .chartXScale(domain: xRange)
            .chartYScale(domain: 0...yTop)
            .chartYAxis(.hidden)
            .chartXAxis { AxisMarks(values: [1, 8, 15, 22, 29]) { AxisValueLabel() } }
            .frame(height: 150)
            .sensoryFeedback(.selection, trigger: pickedDay)
        }
        .cardStyle()
    }

    // MARK: 發票品項

    private func itemCard(_ items: [ItemStat]) -> some View {
        let top: [ItemStat] = Array(items.prefix(8))
        let maxV: Double = top.first?.total ?? 1
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("常買的東西").font(.headline)
                Spacer()
                Text("來自發票").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(top) { i in
                itemRow(i, ratio: maxV > 0 ? i.total / maxV : 0)
            }
        }
        .cardStyle()
    }

    private func itemRow(_ i: ItemStat, ratio: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(i.name).font(.subheadline.weight(.medium)).lineLimit(1)
                Text("×\(Self.qtyText(i.quantity))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Text(Money.format(i.total, hidden: hidden)).font(.subheadline.weight(.semibold)).monospacedDigit()
            }
            Text(i.merchant).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            compareBar(ratio, Color.accentColor.opacity(0.7))
        }
    }

    static func qtyText(_ q: Double) -> String {
        q == q.rounded() ? String(Int(q)) : String(format: "%.1f", q)
    }

    /// 把有發票的記帳拆成品項，同一家店的同一品名加總
    static func itemStats(_ list: [Entry]) -> [ItemStat] {
        var map: [String: ItemStat] = [:]
        for e in list {
            guard let r = Receipt.from(e.receiptJSON) else { continue }
            let raw: String = r.store.isEmpty ? e.title : r.store
            let merchant: String = BrandLogo.brand(for: raw)?.name ?? raw
            for it in r.items where it.price > 0 {
                let name: String = it.name.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }
                let key: String = name + "@" + merchant
                var s: ItemStat = map[key] ?? ItemStat(name: name, merchant: merchant, quantity: 0, total: 0)
                s.quantity += max(it.quantity, 1)
                s.total += it.price
                map[key] = s
            }
        }
        return map.values.sorted { (a: ItemStat, b: ItemStat) -> Bool in a.total > b.total }
    }

    // MARK: 星期幾

    private func weekdayCard(_ w: [(String, Double)]) -> some View {
        let maxV = w.map(\.1).max() ?? 1
        return VStack(alignment: .leading, spacing: 10) {
            Text("星期幾花最多").font(.headline)
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(w, id: \.0) { d in
                    VStack(spacing: 6) {
                        Text(d.1 > 0 ? Money.format(d.1, hidden: hidden) : "")
                            .font(.caption2.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(d.1 == maxV ? Color.orange : Color.secondary)
                            .lineLimit(1).minimumScaleFactor(0.6)
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(d.1 == maxV ? Color.orange.gradient : Color.accentColor.opacity(0.45).gradient)
                            .frame(height: max(6, 90 * d.1 / max(maxV, 1)))
                        Text(d.0).font(.caption2.weight(.semibold)).foregroundStyle(d.1 == maxV ? .orange : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 130, alignment: .bottom)
        }
        .cardStyle()
    }

    // MARK: 商家

    private func merchantCard(_ m: [(name: String, total: Double, count: Int)]) -> some View {
        let maxV = m.first?.total ?? 1
        return VStack(alignment: .leading, spacing: 12) {
            Text("花最多的商家").font(.headline)
            ForEach(m, id: \.name) { x in
                NavigationLink { MerchantDetailView(merchant: x.name) } label: {
                    VStack(spacing: 5) {
                        HStack {
                            Text(x.name).font(.subheadline.weight(.medium)).lineLimit(1)
                            Text("\(x.count) 次").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(Money.format(x.total, hidden: hidden)).font(.subheadline.weight(.semibold)).monospacedDigit()
                        }
                        GeometryReader { g in
                            Capsule().fill(Color.accentColor.gradient)
                                .frame(width: max(6, g.size.width * x.total / max(maxV, 1)))
                        }
                        .frame(height: 6)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .cardStyle()
    }

    // MARK: 計算

    private func categoryCompare(_ now: [Entry], _ prev: [Entry]) -> [Cat] {
        func key(_ e: Entry) -> String { e.category?.main.id.uuidString ?? "none" }
        let n = Dictionary(grouping: now, by: key), p = Dictionary(grouping: prev, by: key)
        return Set(n.keys).union(p.keys).compactMap { k -> Cat? in
            let any = n[k]?.first ?? p[k]?.first
            let c = any?.category?.main
            let a = n[k]?.reduce(0) { $0 + $1.amount } ?? 0
            let b = p[k]?.reduce(0) { $0 + $1.amount } ?? 0
            return Cat(id: k, name: c?.name ?? "未分類", symbol: c?.symbol ?? "questionmark", color: c?.color ?? .gray, now: a, prev: b)
        }
        .sorted { max($0.now, $0.prev) > max($1.now, $1.prev) }
    }

    private func dailyTotals(_ list: [Entry], in month: DateInterval) -> [(Int, Double)] {
        let g = Dictionary(grouping: list) { cal.component(.day, from: $0.date) }
        let lastDay = month.contains(.now) ? cal.component(.day, from: .now)
            : (cal.range(of: .day, in: .month, for: month.start)?.count ?? 30)
        return (1...max(lastDay, 1)).map { d in (d, g[d]?.reduce(0) { $0 + $1.amount } ?? 0) }
    }

    private func elapsedDays(_ month: DateInterval) -> Int {
        month.contains(.now) ? cal.component(.day, from: .now) : (cal.range(of: .day, in: .month, for: month.start)?.count ?? 30)
    }

    private func weekdayTotals(_ list: [Entry]) -> [(String, Double)] {
        guard !list.isEmpty else { return [] }
        let names = ["一", "二", "三", "四", "五", "六", "日"]
        let g = Dictionary(grouping: list) { (cal.component(.weekday, from: $0.date) + 5) % 7 }
        return (0..<7).map { (names[$0], g[$0]?.reduce(0) { $0 + $1.amount } ?? 0) }
    }

    private func topMerchants(_ list: [Entry]) -> [(name: String, total: Double, count: Int)] {
        // 連鎖店的不同寫法（全家／FamilyMart）算同一家
        Dictionary(grouping: list) { BrandLogo.groupKey(for: $0.title) }
            .filter { !PayMethod.isPayMethod($0.key) && $0.key != "未命名" }
            .map { g -> (name: String, total: Double, count: Int) in
                let t = g.value.first?.title ?? g.key
                return (name: BrandLogo.brand(for: t)?.name ?? t, total: g.value.reduce(0) { $0 + $1.amount }, count: g.value.count)
            }
            .sorted { $0.total > $1.total }
            .prefix(5).map { $0 }
    }

    // MARK: AI

}
