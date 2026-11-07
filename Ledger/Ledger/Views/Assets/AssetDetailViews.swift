import SwiftUI
import SwiftData

struct AssetGroupDetailView: View {
    var group: AssetGroup
    @Environment(\.modelContext) private var context
    @Query(sort: \Asset.order) private var assets: [Asset]
    @Query(sort: \Account.order) private var accounts: [Account]
    @Query private var entries: [Entry]
    @AppStorage(Prefs.hideAmountsKey) private var hidden = false
    @AppStorage(AssetGroup.namesKey) private var groupNames = ""
    @State private var editing: Asset?
    @State private var editingAccount: Account?
    @State private var adding = false

    // 折線圖
    @State private var range: PriceRange = .m3
    @State private var chartLine: String?          // nil = 整個分類合計
    @State private var series: (ends: [Date], values: [String: [Double]]) = ([], [:])
    @State private var loading = false

    // 改名
    @State private var renaming: RenameTarget?
    @State private var newName = ""

    enum RenameTarget: Identifiable {
        case group, account(Account), asset(Asset)
        var id: String {
            switch self {
            case .group: "group"
            case .account(let a): "acc-\(a.id)"
            case .asset(let a): "asset-\(a.id)"
            }
        }
    }

    private var summary: AssetGroupSummary? {
        _ = entries.count
        return AssetMath.groups(assets: assets, accounts: accounts.filter { !$0.archived }).first { $0.group == group }
    }

    var body: some View {
        let summary = summary
        List {
            if let summary {
                Section {
                    HStack {
                        Text("合計").foregroundStyle(.secondary)
                        Spacer()
                        MoneyText(value: summary.total, hidden: hidden, font: .title2.weight(.bold))
                    }
                }
                if group == .finance {
                    Section {
                        NavigationLink { PortfolioInsightView() } label: {
                            Label("AI 投資分析", systemImage: "sparkles")
                                .font(.headline)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                Section {
                    VStack(spacing: 10) {
                        linePicker(summary)
                        ValueLineCard(title: chartTitle(summary), points: points(summary), hidden: hidden,
                                      loading: loading, risingRed: group == .finance, range: $range)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                Section {
                    ForEach(summary.lines) { line in
                        Button {
                            if let a = line.asset { editing = a } else if let acc = line.account { editingAccount = acc }
                        } label: {
                            HStack(spacing: 14) {
                                CategoryIcon(symbol: line.symbol, color: group.color, size: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(line.name).font(.body.weight(.semibold)).lineLimit(2)
                                    Text(line.detail).font(.footnote).foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    MoneyText(value: line.value, hidden: hidden, font: .body.weight(.semibold))
                                    if let ch = line.dayChange {
                                        Text((ch >= 0 ? "▲ " : "▼ ") + Money.percent(abs(ch), digits: 2))
                                            .font(.footnote.weight(.semibold))
                                            .foregroundStyle(ch >= 0 ? .red : .green)
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("重新命名", systemImage: "pencil") { startRename(line) }
                            Button("看折線圖", systemImage: "chart.xyaxis.line") { withAnimation(.snappy) { chartLine = line.id } }
                        }
                        .swipeActions(edge: .leading) {
                            Button("改名", systemImage: "pencil") { startRename(line) }.tint(.blue)
                        }
                        .swipeActions {
                            if let a = line.asset {
                                Button("刪除", systemImage: "trash", role: .destructive) {
                                    context.delete(a)
                                    try? context.save()
                                }
                            }
                        }
                    }
                } footer: {
                    Text(group == .cash || group == .liability
                         ? "帳戶餘額會自動算進資產。長按或往右滑可以改名。"
                         : "長按或往右滑可以改名。")
                }
            } else {
                EmptyHint(symbol: group.symbol, title: "沒有\(group.label)資產", message: "按右上角的 ＋ 新增")
            }
        }
        .navigationTitle(group.label)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("改名", systemImage: "pencil") {
                    newName = group.label
                    renaming = .group
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("新增", systemImage: "plus") { adding = true }
            }
        }
        .task(id: "\(range.rawValue)-\(assets.count)-\(entries.count)") { await load() }
        .alert(renameTitle, isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名稱", text: $newName)
            Button("取消", role: .cancel) { renaming = nil }
            if case .group = renaming {
                Button("恢復預設") { setGroupName("") }
            }
            Button("儲存") { applyRename() }
        }
        .sheet(item: $editing) { AssetDetailView(asset: $0) }
        .sheet(item: $editingAccount) { AccountEditor(account: $0) }
        .sheet(isPresented: $adding) {
            AssetEditor(asset: nil, initialKind: AssetKind.allCases.first { $0.group == group } ?? .other)
        }
    }

    // MARK: 折線圖

    private func linePicker(_ summary: AssetGroupSummary) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(title: "全部\(group.label)", selected: chartLine == nil) {
                    withAnimation(.snappy) { chartLine = nil }
                }
                ForEach(summary.lines) { line in
                    FilterChip(title: line.name, selected: chartLine == line.id) {
                        withAnimation(.snappy) { chartLine = line.id }
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollClipDisabled()
    }

    private func chartTitle(_ summary: AssetGroupSummary) -> String {
        guard let id = chartLine, let line = summary.lines.first(where: { $0.id == id }) else { return "\(group.label)走勢" }
        return "\(line.name)走勢"
    }

    private func points(_ summary: AssetGroupSummary) -> [ValuePoint] {
        let ids = chartLine.map { [$0] } ?? summary.lines.map(\.id)
        return History.sum(ends: series.ends, values: ids.compactMap { series.values[$0] })
    }

    private func load() async {
        guard let summary else { return }
        loading = true
        let r = await History.lineSeries(assets: summary.lines.compactMap(\.asset),
                                         accounts: summary.lines.compactMap(\.account), range: range)
        withAnimation(.easeInOut(duration: 0.35)) { series = r }
        loading = false
    }

    // MARK: 改名

    private var renameTitle: String {
        switch renaming {
        case .group: "分類名稱"
        case .account: "帳戶名稱"
        case .asset: "資產名稱"
        case nil: ""
        }
    }

    private func startRename(_ line: AssetLine) {
        newName = line.name
        if let a = line.asset { renaming = .asset(a) } else if let acc = line.account { renaming = .account(acc) }
    }

    private func applyRename() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        switch renaming {
        case .group: setGroupName(name == group.defaultLabel ? "" : name)
        case .account(let a): if !name.isEmpty { a.name = name }
        case .asset(let a): if !name.isEmpty { a.name = name }
        case nil: break
        }
        try? context.save()
        renaming = nil
    }

    private func setGroupName(_ name: String) {
        var names = AssetGroup.customNames
        names[group.rawValue] = name
        AssetGroup.customNames = names
        groupNames = UserDefaults.standard.string(forKey: AssetGroup.namesKey) ?? ""
        renaming = nil
    }
}

struct PortfolioView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Asset.order) private var assets: [Asset]
    @AppStorage(Prefs.hideAmountsKey) private var hidden = false
    @State private var editing: Asset?

    private var investments: [Asset] { assets.filter { $0.kind.group == .finance } }

    var body: some View {
        let totalValue = investments.reduce(0) { $0 + $1.nativeValue * QuoteService.rate(from: $1.currency) }
        let totalCost = investments.filter { $0.costPerUnit > 0 }.reduce(0) { $0 + $1.costPerUnit * $1.quantity * QuoteService.rate(from: $1.currency) }
        let costedValue = investments.filter { $0.costPerUnit > 0 }.reduce(0) { $0 + $1.nativeValue * QuoteService.rate(from: $1.currency) }
        let dayChange = investments.reduce(0.0) { r, a in
            guard a.usesQuote, a.previousClose > 0 else { return r }
            return r + (a.lastPrice - a.previousClose) * a.quantity * QuoteService.rate(from: a.currency)
        }
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("投資市值").foregroundStyle(.secondary)
                    Text(Money.format(totalValue, hidden: hidden))
                        .font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                    HStack(spacing: 18) {
                        VStack(alignment: .leading) {
                            Text("今日").font(.footnote).foregroundStyle(.secondary)
                            Text(Money.format(dayChange, hidden: hidden, signed: true)).monospacedDigit()
                                .foregroundStyle(dayChange >= 0 ? .red : .green)
                        }
                        if totalCost > 0 {
                            VStack(alignment: .leading) {
                                Text("未實現損益").font(.footnote).foregroundStyle(.secondary)
                                Text("\(Money.format(costedValue - totalCost, hidden: hidden, signed: true))（\(Money.percent((costedValue - totalCost) / totalCost, digits: 2))）")
                                    .monospacedDigit()
                                    .foregroundStyle(costedValue >= totalCost ? .red : .green)
                            }
                        }
                    }
                    .font(.headline)
                }
                .padding(.vertical, 6)
            }
            Section {
                NavigationLink { PortfolioInsightView() } label: {
                    Label("AI 投資分析", systemImage: "sparkles").font(.headline).foregroundStyle(Color.accentColor)
                }
            }
            Section("持股") {
                if investments.isEmpty {
                    Text("還沒有投資資產，到資產頁按 ＋ 加入股票代號。").foregroundStyle(.secondary)
                }
                ForEach(investments) { a in
                    Button { editing = a } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(a.name).font(.body.weight(.semibold))
                                Text(a.usesQuote ? "\(a.ticker) · \(Money.format(a.quantity, currency: "USD")) × \(Money.format(a.lastPrice, currency: "USD"))" : a.kind.label)
                                    .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(Money.format(a.nativeValue, currency: a.currency, hidden: hidden) + (a.currency == Prefs.mainCurrency ? "" : " \(a.currency)"))
                                    .font(.body.weight(.semibold)).monospacedDigit()
                                HStack(spacing: 8) {
                                    if let ch = a.dayChangeRatio {
                                        Text((ch >= 0 ? "▲" : "▼") + Money.percent(abs(ch), digits: 2))
                                            .foregroundStyle(ch >= 0 ? .red : .green)
                                    }
                                    if let p = a.profitRatio {
                                        Text("損益 " + Money.percent(p, digits: 1))
                                            .foregroundStyle(p >= 0 ? .red : .green)
                                    }
                                }
                                .font(.footnote.weight(.medium))
                                .monospacedDigit()
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Section {
                Text("報價來源：Yahoo 財經，台股約延遲 0～20 分鐘。台股紅漲綠跌。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("投資組合")
        .refreshable { _ = await QuoteService.refreshAll(context: context) }
        .sheet(item: $editing) { AssetDetailView(asset: $0) }
    }
}
