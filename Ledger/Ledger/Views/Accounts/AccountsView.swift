import SwiftUI
import SwiftData

struct AccountsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Account.order) private var allAccounts: [Account]
    @Query(sort: \Budget.order) private var budgets: [Budget]
    @Query(sort: \Goal.order) private var goals: [Goal]
    @Query(sort: \Loan.date, order: .reverse) private var loans: [Loan]
    @Query(sort: \Entry.date, order: .reverse) private var allEntries: [Entry]
    @AppStorage(Prefs.selectedAccountKey) private var selectedID: String = ""
    @AppStorage(Prefs.defaultAccountKey) private var defaultID: String = ""
    @AppStorage(Prefs.hideAmountsKey) private var hidden = false
    @AppStorage(HomeLayout.key) private var layoutRaw = ""
    @AppStorage(HomeLayout.txCountKey) private var txCount = 8
    @AppStorage("homeSortByAmount") private var sortByAmount = false

    @State private var showTransfer = false
    @State private var showSettings = false
    @State private var showLayout = false
    @State private var editingAccount: Account?
    @State private var deletingAccount: Account?
    @State private var addingAccount = false
    @State private var editingEntry: Entry?
    @State private var showAllEntries = false
    @State private var chartRange: PriceRange = .m1
    @State private var pieIncome = false

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
                    EmptyHint(symbol: "creditcard", title: "還沒有帳戶", message: "點左上角的標題新增第一個帳戶")
                }
            }
            .ledgerNavigation(account?.name ?? "帳戶")
            .toolbar {
                HeaderTitle(title: account?.name ?? "帳戶") {
                    ForEach(accounts) { acc in
                        Button {
                            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                                selectedID = acc.id.uuidString
                            }
                        } label: {
                            Label(acc.name, systemImage: acc.id == account?.id ? "checkmark" : acc.kind.symbol)
                        }
                    }
                    Divider()
                    Button("新增帳戶", systemImage: "plus") { addingAccount = true }
                    if let account {
                        Button("編輯「\(account.name)」", systemImage: "pencil") { editingAccount = account }
                        Button("刪除「\(account.name)」", systemImage: "trash", role: .destructive) { deletingAccount = account }
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Picker("交易排序", selection: $sortByAmount) {
                            Label("依日期", systemImage: "calendar").tag(false)
                            Label("依金額", systemImage: "dollarsign").tag(true)
                        }
                        if let account {
                            Button {
                                defaultID = account.id.uuidString
                            } label: {
                                Label(account.id.uuidString == defaultID ? "捷徑預設帳戶 ✓" : "設為捷徑預設帳戶",
                                      systemImage: "star.circle")
                            }
                        }
                        Divider()
                        Button("自訂主頁", systemImage: "square.grid.2x2") { showLayout = true }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showTransfer) { TransferEditor(from: account) }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showLayout) { NavigationStack { HomeLayoutView() } }
            .sheet(item: $editingAccount) { AccountEditor(account: $0) }
            .accountDeleteDialog($deletingAccount)
            .sheet(isPresented: $addingAccount) { AccountEditor(account: nil) }
            .sheet(item: $editingEntry) { EntryDetailView(entry: $0) }
        }
    }

    @ViewBuilder
    private func content(_ account: Account) -> some View {
        let month = DateText.monthInterval(.now)
        let monthEntries = ((account.entries ?? []) + (account.incomingTransfers ?? []))
            .filter { month.contains($0.date) }
        let items = HomeLayout.decode(layoutRaw).filter(\.visible)

        VStack(spacing: 16) {
            if accounts.count > 1 {
                AccountCarousel(accounts: accounts, selectedID: $selectedID, hidden: hidden)
                    .appearEffect()
            }
            summary(account, month: month, monthEntries: monthEntries)
                .appearEffect()
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                section(item.section, account: account, monthEntries: monthEntries)
                    .appearEffect(delay: min(Double(i + 1) * 0.04, 0.3))
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 24)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: account.id)
        .animation(.snappy, value: layoutRaw)
    }

    private func summary(_ account: Account, month: DateInterval, monthEntries: [Entry]) -> some View {
        let startBalance = account.balance(before: month.start)
        let inflow = monthEntries.map { $0.signedAmount(for: account) }.filter { $0 > 0 }.reduce(0, +)
        let spent = abs(monthEntries.map { $0.signedAmount(for: account) }.filter { $0 < 0 }.reduce(0, +))
        let base = startBalance + inflow
        let usedRatio = base > 0 ? spent / base : (spent > 0 ? 1 : 0)
        let cur = account.currency
        let today = Calendar.current.startOfDay(for: .now)
        let todaySpent = abs(monthEntries.filter { $0.date >= today }.map { $0.signedAmount(for: account) }.filter { $0 < 0 }.reduce(0, +))
        let tint: Color = usedRatio > 0.9 ? .red : (usedRatio > 0.7 ? .orange : .green)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("目前餘額").font(.subheadline).foregroundStyle(.secondary)
                    MoneyText(value: account.balance, currency: cur, hidden: hidden,
                              font: .system(size: 40, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                Spacer()
                EyeButton(hidden: $hidden)
            }

            // 本月用掉多少的進度條
            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(.tertiarySystemFill))
                        Capsule().fill(tint.gradient)
                            .frame(width: max(8, g.size.width * min(usedRatio, 1)))
                    }
                }
                .frame(height: 8)
                HStack {
                    Text("本月已用 \(Money.percent(min(usedRatio, 9.99)))")
                    Spacer()
                    Text("今天花了 \(Money.format(todaySpent, currency: cur, hidden: hidden))")
                }
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                statTile("月初", startBalance, "calendar", .blue, cur)
                statTile("流入", inflow, "arrow.down.left", .green, cur)
                statTile("支出", spent, "arrow.up.right", .orange, cur)
            }
        }
        .cardStyle()
    }

    private func statTile(_ title: String, _ value: Double, _ symbol: String, _ color: Color, _ cur: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
            MoneyText(value: value, currency: cur, hidden: hidden, font: .subheadline.weight(.bold))
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(color.opacity(0.1), in: .rect(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private func section(_ s: HomeSection, account: Account, monthEntries: [Entry]) -> some View {
        switch s {
        case .quickActions: QuickAddRow()
        case .upcomingBills: UpcomingBillsCard(hidden: hidden)
        case .transactions: transactions(account, monthEntries: monthEntries)
        case .balanceChart:
            ValueLineCard(title: "餘額走勢", points: History.accountHistory(account, range: chartRange),
                          currency: account.currency, hidden: hidden, range: $chartRange)
        case .categoryPie:
            CategoryDonutCard(entries: monthEntries.filter { $0.account?.id == account.id },
                              currency: account.currency, hidden: hidden, title: "本月分類比例", income: $pieIncome)
        case .merchants:
            merchantsSection(account, monthEntries: monthEntries)
        case .transfer:
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
            .pressable()
        case .accountCard:
            AccountCard(account: account, hidden: hidden, compact: true)
                .id(account.id)
                .transition(.asymmetric(insertion: .scale(scale: 0.95).combined(with: .opacity), removal: .opacity))
                .onTapGesture { editingAccount = account }
        case .budgets: budgetsSection
        case .goals: goalsSection
        case .loans: loansSection
        }
    }

    @ViewBuilder
    private func transactions(_ account: Account, monthEntries: [Entry]) -> some View {
        let sorted = sortByAmount
            ? monthEntries.sorted { abs($0.signedAmount(for: account)) > abs($1.signedAmount(for: account)) }
            : monthEntries.sorted { $0.date > $1.date }
        let limit = max(txCount, 1)
        let shown = showAllEntries ? Array(sorted) : Array(sorted.prefix(limit))
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("本月交易").font(.headline)
                Text("\(sorted.count) 筆").font(.subheadline).foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: Double(sorted.count)))
                Spacer()
            }
            .padding(.horizontal, 4)
            if sorted.isEmpty {
                PlaceholderRow(symbol: "list.bullet.rectangle", text: "本月還沒有交易，按右下角 ＋ 記一筆")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(shown) { e in
                        Button { editingEntry = e } label: {
                            EntryRow(entry: e, perspective: account, hidden: hidden)
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                        if e.id != shown.last?.id { Divider().padding(.leading, 54) }
                    }
                    if sorted.count > limit {
                        Divider()
                        Button {
                            withAnimation(.snappy) { showAllEntries.toggle() }
                        } label: {
                            HStack(spacing: 4) {
                                Text(showAllEntries ? "收合" : "顯示全部 \(sorted.count) 筆")
                                Image(systemName: "chevron.down")
                                    .rotationEffect(.degrees(showAllEntries ? 180 : 0))
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .cardStyle()
            }
        }
    }

    /// 本月在哪些商家花了多少，點進去看該商家的所有紀錄、地圖
    @ViewBuilder
    private func merchantsSection(_ account: Account, monthEntries: [Entry]) -> some View {
        let spends = monthEntries.filter { $0.kind == .expense && $0.account?.id == account.id }
        let groups = Dictionary(grouping: spends) { $0.title.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.key.isEmpty }
            .map { (name: $0.key, total: $0.value.reduce(0) { $0 + $1.amount }, count: $0.value.count,
                    symbol: $0.value.first?.category?.symbol ?? "bag.fill",
                    color: $0.value.first?.category?.color ?? Color.accentColor) }
            .sorted { $0.total > $1.total }
            .prefix(5)
        let top = groups.first?.total ?? 1
        VStack(alignment: .leading, spacing: 10) {
            Text("本月常去商家").font(.headline).padding(.horizontal, 4)
            if groups.isEmpty {
                PlaceholderRow(symbol: "storefront", text: "本月還沒有支出")
            } else {
                VStack(spacing: 12) {
                    ForEach(Array(groups), id: \.name) { m in
                        NavigationLink {
                            MerchantDetailView(merchant: m.name)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: m.symbol)
                                    .font(.subheadline).foregroundStyle(.white)
                                    .frame(width: 34, height: 34)
                                    .background(m.color.gradient, in: .circle)
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(m.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                        Text("\(m.count) 次").font(.caption).foregroundStyle(.secondary)
                                        Spacer()
                                        MoneyText(value: m.total, currency: account.currency, hidden: hidden,
                                                  font: .subheadline.weight(.semibold))
                                    }
                                    GeometryReader { g in
                                        Capsule().fill(m.color.opacity(0.85))
                                            .frame(width: max(6, g.size.width * m.total / max(top, 1)))
                                    }
                                    .frame(height: 5)
                                }
                                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .cardStyle()
            }
        }
    }

    @ViewBuilder
    private var budgetsSection: some View {
        let activeBudgets = budgets.filter { !$0.archived && $0.pinned }
        VStack(spacing: 10) {
            SectionHeader(title: "預算", destination: { BudgetsView() })
            if activeBudgets.isEmpty {
                NavigationLink { BudgetsView() } label: {
                    PlaceholderRow(symbol: "chart.pie", text: "設定每月預算，掌握花費進度")
                }
                .pressable()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(activeBudgets) { b in
                            NavigationLink { BudgetDetailView(budget: b) } label: {
                                BudgetCard(budget: b, entries: allEntries, hidden: hidden)
                                    .containerRelativeFrame(.horizontal) { w, _ in activeBudgets.count == 1 ? w : w * 0.82 }
                            }
                            .pressable()
                        }
                    }
                }
                .scrollClipDisabled()
                .scrollTargetBehavior(.viewAligned)
            }
        }
    }

    @ViewBuilder
    private var goalsSection: some View {
        let activeGoals = goals.filter { !$0.archived }
        VStack(spacing: 10) {
            SectionHeader(title: "儲蓄目標", destination: { GoalsView() })
            if activeGoals.isEmpty {
                NavigationLink { GoalsView() } label: {
                    PlaceholderRow(symbol: "target", text: "建立存錢目標，追蹤進度")
                }
                .pressable()
            } else {
                ForEach(activeGoals.prefix(3)) { g in
                    NavigationLink { GoalsView() } label: { GoalRow(goal: g, hidden: hidden) }
                        .pressable()
                }
            }
        }
    }

    @ViewBuilder
    private var loansSection: some View {
        let open = loans.filter { !$0.closed && $0.remaining > 0 }
        VStack(spacing: 10) {
            SectionHeader(title: "借貸", destination: { LoansView() })
            if open.isEmpty {
                NavigationLink { LoansView() } label: {
                    PlaceholderRow(symbol: "person.2", text: "記下借出與借入，誰還沒還一目了然")
                }
                .pressable()
            } else {
                let lent = open.filter { $0.direction == .lent }.reduce(0) { $0 + $1.remaining }
                let borrowed = open.filter { $0.direction == .borrowed }.reduce(0) { $0 + $1.remaining }
                NavigationLink { LoansView() } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("別人欠我").font(.subheadline).foregroundStyle(.secondary)
                            MoneyText(value: lent, hidden: hidden, font: .title2.weight(.bold)).foregroundStyle(.green)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("我欠別人").font(.subheadline).foregroundStyle(.secondary)
                            MoneyText(value: borrowed, hidden: hidden, font: .title2.weight(.bold)).foregroundStyle(.red)
                        }
                    }
                    .foregroundStyle(.primary)
                    .cardStyle()
                }
                .pressable()
            }
        }
    }
}

// MARK: - 自訂主頁

struct HomeLayoutView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(HomeLayout.key) private var layoutRaw = ""
    @AppStorage(HomeLayout.txCountKey) private var txCount = 8
    @AppStorage(HomeLayout.startTabKey) private var startTab = AppTab.accounts.rawValue
    @AppStorage(HomeLayout.rollNumbersKey) private var rollNumbers = true
    @State private var items: [HomeItem] = []

    var body: some View {
        List {
            Section {
                ForEach($items) { $item in
                    HStack(spacing: 14) {
                        Image(systemName: item.section.symbol)
                            .foregroundStyle(item.visible ? Color.accentColor : .secondary)
                            .frame(width: 28)
                        Text(item.section.label)
                            .foregroundStyle(item.visible ? .primary : .secondary)
                        Spacer()
                        Toggle("", isOn: $item.visible).labelsHidden()
                    }
                }
                .onMove { items.move(fromOffsets: $0, toOffset: $1) }
            } header: {
                Text("主頁卡片")
            } footer: {
                Text("按住右邊的 ≡ 拖曳調整順序，關掉的卡片不會顯示。最上面的餘額摘要固定不動。")
            }

            Section("主頁") {
                Picker("交易顯示筆數", selection: $txCount) {
                    ForEach([3, 5, 8, 15, 30], id: \.self) { Text("\($0) 筆").tag($0) }
                }
            }

            Section {
                Picker("打開 App 時的分頁", selection: $startTab) {
                    ForEach(AppTab.allCases, id: \.self) { Label($0.label, systemImage: $0.symbol).tag($0.rawValue) }
                }
                Toggle("進頁面時數字滾動", isOn: $rollNumbers)
            } header: {
                Text("其他")
            } footer: {
                Text("關掉後金額會直接顯示，不會從 0 滾上來；數值變動時仍然有滾動效果。")
            }

            Section {
                Button("恢復預設", role: .destructive) {
                    withAnimation { items = HomeLayout.defaultItems }
                    txCount = 8
                    rollNumbers = true
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("自訂主頁")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button(role: .confirm) { dismiss() } }
        }
        .onAppear { items = HomeLayout.decode(layoutRaw) }
        .onChange(of: items) { _, new in layoutRaw = HomeLayout.encode(new) }
    }
}

struct SectionHeader<D: View>: View {
    var title: String
    @ViewBuilder var destination: () -> D
    var showsLink = true

    var body: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            if showsLink {
                NavigationLink {
                    destination()
                } label: {
                    HStack(spacing: 3) {
                        Text("全部")
                        Image(systemName: "chevron.right").font(.footnote.weight(.bold))
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                }
            }
        }
        .padding(.top, 8)
        .padding(.horizontal, 4)
    }
}

struct PlaceholderRow: View {
    var symbol: String
    var text: String
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.title2).foregroundStyle(Color.accentColor).frame(width: 32)
            Text(text).foregroundStyle(.secondary)
            Spacer()
            Image(systemName: "plus.circle.fill").font(.title2).foregroundStyle(Color.accentColor)
        }
        .cardStyle(padding: 18)
    }
}

// MARK: - 帳戶卡片

struct AccountCard: View {
    var account: Account
    var hidden: Bool
    /// 主頁用的小卡片
    var compact: Bool = false

    var body: some View {
        if compact { compactBody } else { fullBody }
    }

    private var compactBody: some View {
        HStack(spacing: 14) {
            Image(systemName: account.kind.symbol)
                .font(.title2)
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.15), in: .rect(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(account.name).font(.headline)
                Text(account.cardLast4.isEmpty ? account.kind.label : "•••• \(account.cardLast4)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                MoneyText(value: account.balance, currency: account.currency, hidden: hidden, font: .headline)
                Text(account.currency).font(.caption.weight(.bold)).kerning(1.5).foregroundStyle(.white.opacity(0.7))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background { GradientCardBackground(color: account.color) }
        .clipShape(.rect(cornerRadius: 24, style: .continuous))
        .contentShape(.rect)
    }

    private var fullBody: some View {
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
                        Text(account.name).font(.headline)
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


/// 首頁最上面的帳戶列：左右滑或點一下切換帳戶
struct AccountCarousel: View {
    var accounts: [Account]
    @Binding var selectedID: String
    var hidden: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(accounts) { a in
                    let on = a.id.uuidString == selectedID || (selectedID.isEmpty && a.id == accounts.first?.id)
                    Button {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { selectedID = a.id.uuidString }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: a.kind.symbol)
                                .font(.caption.weight(.bold)).foregroundStyle(.white)
                                .frame(width: 26, height: 26)
                                .background(a.color.gradient, in: .circle)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(a.name).font(.caption.weight(.semibold)).lineLimit(1)
                                Text(Money.format(a.balance, currency: a.currency, hidden: hidden))
                                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                        .padding(.leading, 6).padding(.trailing, 12).padding(.vertical, 6)
                        .background(on ? a.color.opacity(0.16) : Color(.secondarySystemGroupedBackground), in: .capsule)
                        .overlay(Capsule().strokeBorder(a.color.opacity(on ? 0.9 : 0), lineWidth: 1.5))
                    }
                    .buttonStyle(ChipPressStyle())
                    .id(a.id.uuidString)
                }
            }
            .padding(.horizontal, 2).padding(.vertical, 2)
        }
        .scrollClipDisabled()
        .sensoryFeedback(.selection, trigger: selectedID)
    }
}

/// 快速記帳：一句話、掃發票、一般記帳
struct QuickAddRow: View {
    @Environment(\.openAddEntry) private var openAdd

    var body: some View {
        HStack(spacing: 10) {
            item("一句話記帳", "text.bubble.fill", .accentColor) { openAdd(.sentence) }
            item("掃發票", "doc.text.viewfinder", .orange) { openAdd(.scan) }
            item("記一筆", "plus.circle.fill", .green) { openAdd(.normal) }
        }
    }

    private func item(_ title: String, _ symbol: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.title3).foregroundStyle(color)
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(ChipPressStyle())
    }
}

/// 7 天內要付（或要收）的帳單
struct UpcomingBillsCard: View {
    var hidden: Bool
    @Query private var bills: [Bill]
    @Environment(\.modelContext) private var context

    var body: some View {
        let start = Calendar.current.startOfDay(for: .now)
        let end = Calendar.current.date(byAdding: .day, value: 7, to: start) ?? start
        let list = BillService.occurrences(bills, in: DateInterval(start: start, end: end)).filter { !$0.paid }
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("7 天內到期").font(.headline)
                    Text("\(list.count) 筆").font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
                VStack(spacing: 10) {
                    ForEach(list.prefix(4)) { occ in
                        HStack(spacing: 12) {
                            VStack(spacing: 0) {
                                Text("\(Calendar.current.component(.month, from: occ.due))月").font(.caption2).foregroundStyle(.secondary)
                                Text("\(Calendar.current.component(.day, from: occ.due))").font(.headline.monospacedDigit())
                            }
                            .frame(width: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(occ.bill.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text(dueText(occ.due)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(Money.format(occ.bill.amount, hidden: hidden))
                                .font(.callout.weight(.semibold)).monospacedDigit()
                                .foregroundStyle(occ.bill.receives ? .green : .primary)
                            Button(occ.bill.doneLabel) {
                                withAnimation(.snappy) { BillService.markPaid(occ, context: context) }
                            }
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.glass)
                        }
                    }
                }
                .cardStyle()
            }
        }
    }

    private func dueText(_ d: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: .now), to: Calendar.current.startOfDay(for: d)).day ?? 0
        switch days {
        case ..<1: return "今天"
        case 1: return "明天"
        default: return "\(days) 天後"
        }
    }
}
