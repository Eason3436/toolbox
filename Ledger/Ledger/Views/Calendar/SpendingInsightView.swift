import SwiftUI
import SwiftData
import Charts
import FoundationModels

// MARK: - AI 只負責把買的東西分類（例如奶茶、綠茶 → 飲料），數字全部由 App 自己算

@Generable(description: "把使用者買過的東西依種類分組")
struct AIItemGroups {
    @Guide(description: "2 到 6 組，每組是一種東西", .maximumCount(6))
    var groups: [AIItemGroup]
    @Guide(description: "用一句話描述這個人的購買習慣，20 字以內，不要寫任何數字或金額，例如「常在超商買含糖飲料」")
    var habit: String
}

@Generable
struct AIItemGroup {
    @Guide(description: "這組東西的種類，2 到 4 個字，例如：飲料、零食、麵包、正餐、日用品、交通")
    var type: String
    @Guide(description: "屬於這組的品名，必須照抄清單中的名稱，不可自己編")
    var items: [String]
}

/// AI 分好的組（每個月一份，當天或過去的月份直接用存好的）
struct SavedHabits: Codable, Equatable {
    struct Group: Codable, Equatable {
        var type: String
        var items: [String]
    }
    var habit: String
    var groups: [Group]
    var createdAt: Date

    static func key(_ month: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: month)
        return "habits-v2-\(c.year ?? 0)-\(c.month ?? 0)"
    }

    static func load(_ month: Date) -> SavedHabits? {
        guard let d = UserDefaults.standard.data(forKey: key(month)) else { return nil }
        return try? JSONDecoder().decode(SavedHabits.self, from: d)
    }

    func save(_ month: Date) {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.key(month)) }
    }
}

// MARK: - 本月重點：AI 寫，但只能用 App 算好的數字（寫錯的數字會被換掉）

@Generable(description: "這個月的消費重點")
struct AISpendingInsight {
    @Guide(description: "一句話總結這個月的消費，25 字以內")
    var headline: String
    @Guide(description: "3 個最值得注意的重點，優先寫買了什麼東西的習慣和變化", .maximumCount(3))
    var highlights: [AIInsightHighlight]
    @Guide(description: "一個具體、做得到的小建議，30 字以內；沒有就填空字串")
    var tip: String
}

@Generable
struct AIInsightHighlight {
    @Guide(description: "重點標題，16 字以內，例如「飲料比上月多花 120」")
    var title: String
    @Guide(description: "補充說明，30 字以內，例如「多在全家買，重乳奶茶最多」")
    var detail: String
    @Guide(description: "good 代表省錢或變好、bad 代表花更多、neutral 代表一般", .anyOf(["good", "bad", "neutral"]))
    var tone: String
    @Guide(description: "這個重點講的分類、商家或東西種類，照抄資料裡的名稱")
    var subject: String
}

struct SavedInsight: Codable, Equatable {
    struct Highlight: Codable, Equatable {
        var title: String
        var detail: String
        var tone: String
        var subject: String
    }
    var headline: String
    var highlights: [Highlight]
    var tip: String
    var createdAt: Date

    static func key(_ month: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: month)
        return "insight-v3-\(c.year ?? 0)-\(c.month ?? 0)"
    }

    static func load(_ month: Date) -> SavedInsight? {
        guard let d = UserDefaults.standard.data(forKey: key(month)) else { return nil }
        return try? JSONDecoder().decode(SavedInsight.self, from: d)
    }

    func save(_ month: Date) {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.key(month)) }
    }
}

/// 檢查 AI 寫的句子裡的數字：每個數字都要是資料裡真的有的（差 1 以內），不然就不用
enum NumberCheck {
    static func numbers(in text: String) -> [Double] {
        guard let re = try? NSRegularExpression(pattern: #"\d[\d,]*(?:\.\d+)?"#) else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in
            guard let r = Range(m.range, in: text) else { return nil }
            return Double(text[r].replacingOccurrences(of: ",", with: ""))
        }
    }

    static func ok(_ text: String, allowed: [Double]) -> Bool {
        numbers(in: text).allSatisfy { n in
            n <= 12 || allowed.contains { abs($0 - n) <= 1 }
        }
    }
}

struct SpendingInsightView: View {
    @Query(sort: \Entry.date, order: .reverse) private var entries: [Entry]
    @AppStorage(Prefs.hideAmountsKey) private var hidden = false
    @State private var anchor = Date.now
    @State private var habits: SavedHabits?
    @State private var insight: SavedInsight?
    @State private var loadingAI = false
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

    @State private var yearly = false

    /// 月或年的區間
    private func period(_ d: Date) -> DateInterval {
        cal.dateInterval(of: yearly ? .year : .month, for: d) ?? DateText.monthInterval(d)
    }

    var body: some View {
        let unit: Calendar.Component = yearly ? .year : .month
        let month: DateInterval = period(anchor)
        let prevMonth: DateInterval = period(cal.date(byAdding: unit, value: -1, to: anchor) ?? anchor)
        let inRange: [Entry] = entries.filter { month.contains($0.date) }
        let now = inRange.filter { $0.kind == .expense }
        let prev = entries.filter { $0.kind == .expense && prevMonth.contains($0.date) }
        let total = now.reduce(0) { $0 + $1.amount }
        let income: Double = inRange.filter { $0.kind == .income }.reduce(0) { $0 + $1.amount }
        let prevTotal = prev.reduce(0) { $0 + $1.amount }
        let cats = categoryCompare(now, prev)
        let days: [(Int, Double)] = yearly ? [] : dailyTotals(now, in: month)
        let avg: Double = periodAverage(total: total, period: month)
        let weekdays = weekdayTotals(now)
        let merchants = topMerchants(now)
        let items: [ItemStat] = Self.itemStats(now)
        let prevItems: [ItemStat] = Self.itemStats(prev)
        let names: [String] = Self.thingNames(now: now, prev: prev, items: items, prevItems: prevItems)
        let trend: [TrendPoint] = trendPoints(month)

        ScrollView {
            VStack(spacing: 16) {
                Picker("期間", selection: $yearly) {
                    Text("月").tag(false)
                    Text("年").tag(true)
                }
                .pickerStyle(.segmented)
                monthSwitcher(month)
                kpiRow(total: total, prevTotal: prevTotal, avg: avg, count: now.count)
                flowRow(income: income, expense: total)
                if !yearly {
                    aiCard(cats: cats, merchants: merchants, items: items, total: total, prevTotal: prevTotal)
                }
                trendCard(trend)
                CategoryDonutCard(entries: inRange, hidden: hidden,
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
            .animation(.snappy, value: yearly)
        }
        .background(Palette.background)
        .softTopEdge()
        .task(id: month.start) {
            guard !yearly else { return }
            await runAI(names: names, monthStart: month.start, now: now, prev: prev,
                        cats: cats, merchants: merchants, total: total, prevTotal: prevTotal)
        }
        .navigationTitle("消費分析")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: 月份

    private var thisLabel: String { yearly ? "今年" : "本月" }
    private var lastLabel: String { yearly ? "去年" : "上月" }

    private func periodTitle(_ p: DateInterval) -> String {
        if yearly { return "\(String(cal.component(.year, from: p.start)))年" }
        return DateText.monthTitle(p.start)
    }

    private func step(_ v: Int) {
        let unit: Calendar.Component = yearly ? .year : .month
        anchor = cal.date(byAdding: unit, value: v, to: anchor) ?? anchor
    }

    private func monthSwitcher(_ month: DateInterval) -> some View {
        HStack {
            Button { step(-1) } label: {
                Image(systemName: "chevron.left").frame(width: 34, height: 34)
            }
            .buttonStyle(.glass).buttonBorderShape(.circle)
            Spacer()
            Text(periodTitle(month)).font(.headline).contentTransition(.numericText())
            Spacer()
            Button { step(1) } label: {
                Image(systemName: "chevron.right").frame(width: 34, height: 34)
            }
            .buttonStyle(.glass).buttonBorderShape(.circle)
            .disabled(month.contains(.now))
        }
    }

    /// 月：日均；年：月均（今年只算到這個月）
    private func periodAverage(total: Double, period: DateInterval) -> Double {
        if !yearly { return total / Double(max(elapsedDays(period), 1)) }
        let months: Int = period.contains(.now) ? cal.component(.month, from: .now) : 12
        return total / Double(max(months, 1))
    }

    // MARK: 收入／結餘

    private func flowRow(income: Double, expense: Double) -> some View {
        let net: Double = income - expense
        let netColor: Color = net >= 0 ? .green : .red
        return HStack(spacing: 10) {
            flowTile("收入", income, .green)
            flowTile("結餘", net, netColor)
        }
    }

    private func flowTile(_ title: String, _ v: Double, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            MoneyText(value: v, hidden: hidden, font: .headline).foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(padding: 14)
    }

    // MARK: 收支走勢

    struct TrendPoint: Identifiable {
        var month: Date
        var expense: Double
        var income: Double
        var id: Date { month }
    }

    /// 月：到這個月為止的近 6 個月；年：這一年的 12 個月
    private func trendPoints(_ p: DateInterval) -> [TrendPoint] {
        var starts: [Date] = []
        if yearly {
            for i in 0..<12 {
                if let d = cal.date(byAdding: .month, value: i, to: p.start), d <= .now { starts.append(d) }
            }
        } else {
            for i in (0..<6).reversed() {
                if let d = cal.date(byAdding: .month, value: -i, to: p.start) { starts.append(d) }
            }
        }
        return starts.map { s in
            let m: DateInterval = DateText.monthInterval(s)
            let es: [Entry] = entries.filter { m.contains($0.date) }
            let ex: Double = es.filter { $0.kind == .expense }.reduce(0) { $0 + $1.amount }
            let inc: Double = es.filter { $0.kind == .income }.reduce(0) { $0 + $1.amount }
            return TrendPoint(month: m.start, expense: ex, income: inc)
        }
    }

    private func trendCard(_ t: [TrendPoint]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(yearly ? "每月收支" : "近 6 個月收支").font(.headline)
                Spacer()
                legendDot(.red, "支出")
                legendDot(.green, "收入")
            }
            Chart {
                ForEach(t) { p in
                    BarMark(x: .value("月", p.month, unit: .month), y: .value("支出", p.expense), width: .ratio(0.5))
                        .foregroundStyle(Color.red.opacity(0.25).gradient)
                        .cornerRadius(3)
                    LineMark(x: .value("月", p.month, unit: .month), y: .value("金額", p.expense), series: .value("類型", "支出"))
                        .foregroundStyle(.red)
                        .symbol(.circle)
                        .interpolationMethod(.catmullRom)
                    LineMark(x: .value("月", p.month, unit: .month), y: .value("金額", p.income), series: .value("類型", "收入"))
                        .foregroundStyle(.green)
                        .symbol(.circle)
                        .interpolationMethod(.catmullRom)
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) { _ in
                    AxisValueLabel(format: .dateTime.month(.narrow))
                }
            }
            .chartYAxis(.hidden)
            .frame(height: 170)
        }
        .cardStyle()
    }

    // MARK: 指標

    private func kpiRow(total: Double, prevTotal: Double, avg: Double, count: Int) -> some View {
        let change = prevTotal > 0 ? (total - prevTotal) / prevTotal : nil
        return HStack(spacing: 10) {
            kpi(thisLabel + "支出", Money.format(total, hidden: hidden),
                change.map { "\($0 >= 0 ? "▲" : "▼") \(Money.percent(abs($0))) vs " + lastLabel } ?? lastLabel + "無資料",
                (change ?? 0) > 0 ? .red : .green)
            kpi(yearly ? "月均" : "日均", Money.format(avg, hidden: hidden), "\(count) 筆交易", .secondary)
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
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("本月重點").font(.headline)
                Spacer()
                if loadingAI { ProgressView().controlSize(.small) }
            }
            if let insight {
                Text(insight.headline).font(.subheadline).foregroundStyle(.secondary)
                ForEach(Array(insight.highlights.enumerated()), id: \.offset) { _, h in
                    highlightRow(h, cat: cats.first { $0.name == h.subject })
                }
                if !insight.tip.isEmpty {
                    Label(insight.tip, systemImage: "lightbulb")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                // 還沒有 AI 分析（或裝置不支援）：先用算好的重點
                let list = facts(cats: cats, merchants: merchants, items: items, total: total, prevTotal: prevTotal)
                if list.isEmpty {
                    Text(loadingAI ? "分析中…" : "這個月還沒有足夠的資料").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(list) { f in
                    HStack(spacing: 12) {
                        LedgerIcon(symbol: f.symbol, size: 18, color: f.color)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.title).font(.subheadline.weight(.semibold))
                            Text(f.detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .cardStyle()
        .animation(.snappy, value: insight)
    }

    private func highlightRow(_ h: SavedInsight.Highlight, cat: Cat?) -> some View {
        let color: Color = h.tone == "good" ? .green : (h.tone == "bad" ? .red : .blue)
        let symbol: String = cat?.symbol ?? (h.tone == "good" ? "arrow.down.right" : (h.tone == "bad" ? "arrow.up.right" : "sparkle"))
        return HStack(spacing: 12) {
            LedgerIcon(symbol: symbol, size: 18, color: cat?.color ?? color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(h.title).font(.subheadline.weight(.semibold))
                Text(h.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 4)
            if let cat {
                // 上月 vs 本月 的小長條
                let maxV: Double = max(cat.now, cat.prev, 1)
                VStack(alignment: .trailing, spacing: 3) {
                    miniBar(cat.prev / maxV, Color.secondary.opacity(0.35))
                    miniBar(cat.now / maxV, color)
                }
                .frame(width: 56)
            }
        }
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
                legendDot(Color.secondary.opacity(0.4), lastLabel)
                legendDot(Color.primary, thisLabel)
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

        // MARK: AI：買了什麼

    /// 要交給 AI 分類的名稱：發票品項（本月＋上月）＋沒有發票的記帳名稱（不含連鎖店名、付款方式）
    static func thingNames(now: [Entry], prev: [Entry], items: [ItemStat], prevItems: [ItemStat]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        func add(_ n: String) {
            let t = n.trimmingCharacters(in: .whitespaces)
            guard t.count >= 2, t.count <= 24, !seen.contains(t) else { return }
            seen.insert(t); out.append(t)
        }
        let receiptNames: [ItemStat] = (items + prevItems).sorted { $0.quantity > $1.quantity }
        for i in receiptNames { add(i.name) }
        let plain: [Entry] = (now + prev).filter { $0.receiptJSON == nil }
        let counts: [String: Int] = Dictionary(grouping: plain) { $0.title }.mapValues { $0.count }
        for (t, _) in counts.sorted(by: { $0.value > $1.value })
        where BrandLogo.brand(for: t) == nil && !PayMethod.isPayMethod(t) && t != "未命名" {
            add(t)
        }
        return Array(out.prefix(40))
    }

    private func runAI(names: [String], monthStart: Date, now: [Entry], prev: [Entry], cats: [Cat],
                       merchants: [(name: String, total: Double, count: Int)], total: Double, prevTotal: Double) async {
        let isPast = !DateText.monthInterval(.now).contains(monthStart)
        let savedInsight = SavedInsight.load(monthStart)
        insight = savedInsight
        if let savedInsight, isPast || Calendar.current.isDateInToday(savedInsight.createdAt) {
            habits = SavedHabits.load(monthStart)
            return
        }
        guard NoticeParser.aiAvailable else { return }
        loadingAI = true
        defer { loadingAI = false }
        await groupThings(names: names, monthStart: monthStart, isPast: isPast)
        guard total > 0 else { return }
        let stats: [HabitStat] = habits.map { Self.habitStats($0, now: now, prev: prev) } ?? []
        if let r = await writeInsight(cats: cats, merchants: merchants, stats: stats, total: total, prevTotal: prevTotal) {
            r.save(monthStart)
            withAnimation(.snappy) { insight = r }
        }
    }

    /// 把買的東西依種類分組（例如奶茶、綠茶 → 飲料），給下面的重點用
    private func groupThings(names: [String], monthStart: Date, isPast: Bool) async {
        let saved = SavedHabits.load(monthStart)
        if let saved {
            let known: Set<String> = Set(saved.groups.flatMap(\.items))
            let missing = names.filter { !known.contains($0) }.count
            if isPast || Calendar.current.isDateInToday(saved.createdAt) || missing <= 2 {
                habits = saved
                return
            }
        }
        habits = saved
        guard names.count >= 3 else { return }
        let session = LanguageModelSession(instructions: """
        你幫記帳 App 把使用者買過的東西分類。
        規則：
        1. 只能用清單裡的名稱，一字不改地照抄到 items。
        2. 依「東西是什麼」分組，不是依商店。例如：奶茶、美式咖啡、綠茶 → 飲料；餅乾、洋芋片 → 零食；便當、午餐、拉麵 → 正餐；捷運、高鐵 → 交通。
        3. 看不出是什麼的名稱就不要放。
        4. habit 只描述習慣，不要寫數字、金額或清單裡沒有的東西。
        """)
        let list = names.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        do {
            let r = try await session.respond(to: "清單：\n\(list)", generating: AIItemGroups.self,
                                              options: GenerationOptions(sampling: .greedy)).content
            let result = Self.validate(r, names: names)
            guard !result.groups.isEmpty else { return }
            result.save(monthStart)
            habits = result
        } catch {
            // 分不出來就只用分類和商家
        }
    }

    /// AI 寫本月重點：資料裡的數字全部由 App 算好，AI 只負責挑重點和說法；寫錯數字的句子換成算好的
    private func writeInsight(cats: [Cat], merchants: [(name: String, total: Double, count: Int)], stats: [HabitStat],
                              total: Double, prevTotal: Double) async -> SavedInsight? {
        var allowed: [Double] = [total, prevTotal, abs(total - prevTotal)]
        if prevTotal > 0 { allowed.append(abs(total - prevTotal) / prevTotal * 100) }
        var catLines: [String] = []
        for c in cats.prefix(8) {
            allowed += [c.now, c.prev, abs(c.delta)]
            let cs: String = c.delta >= 0 ? "+" : "-"
            let cd: Int = Int(abs(c.delta).rounded())
            catLines.append("\(c.name)：本月 \(Int(c.now.rounded()))、上月 \(Int(c.prev.rounded()))、差 \(cs)\(cd)")
        }
        var merLines: [String] = []
        for m in merchants {
            allowed += [m.total, Double(m.count)]
            merLines.append("\(m.name)：\(Int(m.total.rounded()))，\(m.count) 次")
        }
        var thingLines: [String] = []
        for st in stats.prefix(6) {
            let diff: Double = st.total - st.prevTotal
            allowed += [st.total, st.prevTotal, abs(diff), st.quantity]
            var line = "\(st.type)：本月 \(Self.qtyText(st.quantity)) 個共 \(Int(st.total.rounded()))、上月 \(Int(st.prevTotal.rounded()))"
            if !st.topThings.isEmpty { line += "；最多的是 \(st.topThings.joined(separator: "、"))" }
            if let m = st.topMerchant { line += "；多在 \(m) 買" }
            thingLines.append(line)
        }
        let session = LanguageModelSession(instructions: """
        你是記帳 App 的消費分析助理，用繁體中文、口語、句子短。
        根據資料挑出這個月最值得注意的三件事。有「買了什麼」的資料時優先用，例如「飲料買了 8 個，多在全家」比「便利商店花比較多」更有用。
        數字一定要照抄資料裡的數字，不可以自己加減或估算，也不要寫資料裡沒有的分類、商家或東西。金額直接寫數字，不加 $ 或「元」。
        subject 填重點講的分類、商家或東西種類名稱。
        """)
        let diffAll: Int = Int(abs(total - prevTotal).rounded())
        let sign: String = total >= prevTotal ? "+" : "-"
        var pct: String = ""
        if prevTotal > 0 {
            let p: Int = Int((abs(total - prevTotal) / prevTotal * 100).rounded())
            pct = "（\(p)%）"
        }
        let catText: String = catLines.joined(separator: "\n")
        let merText: String = merLines.isEmpty ? "無" : merLines.joined(separator: "\n")
        let thingText: String = thingLines.isEmpty ? "沒有資料" : thingLines.joined(separator: "\n")
        var prompt: String = "本月總支出 \(Int(total.rounded()))，上月 \(Int(prevTotal.rounded()))，差 \(sign)\(diffAll)\(pct)。\n"
        prompt += "分類：\n\(catText)\n商家：\n\(merText)\n買了什麼（依種類）：\n\(thingText)"
        guard let r = try? await session.respond(to: prompt, generating: AISpendingInsight.self,
                                                 options: GenerationOptions(sampling: .greedy)).content else { return nil }
        // 數字對不上的重點換掉，標題對不上就用算好的
        var highlights: [SavedInsight.Highlight] = r.highlights.compactMap { h in
            let ok = NumberCheck.ok(h.title, allowed: allowed) && NumberCheck.ok(h.detail, allowed: allowed)
            guard ok, !h.title.isEmpty else { return nil }
            return SavedInsight.Highlight(title: h.title, detail: h.detail, tone: h.tone, subject: h.subject)
        }
        if highlights.count < 2 {
            let backup = facts(cats: cats, merchants: merchants, items: [], total: total, prevTotal: prevTotal)
            for f in backup where highlights.count < 3 && !highlights.contains(where: { $0.title == f.title }) {
                highlights.append(SavedInsight.Highlight(title: f.title, detail: f.detail,
                                                         tone: f.color == .green ? "good" : (f.color == .red ? "bad" : "neutral"),
                                                         subject: ""))
            }
        }
        guard !highlights.isEmpty else { return nil }
        var headline = r.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        if headline.isEmpty || !NumberCheck.ok(headline, allowed: allowed) {
            headline = total >= prevTotal || prevTotal == 0 ? "這個月的花費重點" : "這個月比上月少花"
        }
        let tip: String = NumberCheck.ok(r.tip, allowed: allowed) ? r.tip.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return SavedInsight(headline: headline, highlights: highlights, tip: tip, createdAt: .now)
    }

    /// 只留清單裡真的有的名稱、合併同名的組；習慣句有數字就不用
    static func validate(_ r: AIItemGroups, names: [String]) -> SavedHabits {
        let pool: Set<String> = Set(names)
        var used: Set<String> = []
        var groups: [SavedHabits.Group] = []
        for g in r.groups {
            let type = g.type.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !type.isEmpty, type.count <= 6 else { continue }
            var matched: [String] = []
            for raw in g.items {
                let n = raw.trimmingCharacters(in: .whitespaces)
                let hit: String? = pool.contains(n) ? n : names.first { !n.isEmpty && ($0.contains(n) || n.contains($0)) }
                if let hit, !used.contains(hit) { used.insert(hit); matched.append(hit) }
            }
            guard !matched.isEmpty else { continue }
            if let i = groups.firstIndex(where: { $0.type == type }) {
                groups[i].items += matched
            } else {
                groups.append(SavedHabits.Group(type: type, items: matched))
            }
        }
        var habit = r.habit.trimmingCharacters(in: .whitespacesAndNewlines)
        if habit.rangeOfCharacter(from: .decimalDigits) != nil || habit.count > 30 { habit = "" }
        return SavedHabits(habit: habit, groups: groups, createdAt: .now)
    }

    struct HabitStat: Identifiable {
        var type: String
        var quantity: Double = 0
        var total: Double = 0
        var prevTotal: Double = 0
        var merchants: [String: Double] = [:]
        var things: [String: Double] = [:]
        var id: String { type }
        var topMerchant: String? { merchants.max { $0.value < $1.value }?.key }
        var topThings: [String] { things.sorted { $0.value > $1.value }.prefix(3).map(\.key) }
    }

    /// 用 AI 分好的組，把本月和上月的錢加總（數字都是 App 算的）
    static func habitStats(_ h: SavedHabits, now: [Entry], prev: [Entry]) -> [HabitStat] {
        var groupOf: [String: String] = [:]
        for g in h.groups { for i in g.items { groupOf[i] = g.type } }
        var stats: [String: HabitStat] = [:]
        func add(_ name: String, qty: Double, amount: Double, merchant: String, current: Bool) {
            guard let t = groupOf[name.trimmingCharacters(in: .whitespaces)] else { return }
            var s = stats[t] ?? HabitStat(type: t)
            if current {
                s.quantity += qty
                s.total += amount
                s.merchants[merchant, default: 0] += amount
                s.things[name, default: 0] += qty
            } else {
                s.prevTotal += amount
            }
            stats[t] = s
        }
        for (list, current) in [(now, true), (prev, false)] {
            for e in list {
                let merchant: String = BrandLogo.brand(for: e.title)?.name ?? e.title
                if let r = Receipt.from(e.receiptJSON) {
                    for it in r.items where it.price > 0 {
                        add(it.name, qty: max(it.quantity, 1), amount: it.price, merchant: merchant, current: current)
                    }
                } else {
                    add(e.title, qty: 1, amount: e.amount, merchant: merchant, current: current)
                }
            }
        }
        return stats.values.filter { $0.total > 0 }.sorted { $0.total > $1.total }
    }
}
