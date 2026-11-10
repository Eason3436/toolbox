import SwiftUI
import SwiftData
import Charts

enum PriceRange: String, CaseIterable, Identifiable {
    case m1 = "1mo", m3 = "3mo", m6 = "6mo", y1 = "1y"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .m1: "1月"
        case .m3: "3月"
        case .m6: "6月"
        case .y1: "1年"
        }
    }
    var longLabel: String {
        switch self {
        case .m1: "1個月"
        case .m3: "3個月"
        case .m6: "6個月"
        case .y1: "1年"
        }
    }
}

struct PricePoint: Identifiable {
    var date: Date
    var price: Double
    var id: Date { date }
}

/// 單一資產頁：卡片、市值、買賣、走勢、紀錄、資訊
struct AssetDetailView: View {
    @Bindable var asset: Asset
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Prefs.hideAmountsKey) private var hidden = false

    @State private var range: PriceRange = .m3
    @State private var points: [PricePoint] = []
    @State private var loading = false
    @State private var lotSheet: LotDraft?
    @State private var editing = false
    @State private var confirmDelete = false
    @State private var selectedPoint: PricePoint?

    struct LotDraft: Identifiable {
        var id = UUID()
        var buy: Bool
        var lot: AssetLot?
    }

    private var cur: String { asset.currency }
    private var value: Double { asset.nativeValue }
    private var cost: Double { asset.costPerUnit * asset.quantity }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    hero.appearEffect()
                    valueCard.appearEffect(delay: 0.05)
                    if asset.usesQuote {
                        HStack(spacing: 12) {
                            Button { lotSheet = LotDraft(buy: true) } label: {
                                Label("買入", systemImage: "plus")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 18)
                                    .foregroundStyle(Color(.systemBackground))
                                    .background(Color.primary, in: .rect(cornerRadius: 22, style: .continuous))
                            }
                            Button { lotSheet = LotDraft(buy: false) } label: {
                                Text("賣出")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 18)
                                    .foregroundStyle(.primary)
                                    .background(Palette.card, in: .rect(cornerRadius: 22, style: .continuous))
                            }
                            .disabled(asset.quantity <= 0)
                        }
                        .pressable()
                        .appearEffect(delay: 0.1)
                        priceCard.appearEffect(delay: 0.15)
                        NavigationLink { PortfolioInsightView(focus: asset) } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "chart.line.uptrend.xyaxis").font(.title2).foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("分析").font(.headline)
                                    Text("解讀這檔和你的整體配置").font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                            }
                            .foregroundStyle(.primary)
                            .cardStyle(padding: 18)
                        }
                        .pressable()
                        lotsSection
                    } else {
                        Button { editing = true } label: {
                            Label("更新價值", systemImage: "pencil")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 18)
                                .foregroundStyle(Color(.systemBackground))
                                .background(Color.primary, in: .rect(cornerRadius: 22, style: .continuous))
                        }
                        .pressable()
                    }
                    about
                }
                .padding(.horizontal)
                .padding(.bottom, 30)
            }
            .background(Palette.background)
            .navigationTitle(asset.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("編輯", systemImage: "pencil") { editing = true }
                        if asset.usesQuote {
                            Button("更新報價", systemImage: "arrow.clockwise") { Task { await refresh() } }
                        }
                        Divider()
                        Button("刪除資產", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }
            }
            .confirmationDialog("刪除「\(asset.name)」？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("刪除", role: .destructive) {
                    Haptics.shared.trash(); context.delete(asset)
                    try? context.save()
                    dismiss()
                }
            }
            .sheet(item: $lotSheet) { d in
                LotEditor(asset: asset, buy: d.buy, lot: d.lot)
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $editing) { AssetEditor(asset: asset) }
            .task(id: range) { await loadHistory() }
        }
    }

    // MARK: 卡片

    private var hero: some View {
        let pl = value - cost
        let ratio = cost > 0 ? pl / cost : nil
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                CategoryIcon(symbol: asset.kind.symbol, color: .white, size: 52, onDark: true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(asset.name).font(.title3.weight(.semibold)).lineLimit(1)
                    Text(asset.usesQuote ? "\(Money.format(asset.quantity, currency: "USD")) 股 × \(Money.symbol(for: cur))\(Money.format(asset.lastPrice, currency: "USD"))" : asset.kind.label)
                        .font(.subheadline).foregroundStyle(.white.opacity(0.7)).monospacedDigit()
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    MoneyText(value: value, currency: cur, hidden: hidden, font: .title3.weight(.semibold))
                    if let ratio { DarkPill(text: (ratio >= 0 ? "+" : "") + Money.percent(ratio, digits: 1)) }
                }
            }
            Spacer(minLength: 40)
            if asset.usesQuote, cost > 0 {
                Text("未實現損益").font(.subheadline).foregroundStyle(.white.opacity(0.7))
                Text("\(Money.format(pl, currency: cur, hidden: hidden, signed: true)) (\((ratio ?? 0) >= 0 ? "+" : "")\(Money.percent(ratio ?? 0, digits: 1)))")
                    .font(.title.weight(.bold)).monospacedDigit()
                    .contentTransition(.numericText(value: pl))
                HStack {
                    Text("成本 \(Money.format(cost, currency: cur, hidden: hidden))")
                    Spacer()
                    if let d = asset.priceUpdatedAt {
                        Text(RelativeDateTimeFormatter().localizedString(for: d, relativeTo: .now))
                    }
                }
                .font(.subheadline).foregroundStyle(.white.opacity(0.7)).padding(.top, 6)
            }
        }
        .foregroundStyle(.white)
        .padding(26)
        .frame(maxWidth: .infinity, minHeight: 250, alignment: .topLeading)
        .background {
            ZStack(alignment: .trailing) {
                GradientCardBackground(color: Color(hex: "#2D5DA0"))
                if !asset.ticker.isEmpty {
                    Text(asset.ticker)
                        .font(.system(size: 70, weight: .heavy))
                        .foregroundStyle(.white.opacity(0.08))
                        .lineLimit(1).minimumScaleFactor(0.4)
                        .padding(.horizontal, 24)
                        .offset(y: -10)
                }
            }
        }
        .clipShape(.rect(cornerRadius: 30, style: .continuous))
    }

    private var valueCard: some View {
        let pl = value - cost
        let dayAmount = asset.usesQuote && asset.previousClose > 0 ? (asset.lastPrice - asset.previousClose) * asset.quantity : nil
        return VStack(alignment: .leading, spacing: 14) {
            Text("目前價值").foregroundStyle(.secondary).font(.title3)
            HStack(spacing: 12) {
                MoneyText(value: value, currency: cur, hidden: hidden, font: .system(size: 44, weight: .bold, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.5)
                if cost > 0 {
                    Pill(text: (pl >= 0 ? "+" : "") + Money.percent(pl / cost, digits: 1), tint: pl >= 0 ? .red : .green)
                }
            }
            if cost > 0 {
                Text("投入 \(Money.format(cost, currency: cur, hidden: hidden))，\(pl >= 0 ? "獲利" : "虧損") \(Money.format(abs(pl), currency: cur, hidden: hidden))")
                    .foregroundStyle(.secondary)
            }
            if asset.usesQuote {
                Divider()
                if let dayAmount, let r = asset.dayChangeRatio {
                    HStack {
                        Text("今天").foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Money.format(dayAmount, currency: cur, hidden: hidden, signed: true)) (\(r >= 0 ? "+" : "")\(Money.percent(r, digits: 1)))")
                            .foregroundStyle(r >= 0 ? .red : .green).monospacedDigit()
                    }
                }
                HStack {
                    Text("目前價格").foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Money.symbol(for: cur))\(Money.format(asset.lastPrice, currency: "USD"))").monospacedDigit().fontWeight(.semibold)
                }
                if asset.costPerUnit > 0 {
                    HStack {
                        Text("平均成本").foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Money.symbol(for: cur))\(Money.format(asset.costPerUnit, currency: "USD"))").monospacedDigit().fontWeight(.semibold)
                    }
                }
            }
        }
        .font(.title3)
        .cardStyle()
    }

    // MARK: 走勢

    private var priceCard: some View {
        let first = points.first?.price ?? 0
        let last = points.last?.price ?? 0
        let change = first > 0 ? (last - first) / first : 0
        let lo = min(points.map(\.price).min() ?? 0, asset.costPerUnit > 0 ? asset.costPerUnit : .infinity)
        let hi = max(points.map(\.price).max() ?? 1, asset.costPerUnit)
        let pad = (hi - lo) * 0.12
        let lineColor: Color = change >= 0 ? HeatColor.red : HeatColor.green

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(selectedPoint.map { DateText.short($0.date) } ?? "價格").font(.headline)
                Spacer()
                if let sp = selectedPoint {
                    Text("\(Money.symbol(for: cur))\(Money.format(sp.price, currency: "USD"))").font(.headline).monospacedDigit()
                } else if !points.isEmpty {
                    Text((change >= 0 ? "+" : "") + Money.percent(change, digits: 1))
                        .font(.headline).foregroundStyle(lineColor)
                    + Text(" · \(range.longLabel)").foregroundStyle(.secondary)
                }
            }
            ZStack {
                if points.isEmpty {
                    if loading { ProgressView() } else { Text("沒有走勢資料").foregroundStyle(.secondary) }
                }
                Chart {
                    ForEach(points) { p in
                        AreaMark(x: .value("日期", p.date), yStart: .value("低", lo - pad), yEnd: .value("價格", p.price))
                            .foregroundStyle(LinearGradient(colors: [lineColor.opacity(0.22), lineColor.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("日期", p.date), y: .value("價格", p.price))
                            .foregroundStyle(lineColor)
                            .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .interpolationMethod(.monotone)
                    }
                    if asset.costPerUnit > 0 {
                        RuleMark(y: .value("平均成本", asset.costPerUnit))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 5]))
                            .foregroundStyle(.secondary)
                            .annotation(position: .top, alignment: .trailing) {
                                Text("平均成本 \(Money.symbol(for: cur))\(Money.format(asset.costPerUnit, currency: "USD"))")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .padding(.horizontal, 4)
                                    .background(Palette.card)
                            }
                    }
                    if let sp = selectedPoint {
                        RuleMark(x: .value("選取", sp.date)).foregroundStyle(.secondary.opacity(0.5))
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
                        let dot: (Date, Double) -> CGPoint? = { d, v in
                            guard let x = proxy.position(forX: d), let y = proxy.position(forY: v) else { return nil }
                            return CGPoint(x: plot.minX + x, y: plot.minY + y)
                        }
                        ZStack(alignment: .topLeading) {
                            Rectangle().fill(.clear).contentShape(.rect)
                                .gesture(DragGesture(minimumDistance: 0)
                                    .onChanged { g in
                                        if let d = proxy.value(atX: g.location.x - plot.minX, as: Date.self) {
                                            selectedPoint = points.min { abs($0.date.timeIntervalSince(d)) < abs($1.date.timeIntervalSince(d)) }
                                        }
                                    }
                                    .onEnded { _ in withAnimation(.easeOut(duration: 0.2)) { selectedPoint = nil } })
                            // 圓點在原地出現／消失，不會在放手時飛到最後一點
                            if let sp = selectedPoint, let pos = dot(sp.date, sp.price) {
                                ChartDot(color: lineColor, size: 14).position(pos)
                                    .transition(.scale(scale: 0.3).combined(with: .opacity))
                                    .id("sel")
                            } else if let lp = points.last, let pos = dot(lp.date, lp.price) {
                                ChartDot(color: lineColor, size: 11).position(pos)
                                    .transition(.scale(scale: 0.3).combined(with: .opacity))
                                    .id("last")
                            }
                        }
                    }
                }
                .opacity(points.isEmpty ? 0 : 1)
                .animation(.easeInOut(duration: 0.35), value: points.count)
            }
            .frame(height: 220)
            .selectionHaptic(trigger: selectedPoint?.date)

            HStack(spacing: 6) {
                ForEach(PriceRange.allCases) { r in
                    Button {
                        withAnimation(.snappy) { range = r }
                    } label: {
                        Text(r.label)
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(range == r ? Color(.tertiarySystemFill) : .clear, in: .capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider()
            HStack {
                Text("更新於\(asset.priceUpdatedAt.map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: .now) } ?? "—") · Yahoo Finance")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                Button {
                    Task { await refresh() }
                } label: {
                    // 用 SF Symbols 原生旋轉，不會帶動外框位移
                    Image(systemName: "arrow.clockwise")
                        .font(.body.weight(.semibold))
                        .symbolEffect(.rotate, options: .repeat(.continuous), isActive: loading)
                        .frame(width: 40, height: 40)
                        .background(Color(.tertiarySystemFill), in: .circle)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .disabled(loading)
                .fixedSize()
            }
        }
        .cardStyle()
    }

    // MARK: 紀錄

    private var lotsSection: some View {
        let lots = asset.sortedLots
        let years = Dictionary(grouping: lots) { Calendar.current.component(.year, from: $0.date) }
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(years.keys.sorted(by: >), id: \.self) { y in
                let items = years[y]!
                HStack {
                    Text(String(y))
                    Spacer()
                    Text("\(items.count)筆交易")
                }
                .font(.title3).foregroundStyle(.secondary).padding(.horizontal, 6)
                VStack(spacing: 2) {
                    ForEach(items) { lot in
                        Button { lotSheet = LotDraft(buy: lot.isBuy, lot: lot) } label: {
                            HStack(spacing: 14) {
                                CategoryIcon(symbol: lot.isBuy ? "plus" : "minus", color: lot.isBuy ? .blue : .orange, size: 46)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(lot.isBuy ? "買入" : "賣出") \(Money.format(abs(lot.quantity), currency: "USD")) 股").font(.headline)
                                    Text("\(DateText.monthDay(lot.date)) · @ \(Money.symbol(for: cur))\(Money.format(lot.price, currency: "USD"))")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 3) {
                                    Text("\(cur) \((abs(lot.quantity) * lot.price).formatted(.number.precision(.fractionLength(2))))")
                                        .font(.headline).monospacedDigit()
                                    if lot.isBuy, lot.price > 0, asset.lastPrice > 0 {
                                        let r = (asset.lastPrice - lot.price) / lot.price
                                        Text((r >= 0 ? "+" : "") + Money.percent(r, digits: 1))
                                            .font(.subheadline).foregroundStyle(r >= 0 ? .red : .green)
                                    }
                                }
                            }
                            .padding(.vertical, 6)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .cardStyle(padding: 16)
            }
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("關於").font(.title3).foregroundStyle(.secondary).padding(.horizontal, 6)
            VStack(spacing: 14) {
                if !asset.ticker.isEmpty { aboutRow("代號", asset.ticker) }
                aboutRow("類型", asset.kind.label)
                aboutRow("幣別", cur == Prefs.mainCurrency ? cur : "\(cur) · 1 \(cur) = \(String(format: "%.2f", QuoteService.rate(from: cur))) \(Prefs.mainCurrency)")
                aboutRow("來源", asset.usesQuote ? "Yahoo Finance" : "手動")
                aboutRow("類別", asset.kind.group.label)
            }
            .cardStyle()
        }
    }

    private func aboutRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).foregroundStyle(.secondary)
            Spacer()
            Text(v).multilineTextAlignment(.trailing)
        }
        .font(.title3)
    }

    // MARK: 資料

    private func loadHistory() async {
        guard asset.usesQuote else { return }
        loading = true
        defer { loading = false }
        if let h = try? await QuoteService.history(asset.ticker, range: range.rawValue) {
            withAnimation(.easeInOut(duration: 0.35)) {
                points = h.map { PricePoint(date: $0.0, price: $0.1) }
            }
        }
    }

    private func refresh() async {
        loading = true
        if let q = try? await QuoteService.fetch(asset.ticker) {
            withAnimation(.snappy) {
                asset.lastPrice = q.price
                asset.previousClose = q.previousClose
                asset.currency = q.currency
                asset.priceUpdatedAt = .now
            }
            try? context.save()
        }
        loading = false
        await loadHistory()
    }
}

/// 新增或編輯一筆買入／賣出
struct LotEditor: View {
    var asset: Asset
    var buy: Bool
    var lot: AssetLot?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var isBuy = true
    @State private var qtyText = ""
    @State private var priceText = ""
    @State private var feeText = ""
    @State private var date = Date.now
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("", selection: $isBuy) {
                        Text("買入").tag(true)
                        Text("賣出").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                }
                Section {
                    LabeledContent("股數") {
                        TextField("0", text: $qtyText).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("成交價") {
                        TextField("0", text: $priceText).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("手續費") {
                        TextField("0", text: $feeText).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    DatePicker("日期", selection: $date, displayedComponents: .date)
                    TextField("備註", text: $note)
                } footer: {
                    if let q = Money.parse(qtyText), let p = Money.parse(priceText) {
                        Text("金額 \(asset.currency) \(Money.format(q * p, currency: "USD"))")
                    }
                }
                if lot != nil {
                    Section {
                        Button("刪除這筆", role: .destructive) {
                            if let lot { Haptics.shared.trash(); context.delete(lot) }
                            asset.lots?.removeAll { $0.id == lot?.id }
                            asset.recomputeFromLots()
                            try? context.save()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(lot == nil ? (isBuy ? "買入" : "賣出") : "編輯紀錄")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) { save() }
                        .disabled((Money.parse(qtyText) ?? 0) <= 0 || Money.parse(priceText) == nil)
                }
            }
            .onAppear {
                isBuy = buy
                if let lot {
                    isBuy = lot.isBuy
                    qtyText = String(abs(lot.quantity).formatted(.number.grouping(.never)))
                    priceText = String(lot.price.formatted(.number.grouping(.never)))
                    feeText = lot.fee == 0 ? "" : String(lot.fee.formatted(.number.grouping(.never)))
                    date = lot.date
                    note = lot.note
                } else if asset.lastPrice > 0 {
                    priceText = String(asset.lastPrice.formatted(.number.grouping(.never)))
                }
            }
        }
    }

    private func save() {
        // 舊資料沒有買賣紀錄時，先把現有持股補成一筆
        if (asset.lots ?? []).isEmpty, asset.quantity > 0, lot == nil {
            let seed = AssetLot(date: asset.createdAt, quantity: asset.quantity, price: asset.costPerUnit > 0 ? asset.costPerUnit : asset.lastPrice)
            seed.asset = asset
            context.insert(seed)
        }
        let q = abs(Money.parse(qtyText) ?? 0)
        let target = lot ?? {
            let n = AssetLot(date: date, quantity: 0, price: 0)
            n.asset = asset
            context.insert(n)
            return n
        }()
        target.quantity = isBuy ? q : -q
        target.price = Money.parse(priceText) ?? 0
        target.fee = Money.parse(feeText) ?? 0
        target.date = date
        target.note = note
        try? context.save()
        asset.recomputeFromLots()
        try? context.save()
        dismiss()
    }
}
