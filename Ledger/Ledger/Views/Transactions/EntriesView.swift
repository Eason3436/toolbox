import SwiftUI
import SwiftData

enum EntryFilter: String, CaseIterable, Identifiable {
    case all, expense, income
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: "記帳"
        case .expense: "支出"
        case .income: "收入"
        }
    }
}

struct EntriesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Entry.date, order: .reverse) private var allEntries: [Entry]
    @AppStorage(Prefs.hideAmountsKey) private var hidden = false

    @State private var month = Date.now
    @AppStorage("entriesAllTime") private var allTime = false
    @State private var filter: EntryFilter = .all
    @State private var search = ""
    /// 用一句話搜尋時，模型整理出來的條件
    @State private var smart: EntrySearch.Filter?
    @State private var smartLoading = false
    @State private var smartError: String?
    @State private var editing: Entry?
    @State private var pieIncome = false
    @State private var accountFilter: UUID?
    @State private var payFilter: String?
    @State private var receiptOnly = false
    @Query(sort: \Account.order) private var accounts: [Account]

    private var monthEntries: [Entry] {
        if allTime { return allEntries }
        let interval = DateText.monthInterval(month)
        return allEntries.filter { interval.contains($0.date) }
    }

    private var visible: [Entry] {
        // 搜尋時找全部期間
        let base: [Entry] = search.isEmpty ? monthEntries : allEntries
        return base.filter { e in
            switch filter {
            case .all: true
            case .expense: e.kind == .expense
            case .income: e.kind == .income
            }
        }
        .filter { e in
            if let smart { return smart.matches(e) }
            return search.isEmpty || EntrySearch.text(e, contains: search)
        }
        .filter { e in accountFilter == nil || e.account?.id == accountFilter || e.toAccount?.id == accountFilter }
        .filter { e in payFilter == nil || e.payMethod == payFilter }
        .filter { e in !receiptOnly || e.receiptJSON != nil }
    }

    /// 往右滑複製：同商家、金額、分類、帳戶，時間改成現在
    private func duplicate(_ e: Entry) {
        let copy = Entry(title: e.title, amount: e.amount, kind: e.kind, date: .now, category: e.category,
                         account: e.account, note: e.note)
        copy.toAccount = e.toAccount
        copy.payMethod = e.payMethod
        context.insert(copy)
        try? context.save()
    }

    private var hasFilters: Bool { accountFilter != nil || payFilter != nil || receiptOnly || filter != .all }

    /// 左上角標題：目前看的帳戶
    private var accountTitle: String {
        accounts.first { $0.id == accountFilter }?.name ?? "全部帳戶"
    }

    /// 篩選膠囊：帳戶、付款方式、有發票
    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    Picker("顯示", selection: $filter) {
                        Text("支出和收入").tag(EntryFilter.all)
                        Text("支出").tag(EntryFilter.expense)
                        Text("收入").tag(EntryFilter.income)
                    }
                } label: {
                    Chip(title: filter == .all ? "支出和收入" : filter.label, symbol: "arrow.up.arrow.down",
                         selected: filter != .all, showsChevron: true)
                }
                ForEach(["Apple Pay", "LINE Pay"], id: \.self) { m in
                    Button {
                        payFilter = payFilter == m ? nil : m
                    } label: {
                        Chip(title: m, symbol: m == "Apple Pay" ? "apple.logo" : "l.circle.fill",
                             selected: payFilter == m, tint: m == "Apple Pay" ? Color.primary : Color(hex: "#06C755"))
                    }
                    .buttonStyle(ChipPressStyle())
                }
                Button { receiptOnly.toggle() } label: {
                    Chip(title: "有發票", symbol: "doc.text", selected: receiptOnly)
                }
                .buttonStyle(ChipPressStyle())
                if payFilter != nil || receiptOnly || filter != .all {
                    Button("清除") {
                        withAnimation(.snappy) { filter = .all; payFilter = nil; receiptOnly = false }
                    }
                    .font(.subheadline.weight(.semibold))
                }
            }
            .padding(.horizontal, 2).padding(.vertical, 2)
        }
        .scrollClipDisabled()
        .animation(.snappy, value: hasFilters)
    }

    /// 全部／單月切換；單月時旁邊可以換月份
    private var periodBar: some View {
        HStack(spacing: 10) {
            Picker("期間", selection: $allTime.animation(.snappy)) {
                Text("單月").tag(false)
                Text("全部").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 130)
            Spacer(minLength: 0)
            if !allTime {
                MonthStepper(month: $month)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .padding(.horizontal, 2)
    }

    private var days: [(Date, [Entry])] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: visible) { cal.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0]!.sorted { $0.date > $1.date }) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    summary
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                if !search.isEmpty {
                    Section { smartBar }
                } else {
                    Section {
                        periodBar
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }
                Section {
                    filterChips
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                if days.isEmpty {
                    Section {
                        if hasFilters || !search.isEmpty || filter != .all {
                            EmptyHint(symbol: "line.3.horizontal.decrease.circle", title: "沒有符合的紀錄", message: "換個篩選條件，或按「清除」")
                                .listRowBackground(Color.clear)
                        } else {
                            EmptyHint(symbol: "cart", title: allTime ? "還沒有記帳" : "這個月還沒有記帳", message: "按右下角的 ＋ 記一筆，或在捷徑設定「從通知記帳」自動化")
                                .listRowBackground(Color.clear)
                        }
                    }
                }
                ForEach(days, id: \.0) { day, entries in
                    Section {
                        ForEach(entries) { e in
                            Button { editing = e } label: { EntryRow(entry: e, hidden: hidden) }
                                .buttonStyle(.plain)
                                .swipeActions {
                                    Button("刪除", systemImage: "trash", role: .destructive) {
                                        Haptics.shared.trash(); context.delete(e)
                                        try? context.save()
                                    }
                                }
                                .swipeActions(edge: .leading) {
                                    Button("再記一筆", systemImage: "plus.square.on.square") { duplicate(e) }
                                        .tint(.blue)
                                }
                        }
                    } header: {
                        HStack {
                            Text(DateText.dayHeader(day))
                            Spacer()
                            let net = entries.reduce(0) { $0 + $1.signedAmount }
                            Text(Money.format(net, hidden: hidden, signed: true)).monospacedDigit()
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                }
            }
            .listSectionSpacing(14)
            .scrollContentBackground(.hidden)
            .background(Palette.background)
            .ledgerNavigation(accountTitle)
            .toolbar {
                HeaderTitle(title: accountTitle) {
                    Picker("帳戶", selection: $accountFilter) {
                        Text("全部帳戶").tag(UUID?.none)
                        ForEach(accounts.filter { !$0.archived }) { a in
                            Label(a.name, systemImage: a.kind.symbol).tag(Optional(a.id))
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { LedgerModeToggle() }
            }
            .searchable(text: $search, placement: .navigationBarDrawer, prompt: "搜尋，或說「上個月買的飲料」")
            .onSubmit(of: .search) { runSmartSearch() }
            .onChange(of: search) { old, new in
                smart = nil
                smartError = nil
                if old.isEmpty && !new.isEmpty { EntrySearch.prewarm() }
            }
            .sheet(item: $editing) { EntryDetailView(entry: $0) }
        }
    }

    // MARK: 用一句話搜尋

    private func runSmartSearch() {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard EntrySearch.looksLikeSentence(q), NoticeParser.aiAvailable else { return }
        smartLoading = true
        smartError = nil
        Task {
            defer { smartLoading = false }
            do {
                let f = try await EntrySearch.parse(q)
                // 等待期間使用者改了字就不套用
                guard search.trimmingCharacters(in: .whitespaces) == q else { return }
                withAnimation(.snappy) { smart = f }
            } catch {
                smartError = "看不懂這句，先用關鍵字比對"
            }
        }
    }

    /// 搜尋結果上方：筆數、合計，用一句話搜尋時顯示整理出的條件
    private var smartBar: some View {
        let list: [Entry] = visible
        let spent: Double = list.filter { $0.kind == .expense }.reduce(0) { $0 + $1.amount }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(list.count) 筆").font(.subheadline.weight(.semibold))
                Spacer()
                if smartLoading {
                    ProgressView().controlSize(.small)
                } else if spent > 0 {
                    Text("支出 \(Money.format(spent, hidden: hidden))").font(.subheadline.weight(.semibold)).monospacedDigit()
                }
            }
            if let smart, !smart.summary.isEmpty {
                Label(smart.summary, systemImage: "sparkle.magnifyingglass")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            } else if let smartError {
                Text(smartError).font(.caption).foregroundStyle(.secondary)
            } else if EntrySearch.looksLikeSentence(search) && NoticeParser.aiAvailable && !smartLoading {
                Text("按「搜尋」用整句話找").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var summary: some View {
        let expense = monthEntries.filter { $0.kind == .expense }.reduce(0) { $0 + $1.amount }
        let income = monthEntries.filter { $0.kind == .income }.reduce(0) { $0 + $1.amount }

        return VStack(alignment: .leading, spacing: 14) {
            Text(allTime ? "全部支出" : "本月支出").foregroundStyle(.secondary).font(.title3)
            HStack(spacing: 12) {
                MoneyText(value: expense, hidden: hidden, font: .system(size: 44, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if income > 0 {
                    Pill(text: "結餘 \(Money.format(income - expense, hidden: hidden, signed: true))", tint: income >= expense ? .green : .red)
                }
                Spacer()
                EyeButton(hidden: $hidden)
            }
            Divider()
            SummaryRow(title: "收入", amount: income, hidden: hidden)
            SummaryRow(title: "支出", amount: expense, hidden: hidden)
        }
        .cardStyle()
    }
}

struct EntryRow: View {
    var entry: Entry
    var perspective: Account? = nil
    var hidden: Bool = false
    /// 不在按日分組的清單裡時，時間前面加上日期
    var showsDate: Bool = false

    var body: some View {
        HStack(spacing: 14) {
            if entry.kind == .transfer {
                CategoryIcon(symbol: "arrow.left.arrow.right", color: .blue)
            } else if let g = entry.listGlyph {
                BrandGlyphIcon(glyph: g)
            } else if let c = entry.category {
                c.icon()
            } else {
                CategoryIcon(symbol: "questionmark", color: .gray)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(entry.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if let pm = entry.payMethod {
                        PayBadge(method: pm, compact: true)
                    } else if entry.source == .shortcut {
                        Image(systemName: "bolt.fill").font(.caption).foregroundStyle(.secondary)
                    } else if entry.source == .bill {
                        Image(systemName: "bolt.fill").font(.caption).foregroundStyle(.secondary)
                    }
                    if entry.receiptJSON != nil {
                        Image(systemName: "doc.text").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            let value = perspective.map { entry.signedAmount(for: $0) } ?? entry.signedAmount
            Text(entry.kind == .transfer && perspective == nil
                 ? Money.format(entry.amount, hidden: hidden)
                 : Money.format(value, currency: entry.account?.currency ?? Prefs.mainCurrency, hidden: hidden, signed: true))
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(value > 0 ? .green : .primary)
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }

    private var subtitle: String {
        var parts: [String] = []
        if entry.kind == .transfer {
            parts.append("\(entry.account?.name ?? "?") → \(entry.toAccount?.name ?? "?")")
        } else {
            if let c = entry.category { parts.append(c.name) }
            if let a = entry.account { parts.append(a.name) }
        }
        let f = DateFormatter()
        f.dateFormat = showsDate ? "M/d HH:mm" : "HH:mm"
        parts.append(f.string(from: entry.date))
        return parts.joined(separator: " · ")
    }
}
