import SwiftUI
import SwiftData

struct AssetsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Asset.order) private var assets: [Asset]
    @Query(sort: \Account.order) private var accounts: [Account]
    @Query private var entries: [Entry] // 讓帳戶餘額變動時重新計算
    @AppStorage(Prefs.hideAmountsKey) private var hidden = false
    @AppStorage(AssetGroup.namesKey) private var groupNames = "" // 改名後重畫

    @State private var filter: AssetGroup?
    @State private var expandedID: String?
    @State private var refreshing = false
    @State private var lastRefresh: Date? = UserDefaults.standard.object(forKey: QuoteService.lastRefreshKey) as? Date
    @State private var failed: [String] = []
    @State private var addingKind: AssetKind?
    @State private var editing: Asset?
    @State private var netRange: PriceRange = .m3
    @State private var netPoints: [ValuePoint] = []
    @State private var netLoading = false

    private var groups: [AssetGroupSummary] {
        _ = entries.count
        return AssetMath.groups(assets: assets, accounts: accounts.filter { !$0.archived })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    summary
                    if filter == nil {
                        ValueLineCard(title: "總資產走勢", points: netPoints, hidden: hidden,
                                      loading: netLoading, risingRed: true, range: $netRange)
                            .task(id: "\(netRange.rawValue)-\(assets.count)-\(entries.count)") { await loadNetWorth() }
                    }
                    chips
                    groupCards
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .refreshable { await refresh() }
            .background(Palette.background)
            .ledgerNavigation(filter?.label ?? "資產")
            .toolbar {
                HeaderTitle(title: filter?.label ?? "資產") {
                    Button("全部資產") { filter = nil }
                    ForEach(groups) { g in
                        Button(g.group.label) { filter = g.group }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await refresh() }
                    } label: {
                        HStack(spacing: 6) {
                            if refreshing {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text(lastRefresh.map { "報價 \(timeText($0))" } ?? "更新報價")
                                .font(.subheadline.weight(.medium))
                                .monospacedDigit()
                        }
                        .padding(.horizontal, 6)
                    }
                    .disabled(refreshing)
                }
            }
            .task(id: scenePhase) {
                // 畫面開著時每 60 秒自動更新一次報價
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    if assets.contains(where: \.usesQuote) || accounts.contains(where: { $0.currency != Prefs.mainCurrency }) {
                        await refresh()
                    }
                    try? await Task.sleep(for: .seconds(60))
                }
            }
            .sheet(item: $addingKind) { AssetEditor(asset: nil, initialKind: $0) }
            .sheet(item: $editing) { AssetDetailView(asset: $0) }
        }
    }

    private func loadNetWorth() async {
        netLoading = true
        let pts = await History.netWorthHistory(range: netRange)
        withAnimation(.easeInOut(duration: 0.35)) { netPoints = pts }
        netLoading = false
    }

    private func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        let r = await QuoteService.refreshAll(context: context)
        failed = r.failed
        lastRefresh = .now
        refreshing = false
    }

    private func timeText(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "M/d HH:mm"
        return f.string(from: d)
    }

    // MARK: 摘要

    private var summary: some View {
        let gs = groups
        let total = gs.reduce(0) { $0 + $1.total }
        let positive = gs.filter { $0.total > 0 }
        let positiveTotal = positive.reduce(0) { $0 + $1.total }
        let quoted = assets.filter(\.usesQuote)

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("總資產").foregroundStyle(.secondary).font(.title3)
                Spacer()
                EyeButton(hidden: $hidden).scaleEffect(0.8).frame(height: 30)
            }
            MoneyText(value: total, hidden: hidden, font: .system(size: 48, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if let day = dayChange {
                todayRow(day)
            }

            if positiveTotal > 0 {
                GeometryReader { geo in
                    HStack(spacing: 3) {
                        ForEach(positive) { g in
                            Capsule().fill(g.group.color)
                                .frame(width: max(6, (geo.size.width - CGFloat(positive.count - 1) * 3) * g.total / positiveTotal))
                        }
                    }
                }
                .frame(height: 10)

                FlowLayout(spacing: 14, leading: true) {
                    ForEach(positive) { g in
                        HStack(spacing: 6) {
                            Circle().fill(g.group.color).frame(width: 8, height: 8)
                            Text(g.group.label).foregroundStyle(.secondary)
                            Text(Money.percent(g.total / positiveTotal)).monospacedDigit()
                        }
                        .font(.footnote)
                    }
                }
            }
            Divider()
            HStack {
                Image(systemName: "bolt.fill").foregroundStyle(.orange)
                Group {
                    if quoted.isEmpty {
                        Text("加入股票代號即可自動報價")
                    } else {
                        Text("\(quoted.count)項自動報價・\(lastRefresh.map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: .now) } ?? "尚未更新")")
                    }
                }
                .foregroundStyle(.secondary)
                .lineLimit(1)
                Spacer()
                NavigationLink {
                    PortfolioView()
                } label: {
                    HStack(spacing: 4) {
                        Text("投資組合")
                        Image(systemName: "chevron.right")
                    }
                    .font(.headline)
                    .foregroundStyle(Color.accentColor)
                }
            }
            .font(.body)
            if !failed.isEmpty {
                Text("無法更新：\(failed.joined(separator: "、"))").font(.footnote).foregroundStyle(.red)
            }
        }
        .cardStyle()
    }

    // MARK: 今日損益

    private struct DayChange {
        var amount: Double
        var ratio: Double
        var today: Bool
        /// 還沒拿到成交時間（剛更新 App、報價還沒抓）
        var known: Bool
    }

    /// 有自動報價的投資：今天（或上個交易日）漲跌了多少，換成主幣別
    private var dayChange: DayChange? {
        let list: [Asset] = assets.filter { a in
            a.usesQuote && a.previousClose > 0 && a.lastPrice > 0 && (filter == nil || a.kind.group == filter)
        }
        guard !list.isEmpty else { return nil }
        var amount = 0.0
        var base = 0.0
        for a in list {
            let rate = QuoteService.rate(from: a.currency)
            amount += (a.lastPrice - a.previousClose) * a.quantity * rate
            base += a.previousClose * a.quantity * rate
        }
        let today = list.contains { QuoteService.tradedToday($0) }
        let known = list.contains { QuoteService.marketTime(of: $0) != nil }
        return DayChange(amount: amount, ratio: base > 0 ? amount / base : 0, today: today, known: known)
    }

    private func todayRow(_ d: DayChange) -> some View {
        let up = d.amount >= 0
        let color: Color = abs(d.amount) < 0.5 ? .secondary : (up ? .red : .green)
        return HStack(spacing: 8) {
            Text(d.today || !d.known ? "今日" : "上個交易日").foregroundStyle(.secondary)
            Image(systemName: up ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                .font(.caption)
                .foregroundStyle(color)
            Text(Money.format(d.amount, hidden: hidden, signed: true))
                .foregroundStyle(color)
                .contentTransition(.numericText(value: d.amount))
            Text("(\(up ? "+" : "")\(Money.percent(d.ratio, digits: 2)))")
                .foregroundStyle(color)
            if d.known && !d.today {
                Text("・今天沒開盤").foregroundStyle(.tertiary)
            }
        }
        .font(.headline)
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .animation(.snappy, value: d.amount)
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                FilterChip(title: "全部", selected: filter == nil) { withAnimation(.snappy) { filter = nil } }
                ForEach(groups) { g in
                    FilterChip(title: g.group.label, selected: filter == g.group) { withAnimation(.snappy) { filter = g.group } }
                }
            }
        }
        .scrollClipDisabled()
    }

    // MARK: 分組卡片（疊在一起）

    private var groupCards: some View {
        let list = groups.filter { filter == nil || $0.group == filter }
        let overlap: CGFloat = 36
        let current = list.contains(where: { $0.id == expandedID }) ? expandedID : list.last?.id
        let total = max(groups.filter { $0.total > 0 }.reduce(0) { $0 + $1.total }, 1)
        return VStack(spacing: -overlap) {
            if list.isEmpty {
                EmptyHint(symbol: "briefcase", title: "還沒有資產", message: "按右下角的 ＋ 加入股票、ETF、加密貨幣或其他資產")
            }
            ForEach(Array(list.enumerated()), id: \.element.id) { i, g in
                let expanded = g.id == current
                let isLast = i == list.count - 1
                AssetGroupCard(summary: g, ratio: g.total / total, expanded: expanded, hidden: hidden,
                               bottomInset: isLast ? 0 : overlap,
                               onAdd: { addingKind = g.group == .finance ? .stock : (g.group == .cash ? .cash : (g.group == .property ? .property : (g.group == .liability ? .loan : .other))) },
                               onSelectAsset: { editing = $0 })
                    .frame(height: expanded ? nil : 110 + overlap, alignment: .top)
                    .zIndex(Double(i))
                    .onTapGesture {
                        withAnimation(.spring(duration: 0.4, bounce: 0.2)) { expandedID = g.id }
                    }
            }
        }
    }
}

struct AssetGroupCard: View {
    var summary: AssetGroupSummary
    var ratio: Double
    var expanded: Bool
    var hidden: Bool
    var bottomInset: CGFloat
    var onAdd: () -> Void
    var onSelectAsset: (Asset) -> Void

    var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 14) {
                    CategoryIcon(symbol: summary.group.symbol, color: .white, size: 56, onDark: true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(summary.group.label).font(.title3.weight(.semibold))
                        Text("\(summary.lines.count)項資產").foregroundStyle(.white.opacity(0.7))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(Money.format(summary.total, hidden: hidden))
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                        DarkPill(text: hidden ? "••" : Money.percent(ratio, digits: abs(ratio) < 0.01 ? 1 : 0))
                    }
                }

                if expanded {
                    VStack(spacing: 12) {
                        ForEach(summary.lines) { line in
                            Button {
                                if let a = line.asset { onSelectAsset(a) }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(line.name).font(.headline)
                                        Text(line.detail).font(.footnote).foregroundStyle(.white.opacity(0.65))
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(Money.format(line.value, hidden: hidden)).font(.headline).monospacedDigit()
                                        if let ch = line.dayChange {
                                            Text((ch >= 0 ? "▲ " : "▼ ") + Money.percent(abs(ch), digits: 2))
                                                .font(.footnote.weight(.semibold))
                                                .foregroundStyle(ch >= 0 ? Color(hex: "#FF8A80") : Color(hex: "#A5D6A7"))
                                        } else if line.currency != Prefs.mainCurrency {
                                            Text("\(line.currency) \(Money.format(line.nativeValue, currency: line.currency, hidden: hidden))")
                                                .font(.footnote).foregroundStyle(.white.opacity(0.65))
                                        }
                                    }
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 26)
                    .padding(.bottom, 20)

                    HStack(spacing: 12) {
                        NavigationLink {
                            AssetGroupDetailView(group: summary.group)
                        } label: {
                            Text("查看資產")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .foregroundStyle(Palette.onDarkButtonText)
                                .background(Palette.onDarkButton, in: .capsule)
                        }
                        Button(action: onAdd) {
                            Image(systemName: "plus")
                                .font(.title2.weight(.medium))
                                .frame(width: 76, height: 54)
                                .foregroundStyle(.white)
                                .background(.black.opacity(0.4), in: .capsule)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .foregroundStyle(.white)
            .padding(26)
            .padding(.bottom, expanded ? bottomInset : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(alignment: .bottomTrailing) {
                ZStack(alignment: .bottomTrailing) {
                    GradientCardBackground(color: summary.group.color)
                    if expanded {
                        Image(systemName: summary.group.symbol)
                            .font(.system(size: 130))
                            .foregroundStyle(.white.opacity(0.08))
                            .padding(.trailing, 30)
                            .padding(.bottom, 90 + bottomInset)
                    }
                }
            }
            .clipShape(.rect(cornerRadius: 30, style: .continuous))
    }
}

