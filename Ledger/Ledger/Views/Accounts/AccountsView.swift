import SwiftUI
import SwiftData

struct AccountsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Account.order) private var allAccounts: [Account]
    @AppStorage(Prefs.selectedAccountKey) private var selectedID: String = ""
    @AppStorage(Prefs.defaultAccountKey) private var defaultID: String = ""
    @AppStorage(Prefs.hideAmountsKey) private var hidden = false

    @State private var sortByAmount = false
    @State private var showTransfer = false
    @State private var showSettings = false
    @State private var editingAccount: Account?
    @State private var addingAccount = false
    @State private var editingEntry: Entry?

    private var accounts: [Account] { allAccounts.filter { !$0.archived } }

    private var account: Account? {
        accounts.first { $0.id.uuidString == selectedID } ?? accounts.first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let account {
                    content(account)
                } else {
                    EmptyHint(symbol: "creditcard", title: "還沒有帳戶", message: "點右上角的選單新增第一個帳戶")
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(account?.name ?? "帳戶")
            .toolbarTitleMenu {
                ForEach(accounts) { acc in
                    Button {
                        selectedID = acc.id.uuidString
                    } label: {
                        Label(acc.name, systemImage: acc.id == account?.id ? "checkmark" : acc.kind.symbol)
                    }
                }
                Divider()
                Button("新增帳戶", systemImage: "plus") { addingAccount = true }
                if let account {
                    Button("編輯「\(account.name)」", systemImage: "pencil") { editingAccount = account }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("排序", selection: $sortByAmount) {
                            Label("依日期", systemImage: "calendar").tag(false)
                            Label("依金額", systemImage: "dollarsign").tag(true)
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                }
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        if let account { defaultID = account.id.uuidString }
                    } label: {
                        Image(systemName: account?.id.uuidString == defaultID ? "star.circle.fill" : "star.circle")
                    }
                    .accessibilityLabel("設為捷徑預設帳戶")
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showTransfer) { TransferEditor(from: account) }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(item: $editingAccount) { AccountEditor(account: $0) }
            .sheet(isPresented: $addingAccount) { AccountEditor(account: nil) }
            .sheet(item: $editingEntry) { EntryEditor(entry: $0) }
        }
    }

    @ViewBuilder
    private func content(_ account: Account) -> some View {
        let month = DateText.monthInterval(.now)
        let monthEntries = ((account.entries ?? []) + (account.incomingTransfers ?? []))
            .filter { month.contains($0.date) }
        let startBalance = account.balance(before: month.start)
        let inflow = monthEntries.map { $0.signedAmount(for: account) }.filter { $0 > 0 }.reduce(0, +)
        let spent = -monthEntries.map { $0.signedAmount(for: account) }.filter { $0 < 0 }.reduce(0, +)
        let base = startBalance + inflow
        let usedRatio = base > 0 ? spent / base : (spent > 0 ? 1 : 0)
        let cur = account.currency

        VStack(spacing: 16) {
            // 摘要
            VStack(alignment: .leading, spacing: 14) {
                Text("剩餘").foregroundStyle(.secondary).font(.title3)
                HStack(spacing: 12) {
                    Text(Money.format(account.balance, currency: cur, hidden: hidden))
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Pill(text: "已使用 \(Money.percent(min(usedRatio, 9.99)))", tint: usedRatio > 0.9 ? .red : .green)
                    Spacer()
                    EyeButton(hidden: $hidden)
                }
                Divider()
                VStack(spacing: 10) {
                    SummaryRow(title: "月初餘額", value: Money.format(startBalance, currency: cur, hidden: hidden))
                    SummaryRow(title: "資金流入", value: Money.format(inflow, currency: cur, hidden: hidden))
                    SummaryRow(title: "已用", value: Money.format(spent, currency: cur, hidden: hidden))
                }
            }
            .cardStyle()

            // 轉帳
            Button { showTransfer = true } label: {
                HStack(spacing: 14) {
                    Image(systemName: "arrow.left.arrow.right")
                    Text("轉帳")
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                }
                .font(.title3)
                .foregroundStyle(.primary)
                .cardStyle(padding: 18)
            }
            .buttonStyle(.plain)

            AccountCard(account: account, hidden: hidden)
                .onTapGesture { editingAccount = account }

            // 本月交易
            let sorted = sortByAmount
                ? monthEntries.sorted { abs($0.signedAmount(for: account)) > abs($1.signedAmount(for: account)) }
                : monthEntries.sorted { $0.date > $1.date }
            if !sorted.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("本月交易").font(.headline).padding(.bottom, 6)
                    ForEach(sorted) { e in
                        Button { editingEntry = e } label: {
                            EntryRow(entry: e, perspective: account, hidden: hidden)
                        }
                        .buttonStyle(.plain)
                        if e.id != sorted.last?.id { Divider().padding(.leading, 58) }
                    }
                }
                .cardStyle()
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 24)
    }
}

// MARK: - 帳戶卡片

struct AccountCard: View {
    var account: Account
    var hidden: Bool

    var body: some View {
        ZStack {
            GradientCardBackground(color: account.color)

            Text(Money.symbol(for: account.currency))
                .font(.system(size: 120, weight: .bold))
                .foregroundStyle(.white.opacity(0.07))
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 24)

            VStack(alignment: .leading) {
                HStack(alignment: .top) {
                    Image(systemName: account.kind.symbol)
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.85))
                    Spacer()
                    DarkPill(text: Money.format(account.balance, currency: account.currency, hidden: hidden))
                }
                Spacer()
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(account.name).font(.title3.weight(.semibold))
                        Text(account.cardLast4.isEmpty ? account.kind.label : "•••• \(account.cardLast4)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    Spacer()
                    Text(account.currency)
                        .font(.callout.weight(.bold))
                        .kerning(2)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .overlay(Capsule().strokeBorder(.white.opacity(0.8), lineWidth: 1.5))
                }
                .foregroundStyle(.white)
            }
            .padding(24)
        }
        .aspectRatio(1.586, contentMode: .fit)
    }
}
