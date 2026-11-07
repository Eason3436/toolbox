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
    @State private var filter: EntryFilter = .all
    @State private var search = ""
    @State private var editing: Entry?
    @State private var pieIncome = false

    private var monthEntries: [Entry] {
        let interval = DateText.monthInterval(month)
        return allEntries.filter { interval.contains($0.date) }
    }

    private var visible: [Entry] {
        monthEntries.filter { e in
            switch filter {
            case .all: true
            case .expense: e.kind == .expense
            case .income: e.kind == .income
            }
        }
        .filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.note.localizedCaseInsensitiveContains(search) || ($0.category?.name.contains(search) ?? false) }
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
                if !monthEntries.isEmpty, search.isEmpty {
                    Section {
                        CategoryDonutCard(entries: monthEntries, hidden: hidden, income: $pieIncome)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }
                if days.isEmpty {
                    Section {
                        EmptyHint(symbol: "cart", title: "這個月還沒有記帳", message: "按右下角的 ＋ 記一筆，或在捷徑設定「從通知記帳」自動化")
                            .listRowBackground(Color.clear)
                    }
                }
                ForEach(days, id: \.0) { day, entries in
                    Section {
                        ForEach(entries) { e in
                            Button { editing = e } label: { EntryRow(entry: e, hidden: hidden) }
                                .buttonStyle(.plain)
                                .swipeActions {
                                    Button("刪除", systemImage: "trash", role: .destructive) {
                                        context.delete(e)
                                        try? context.save()
                                    }
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
            .background(Color(.systemGroupedBackground))
            .ledgerNavigation(filter.label)
            .toolbar {
                HeaderTitle(title: filter.label) {
                    Picker("顯示", selection: $filter) {
                        Text("全部").tag(EntryFilter.all)
                        Text("支出").tag(EntryFilter.expense)
                        Text("收入").tag(EntryFilter.income)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    MonthStepper(month: $month)
                }
                .sharedBackgroundVisibility(.hidden)
            }
            .searchable(text: $search, placement: .navigationBarDrawer, prompt: "搜尋商家、備註、分類")
            .sheet(item: $editing) { EntryDetailView(entry: $0) }
        }
    }

    private var summary: some View {
        let expense = monthEntries.filter { $0.kind == .expense }.reduce(0) { $0 + $1.amount }
        let income = monthEntries.filter { $0.kind == .income }.reduce(0) { $0 + $1.amount }

        return VStack(alignment: .leading, spacing: 14) {
            Text("本月支出").foregroundStyle(.secondary).font(.title3)
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

    var body: some View {
        HStack(spacing: 14) {
            if entry.kind == .transfer {
                CategoryIcon(symbol: "arrow.left.arrow.right", color: .blue)
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
                        Image(systemName: "sparkles").font(.caption).foregroundStyle(.secondary)
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
        f.dateFormat = "HH:mm"
        parts.append(f.string(from: entry.date))
        return parts.joined(separator: " · ")
    }
}
