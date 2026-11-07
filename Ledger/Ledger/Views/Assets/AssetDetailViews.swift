import SwiftUI
import SwiftData

struct AssetGroupDetailView: View {
    var group: AssetGroup
    @Environment(\.modelContext) private var context
    @Query(sort: \Asset.order) private var assets: [Asset]
    @Query(sort: \Account.order) private var accounts: [Account]
    @AppStorage(Prefs.hideAmountsKey) private var hidden = false
    @State private var editing: Asset?
    @State private var editingAccount: Account?
    @State private var adding = false

    var body: some View {
        let summary = AssetMath.groups(assets: assets, accounts: accounts.filter { !$0.archived }).first { $0.group == group }
        List {
            if let summary {
                Section {
                    HStack {
                        Text("合計").foregroundStyle(.secondary)
                        Spacer()
                        Text(Money.format(summary.total, hidden: hidden)).font(.title2.weight(.bold)).monospacedDigit()
                    }
                }
                Section {
                    ForEach(summary.lines) { line in
                        Button {
                            if let a = line.asset { editing = a } else if let acc = line.account { editingAccount = acc }
                        } label: {
                            HStack(spacing: 14) {
                                CategoryIcon(symbol: line.symbol, color: group.color, size: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(line.name).font(.body.weight(.semibold))
                                    Text(line.detail).font(.footnote).foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(Money.format(line.value, hidden: hidden)).monospacedDigit().font(.body.weight(.semibold))
                                    if let ch = line.dayChange {
                                        Text((ch >= 0 ? "▲ " : "▼ ") + Money.percent(abs(ch), digits: 2))
                                            .font(.footnote.weight(.semibold))
                                            .foregroundStyle(ch >= 0 ? .red : .green)
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)
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
                    if group == .cash || group == .liability {
                        Text("帳戶餘額會自動算進資產。")
                    }
                }
            } else {
                EmptyHint(symbol: group.symbol, title: "沒有\(group.label)資產", message: "按右上角的 ＋ 新增")
            }
        }
        .navigationTitle(group.label)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("新增", systemImage: "plus") { adding = true }
            }
        }
        .sheet(item: $editing) { AssetEditor(asset: $0) }
        .sheet(item: $editingAccount) { AccountEditor(account: $0) }
        .sheet(isPresented: $adding) {
            AssetEditor(asset: nil, initialKind: AssetKind.allCases.first { $0.group == group } ?? .other)
        }
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
        .sheet(item: $editing) { AssetEditor(asset: $0) }
    }
}
