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

struct SpendingInsightView: View {
    @Query(sort: \Entry.date, order: .reverse) private var entries: [Entry]
    @AppStorage(Prefs.hideAmountsKey) private var hidden = false
    @State private var anchor = Date.now
    @State private var insight: AISpendingInsight?
    @State private var loadingAI = false
    @State private var aiError: String?
    @State private var pickedDay: Int?
    @State private var pieIncome = false

    private let cal = Calendar.current

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

        ScrollView {
            VStack(spacing: 16) {
                monthSwitcher(month)
                kpiRow(total: total, prevTotal: prevTotal, avg: avg, count: now.count)
                aiCard(cats: cats, merchants: merchants, total: total, prevTotal: prevTotal)
                CategoryDonutCard(entries: entries.filter { month.contains($0.date) }, hidden: hidden,
                                  title: "分類比例", income: $pieIncome)
                if !cats.isEmpty { categoryCompareCard(cats) }
                if !days.isEmpty { dailyCard(days, avg: avg, monthDays: cal.range(of: .day, in: .month, for: month.start)?.count ?? 31) }
                if !weekdays.isEmpty { weekdayCard(weekdays) }
                if !merchants.isEmpty { merchantCard(merchants) }
            }
            .padding()
            .padding(.bottom, 40)
            .animation(.snappy, value: anchor)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("消費分析")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { StatsView() } label: { Image(systemName: "chart.bar.xaxis") }
                    .accessibilityLabel("月／年統計")
            }
        }
        .task(id: month.start) { await runAI(cats: cats, merchants: merchants, total: total, prevTotal: prevTotal) }
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

    // MARK: AI 重點卡

    @ViewBuilder
    private func aiCard(cats: [Cat], merchants: [(name: String, total: Double, count: Int)], total: Double, prevTotal: Double) -> some View {
        VStack(alignment: .leading, spacing: 12) {
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
                    Text(insight.tip)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if let aiError {
                Text(aiError).font(.footnote).foregroundStyle(.secondary)
            } else if !loadingAI {
                Text("這個月還沒有足夠的資料").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .cardStyle()
        .animation(.snappy, value: insight?.headline)
    }

    private func highlightRow(_ h: AISpendingHighlight, cat: Cat?) -> some View {
        let color: Color = h.tone == "good" ? .green : (h.tone == "bad" ? .red : .blue)
        return HStack(spacing: 12) {
            Image(systemName: cat?.symbol ?? (h.tone == "good" ? "arrow.down.right" : h.tone == "bad" ? "arrow.up.right" : "equal"))
                .font(.subheadline.weight(.semibold)).foregroundStyle(cat?.color ?? color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(h.title).font(.subheadline.weight(.semibold))
                Text(h.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 4)
            if let cat {
                // 本月 vs 上月 的小長條
                VStack(alignment: .trailing, spacing: 3) {
                    let maxV = max(cat.now, cat.prev, 1)
                    miniBar(cat.prev / maxV, .secondary.opacity(0.35))
                    miniBar(cat.now / maxV, color)
                    Text(cat.delta >= 0 ? "+\(Money.format(cat.delta, hidden: hidden))" : Money.format(cat.delta, hidden: hidden))
                        .font(.caption2.weight(.bold)).monospacedDigit().foregroundStyle(color)
                }
                .frame(width: 70)
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
        let yTop: Double = max(peak, avg, 1) * 1.1
        let xRange: ClosedRange<Double> = 0.5...(Double(monthDays) + 0.5)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("每天花多少").font(.headline)
                Spacer()
                if let d = pickedDay, let v = days.first(where: { $0.0 == d })?.1 {
                    Text("\(d) 日 \(Money.format(v, hidden: hidden))").font(.subheadline.weight(.semibold)).monospacedDigit()
                } else {
                    Text("虛線是日均").font(.caption).foregroundStyle(.secondary)
                }
            }
            Chart {
                ForEach(days, id: \.0) { d in
                    BarMark(x: .value("日", d.0), y: .value("金額", d.1), width: .fixed(6))
                        .foregroundStyle(d.1 > avg * 1.8 ? Color.orange : Color.accentColor)
                        .opacity(pickedDay == nil || pickedDay == d.0 ? 1 : 0.4)
                        .cornerRadius(3)
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

    // MARK: 星期幾

    private func weekdayCard(_ w: [(String, Double)]) -> some View {
        let maxV = w.map(\.1).max() ?? 1
        return VStack(alignment: .leading, spacing: 10) {
            Text("星期幾花最多").font(.headline)
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(w, id: \.0) { d in
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(d.1 == maxV ? Color.orange.gradient : Color.accentColor.opacity(0.45).gradient)
                            .frame(height: max(6, 90 * d.1 / max(maxV, 1)))
                        Text(d.0).font(.caption2.weight(.semibold)).foregroundStyle(d.1 == maxV ? .orange : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 112, alignment: .bottom)
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
        Dictionary(grouping: list) { $0.title }
            .filter { !PayMethod.isPayMethod($0.key) && $0.key != "未命名" }
            .map { (name: $0.key, total: $0.value.reduce(0) { $0 + $1.amount }, count: $0.value.count) }
            .sorted { $0.total > $1.total }
            .prefix(5).map { $0 }
    }

    // MARK: AI

    private func runAI(cats: [Cat], merchants: [(name: String, total: Double, count: Int)], total: Double, prevTotal: Double) async {
        insight = nil
        aiError = nil
        guard total > 0 else { return }
        guard NoticeParser.aiAvailable else { aiError = "Apple Intelligence \(NoticeParser.aiStatusText)"; return }
        loadingAI = true
        defer { loadingAI = false }
        let catLines = cats.prefix(8).map { "\($0.name)：本月 \(Int($0.now))、上月 \(Int($0.prev))" }.joined(separator: "\n")
        let merLines = merchants.map { "\($0.name)：\(Int($0.total)) 元，\($0.count) 次" }.joined(separator: "\n")
        let session = LanguageModelSession(instructions: """
        你是記帳 App 的消費分析助理。根據使用者這個月和上個月的分類花費，挑出最值得注意的三件事。
        用繁體中文，句子要短，數字要跟資料一致，不要編造資料中沒有的分類或商家。
        """)
        let prompt = """
        本月總支出 \(Int(total)) 元，上月 \(Int(prevTotal)) 元。
        分類：
        \(catLines)
        常去商家：
        \(merLines)
        """
        do {
            let r = try await session.respond(to: prompt, generating: AISpendingInsight.self).content
            withAnimation(.snappy) { insight = r }
        } catch {
            aiError = "暫時無法產生重點"
        }
    }
}
