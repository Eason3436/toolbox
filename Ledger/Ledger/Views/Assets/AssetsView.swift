import SwiftUI
import SwiftData

struct AssetsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Asset.order) private var assets: [Asset]
    @Query(sort: \Account.order) private var accounts: [Account]
    @Query private var entries: [Entry] // 讓帳戶餘額變動時重新計算
    @AppStorage(Prefs.hideAmountsKey) private var hidden = false

    @State private var filter: AssetGroup?
    @State private var expandedID: String?
    @State private var refreshing = false
    @State private var lastRefresh: Date? = UserDefaults.standard.object(forKey: QuoteService.lastRefreshKey) as? Date
    @State private var failed: [String] = []
    @State private var addingKind: AssetKind?
    @State private var editing: Asset?

    private var groups: [AssetGroupSummary] {
        _ = entries.count
        return AssetMath.groups(assets: assets, accounts: accounts.filter { !$0.archived })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    summary
                    chips
                    groupCards
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .refreshable { await refresh() }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(filter?.label ?? "資產")
            .toolbarTitleMenu {
                Button("全部資產") { filter = nil }
                ForEach(groups) { g in
                    Button(g.group.label) { filter = g.group }
                }
            }
            .toolbar {
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
            .sheet(item: $editing) { AssetEditor(asset: $0) }
        }
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
            Text(Money.format(total, hidden: hidden))
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.5)

            if positiveTotal > 0 {
                GeometryReader { geo in
                    HStack(spacing: 3) {
                        ForEach(positive) { g in
                            Capsule().fill(g.group.color)
                                .frame(width: max(6, (geo.size.width - CGFloat(positive.count - 1) * 3) * g.total / positiveTotal))
                        }
                    }
                }
                .frame(height: 14)

                FlowLayout(spacing: 14, leading: true) {
                    ForEach(positive) { g in
                        HStack(spacing: 6) {
                            Circle().fill(g.group.color).frame(width: 10, height: 10)
                            Text("\(g.group.label) \(Money.percent(g.total / positiveTotal))")
                                .foregroundStyle(.secondary)
                        }
                        .font(.title3)
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
                                .foregroundStyle(.black)
                                .background(.white, in: .capsule)
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

