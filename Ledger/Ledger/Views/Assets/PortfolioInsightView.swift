import SwiftUI
import SwiftData
import Charts

/// 像 Google 財經那樣的投資組合分析：資產配置、集中度、方塊圖，加上 Apple Intelligence 的文字解讀
struct PortfolioInsightView: View {
    /// 只看單一檔時傳入
    var focus: Asset? = nil

    @Query(sort: \Asset.order) private var assets: [Asset]
    @Query(sort: \Account.order) private var accounts: [Account]
    @AppStorage(Prefs.hideAmountsKey) private var hidden = false
    @StateObject private var ai = PortfolioAI()
    @AppStorage("aiUseWeb") private var useWeb = true
    @Environment(\.openURL) private var openURL
    @State private var question = ""
    @FocusState private var asking: Bool

    struct Holding: Identifiable {
        var id: String
        var name: String
        var ticker: String
        var kind: AssetKind
        var value: Double      // 主幣別
        var dayChange: Double?
        var profit: Double?
    }

    private var holdings: [Holding] {
        assets.filter { $0.kind.group == .finance && $0.nativeValue > 0 }
            .map { a in
                Holding(id: a.id.uuidString, name: a.name, ticker: a.ticker.uppercased(), kind: a.kind,
                        value: a.nativeValue * QuoteService.rate(from: a.currency),
                        dayChange: a.dayChangeRatio, profit: a.profitRatio)
            }
            .sorted { $0.value > $1.value }
    }

    private var cash: Double {
        accounts.filter { !$0.archived }.reduce(0) { $0 + max($1.balance, 0) * QuoteService.rate(from: $1.currency) }
    }

    var body: some View {
        let hs = holdings
        let invested = hs.reduce(0) { $0 + $1.value }
        ScrollView {
            VStack(spacing: 16) {
                if hs.isEmpty {
                    EmptyHint(symbol: "chart.pie", title: "還沒有投資", message: "到資產頁按 ＋ 加入股票或 ETF，就能看分析")
                } else {
                    aiCard(.performance)
                    allocationCard(hs, invested: invested)
                    concentrationCard(hs, invested: invested)
                    treemapCard(hs, invested: invested)
                    if useWeb { newsCard }
                    askCard
                    Toggle(isOn: $useWeb) {
                        Label("分析時讀取網路新聞", systemImage: "globe")
                    }
                    .cardStyle(padding: 16)
                    .onChange(of: useWeb) { _, _ in Task { await runAnalysis(hs, invested: invested) } }
                    Text("由 Apple Intelligence 在 iPhone 上產生，參考你的持股、今日大盤與 Google 新聞最近 7 天的標題（只讀標題，不讀全文）。僅供參考，不構成投資建議。")
                        .font(.footnote).foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 30)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(.systemGroupedBackground))
        .navigationTitle(focus.map { "\($0.name) 分析" } ?? "AI 投資分析")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await runAnalysis(hs, invested: invested) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .symbolEffect(.rotate, options: .repeat(.continuous), isActive: ai.running)
                }
                .disabled(ai.running || hs.isEmpty)
            }
        }
        .task {
            if ai.insight == nil, !hs.isEmpty {
                await runAnalysis(hs, invested: invested)
            }
        }
    }

    // MARK: AI 文字

    enum Part { case performance, allocation, concentration }

    private func partText(_ part: Part) -> String? {
        switch part {
        case .performance: ai.insight?.performance
        case .allocation: ai.insight?.allocation
        case .concentration: ai.insight?.concentration
        }
    }

    private func partTitle(_ part: Part) -> String {
        switch part {
        case .performance: "表現走勢："
        case .allocation: "配置重點："
        case .concentration: "集中度："
        }
    }

    @ViewBuilder
    private func aiText(_ part: Part) -> some View {
        if let error = ai.error, part == .performance {
            Label(error, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.orange)
        } else if let text = partText(part), !text.isEmpty {
            (Text(partTitle(part)).bold() + Text(text))
                .font(.body)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.2), value: text)
        } else if ai.running {
            HStack(spacing: 8) {
                ProgressView()
                Text("Apple Intelligence 分析中…").foregroundStyle(.secondary)
            }
            .font(.subheadline)
        }
    }

    private func aiCard(_ part: Part) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("AI 摘要", systemImage: "sparkles").font(.headline)
            aiText(.performance)
            questionsList
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    @ViewBuilder
    private var questionsList: some View {
        if let qs = ai.insight?.questions, !ai.running {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(qs.enumerated()), id: \.offset) { _, q in
                    Button {
                        Task { await ai.ask(q, context: currentContext) }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "arrow.turn.down.right")
                            Text(q).multilineTextAlignment(.leading)
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .disabled(ai.answering)
                }
            }
            .padding(.top, 4)
        }
    }

    // MARK: 資產配置

    private func allocationCard(_ hs: [Holding], invested: Double) -> some View {
        var parts = Dictionary(grouping: hs, by: \.kind).map { (name: $0.key.label, color: color(for: $0.key), value: $0.value.reduce(0) { $0 + $1.value }) }
        if cash > 0 { parts.append((name: "現金帳戶", color: AssetGroup.cash.color, value: cash)) }
        parts.sort { $0.value > $1.value }
        let total = parts.reduce(0) { $0 + $1.value }
        return VStack(alignment: .leading, spacing: 14) {
            Text("資產配置").font(.headline)
            FlowLayout(spacing: 12, leading: true) {
                ForEach(parts, id: \.name) { p in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 3).fill(p.color).frame(width: 12, height: 12)
                        Text("\(p.name) \(Money.percent(total > 0 ? p.value / total : 0))")
                    }
                    .font(.subheadline)
                }
            }
            Chart(parts, id: \.name) { p in
                SectorMark(angle: .value("金額", p.value), innerRadius: .ratio(0.7), angularInset: 1.5)
                    .foregroundStyle(p.color)
            }
            .chartBackground { _ in
                VStack(spacing: 2) {
                    Text("總額").font(.caption).foregroundStyle(.secondary)
                    MoneyText(value: total, hidden: hidden, font: .headline, rollsOnAppear: false)
                }
            }
            .frame(height: 190)
            aiText(.allocation)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func color(for kind: AssetKind) -> Color {
        switch kind {
        case .stock: Color(hex: "#2E7D32")
        case .etf: Color(hex: "#1E88E5")
        case .fund: Color(hex: "#8E24AA")
        case .crypto: Color(hex: "#F57C00")
        default: kind.group.color
        }
    }

    // MARK: 集中度

    private func concentrationCard(_ hs: [Holding], invested: Double) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("集中度風險").font(.headline)
            ForEach(hs.prefix(8)) { h in
                let w = invested > 0 ? h.value / invested : 0
                HStack(spacing: 12) {
                    Text(h.name).font(.subheadline).lineLimit(1).frame(width: 96, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .trailing) {
                            Capsule().fill(Color(.tertiarySystemFill))
                            HStack {
                                Spacer(minLength: 0)
                                Text(Money.percent(w)).font(.caption.weight(.bold)).foregroundStyle(.white).padding(.trailing, 8)
                            }
                            .frame(width: max(geo.size.width * w, 44))
                            .frame(maxHeight: .infinity)
                            .background(Color(hex: "#3D6AE0"), in: .capsule)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(height: 26)
                }
            }
            aiText(.concentration)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: 方塊圖

    private func treemapCard(_ hs: [Holding], invested: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("投資視覺化").font(.headline)
            Text("方塊大小代表在投資組合中的權重，顏色是今天的漲跌（紅漲綠跌）。")
                .font(.subheadline).foregroundStyle(.secondary)
            GeometryReader { geo in
                let rects = Treemap.layout(hs.map(\.value), in: CGRect(origin: .zero, size: geo.size))
                ZStack(alignment: .topLeading) {
                    ForEach(Array(hs.enumerated()), id: \.element.id) { i, h in
                        if i < rects.count {
                            let r = rects[i].insetBy(dx: 2, dy: 2)
                            tile(h)
                                .frame(width: max(r.width, 0), height: max(r.height, 0))
                                .offset(x: r.minX, y: r.minY)
                        }
                    }
                }
            }
            .frame(height: 300)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func tile(_ h: Holding) -> some View {
        let ch = h.dayChange ?? 0
        let strength = min(abs(ch) / 0.05, 1)
        let base: Color = ch >= 0 ? HeatColor.red : HeatColor.green
        return VStack(alignment: .leading, spacing: 2) {
            Text(h.ticker.isEmpty ? h.name : h.ticker.replacingOccurrences(of: ".TWO", with: "").replacingOccurrences(of: ".TW", with: ""))
                .font(.headline)
            Text(h.name).font(.caption).lineLimit(1)
            if let d = h.dayChange {
                Text((d >= 0 ? "+" : "") + Money.percent(d, digits: 2)).font(.caption.weight(.semibold)).monospacedDigit()
            }
        }
        .foregroundStyle(strength > 0.5 ? .white : base)
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(base.opacity(0.18 + 0.62 * strength), in: .rect(cornerRadius: 14, style: .continuous))
    }

    // MARK: 新聞

    private func runAnalysis(_ hs: [Holding], invested: Double) async {
        let targets: [(ticker: String, name: String)] = (focus.map { [($0.ticker, $0.name)] } ?? [])
            + hs.filter { !$0.ticker.isEmpty && $0.ticker != focus?.ticker.uppercased() }.map { ($0.ticker, $0.name) }
        await ai.analyze(context: contextText(hs, invested: invested), targets: targets, useWeb: useWeb)
    }

    private var newsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("相關新聞", systemImage: "newspaper").font(.headline)
                Spacer()
                if ai.fetchingNews { ProgressView() }
            }
            if !ai.markets.isEmpty {
                HStack(spacing: 8) {
                    ForEach(ai.markets, id: \.name) { m in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Text((m.change >= 0 ? "+" : "") + Money.percent(m.change, digits: 2))
                                .font(.subheadline.weight(.semibold)).monospacedDigit()
                                .foregroundStyle(m.change >= 0 ? HeatColor.red : HeatColor.green)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 12, style: .continuous))
                    }
                }
            }
            if ai.news.isEmpty, !ai.fetchingNews {
                Text("沒有抓到最近 7 天的相關新聞。").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(ai.news.prefix(8)) { n in
                Button {
                    if let url = n.link { openURL(url) }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(n.title).font(.subheadline.weight(.semibold)).multilineTextAlignment(.leading)
                            .foregroundStyle(.primary)
                        HStack(spacing: 6) {
                            Text(n.topic).foregroundStyle(Color.accentColor)
                            Text(n.source)
                            if let d = n.date { Text(d, format: .relative(presentation: .named)) }
                        }
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                if n.id != ai.news.prefix(8).last?.id { Divider() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: 提問

    private var askCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(ai.answers.enumerated()), id: \.offset) { _, qa in
                VStack(alignment: .leading, spacing: 6) {
                    Text(qa.question).font(.subheadline.weight(.bold))
                    if qa.answer.isEmpty {
                        ProgressView()
                    } else {
                        Text(qa.answer).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Divider()
            }
            HStack(spacing: 10) {
                Image(systemName: "sparkle.magnifyingglass").foregroundStyle(.secondary)
                TextField("問 AI 關於你的投資", text: $question, axis: .vertical)
                    .focused($asking)
                    .submitLabel(.send)
                    .onSubmit(send)
                if !question.isEmpty {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                    .disabled(ai.answering)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(.tertiarySystemFill), in: .capsule)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func send() {
        let q = question
        question = ""
        asking = false
        Task { await ai.ask(q, context: currentContext) }
    }

    // MARK: 給 AI 的資料

    private var currentContext: String {
        let hs = holdings
        return contextText(hs, invested: hs.reduce(0) { $0 + $1.value })
    }

    private func contextText(_ hs: [Holding], invested: Double) -> String {
        var lines: [String] = []
        lines.append("主幣別：\(Prefs.mainCurrency)")
        lines.append("投資總市值：\(Int(invested))；現金帳戶合計：\(Int(cash))")
        for h in hs {
            var l = "- \(h.name)（\(h.ticker.isEmpty ? h.kind.label : h.ticker)，\(h.kind.label)）市值 \(Int(h.value))，占投資 \(Money.percent(invested > 0 ? h.value / invested : 0, digits: 1))"
            if let d = h.dayChange { l += "，今日 \(d >= 0 ? "+" : "")\(Money.percent(d, digits: 2))" }
            if let p = h.profit { l += "，持有報酬 \(p >= 0 ? "+" : "")\(Money.percent(p, digits: 1))" }
            lines.append(l)
        }
        if let focus {
            lines.append("使用者特別想了解：\(focus.name)（\(focus.ticker)），請以這檔為主來分析，同時說明它在整體組合中的角色。")
        }
        return lines.joined(separator: "\n")
    }
}

/// 簡單的 squarified treemap
enum Treemap {
    static func layout(_ values: [Double], in rect: CGRect) -> [CGRect] {
        let total = values.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return values.map { _ in .zero } }
        let scale = rect.width * rect.height / total
        let areas = values.map { $0 * scale }
        var result: [CGRect] = []
        var remaining = rect
        var i = 0
        while i < areas.count {
            let short = min(remaining.width, remaining.height)
            var row: [Double] = [areas[i]]
            var j = i + 1
            while j < areas.count, worst(row + [areas[j]], short) <= worst(row, short) {
                row.append(areas[j]); j += 1
            }
            let rowArea = row.reduce(0, +)
            if remaining.width >= remaining.height {
                let w = rowArea / remaining.height
                var y = remaining.minY
                for a in row {
                    let h = a / w
                    result.append(CGRect(x: remaining.minX, y: y, width: w, height: h))
                    y += h
                }
                remaining = CGRect(x: remaining.minX + w, y: remaining.minY, width: remaining.width - w, height: remaining.height)
            } else {
                let h = rowArea / remaining.width
                var x = remaining.minX
                for a in row {
                    let w = a / h
                    result.append(CGRect(x: x, y: remaining.minY, width: w, height: h))
                    x += w
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + h, width: remaining.width, height: remaining.height - h)
            }
            i = j
        }
        return result
    }

    private static func worst(_ row: [Double], _ side: Double) -> Double {
        let s = row.reduce(0, +)
        guard let mx = row.max(), let mn = row.min(), s > 0, mn > 0 else { return .infinity }
        return max(side * side * mx / (s * s), (s * s) / (side * side * mn))
    }
}
