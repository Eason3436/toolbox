import SwiftUI
import SwiftData

enum BillFilter: String, CaseIterable, Identifiable {
    case all, subscription, bill, income, unpaid
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: "帳單"
        case .subscription: "訂閱"
        case .bill: "一般帳單"
        case .income: "固定收入"
        case .unpaid: "未完成"
        }
    }
}

struct BillsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Bill.createdAt) private var bills: [Bill]
    @AppStorage(Prefs.hideAmountsKey) private var hidden = false
    @AppStorage("billStackMode") private var stackMode = true

    @State private var month = Date.now
    @State private var filter: BillFilter = .all
    @State private var sortByAmount = false
    @State private var expandedID: String?
    @State private var editing: Bill?
    @State private var showCalendar = false

    private var occurrences: [BillOccurrence] {
        var list = BillService.upcoming(bills)
        switch filter {
        case .all: break
        case .subscription: list = list.filter { $0.bill.isSubscription && !$0.bill.receives }
        case .bill: list = list.filter { !$0.bill.isSubscription && !$0.bill.receives }
        case .income: list = list.filter { $0.bill.receives }
        case .unpaid: list = list.filter { !$0.paid }
        }
        if sortByAmount { list.sort { $0.bill.amount > $1.bill.amount } }
        return list
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    PlanningLinks()
                    summary
                    if occurrences.isEmpty {
                        EmptyHint(symbol: "calendar.badge.clock", title: "還沒有帳單", message: "按右下角的 ＋ 新增訂閱或固定帳單")
                    } else {
                        cards
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .background(Palette.background)
            .ledgerNavigation(filter.label)
            .toolbar {
                HeaderTitle(title: filter.label) {
                    Picker("顯示", selection: $filter) {
                        Text("全部").tag(BillFilter.all)
                        Text("訂閱").tag(BillFilter.subscription)
                        Text("固定收入").tag(BillFilter.income)
                        Text("未完成").tag(BillFilter.unpaid)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("排序", selection: $sortByAmount) {
                            Label("依到期日", systemImage: "calendar").tag(false)
                            Label("依金額", systemImage: "dollarsign").tag(true)
                        }
                        Picker("顯示方式", selection: $stackMode) {
                            Label("堆疊卡片", systemImage: "square.stack").tag(true)
                            Label("列表", systemImage: "list.bullet").tag(false)
                        }
                        Divider()
                        Button("帳單月曆", systemImage: "calendar") { showCalendar = true }
                    } label: { Image(systemName: "ellipsis") }
                }
            }
            .sheet(item: $editing) { BillEditor(bill: $0) }
            .sheet(isPresented: $showCalendar) {
                BillCalendarSheet(bills: bills, month: $month, hidden: hidden)
                    .presentationDetents([.medium, .large])
            }
        }
    }

    /// 不分月：30 天內要繳的、每月大約多少、本月已繳
    private var summary: some View {
        let soon = Calendar.current.date(byAdding: .day, value: 30, to: .now) ?? .now
        let shown = BillService.upcoming(bills)
        let pending = shown.filter { !$0.paid && !$0.bill.receives && $0.due <= soon }
            .reduce(0) { $0 + $1.bill.amount * QuoteService.rate(from: $1.bill.currency) }
        let active = bills.filter(\.active)
        let monthly = active.filter { !$0.receives }
            .reduce(0) { $0 + BillService.monthlyEquivalent($1) * QuoteService.rate(from: $1.currency) }
        let monthlyIncome = active.filter(\.receives)
            .reduce(0) { $0 + BillService.monthlyEquivalent($1) * QuoteService.rate(from: $1.currency) }
        let thisMonth = BillService.occurrences(bills, in: DateText.monthInterval(.now)).filter { !$0.bill.receives }
        let paid = thisMonth.filter(\.paid).reduce(0) { $0 + $1.bill.amount * QuoteService.rate(from: $1.bill.currency) }
        let monthTotal = thisMonth.reduce(0) { $0 + $1.bill.amount * QuoteService.rate(from: $1.bill.currency) }
        let ratio = monthTotal > 0 ? paid / monthTotal : 1
        return VStack(alignment: .leading, spacing: 14) {
            Text("30 天內待支付").foregroundStyle(.secondary).font(.title3)
            HStack(spacing: 12) {
                MoneyText(value: pending, hidden: hidden, font: .system(size: 44, weight: .bold, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.5)
                Pill(text: "本月已付 \(Money.percent(ratio))", tint: ratio >= 1 ? .green : .orange)
                Spacer()
                EyeButton(hidden: $hidden)
            }
            Divider()
            SummaryRow(title: "每月約", amount: monthly, hidden: hidden)
            SummaryRow(title: "本月已繳", amount: paid, hidden: hidden)
            if monthlyIncome > 0 {
                SummaryRow(title: "固定收入每月約", amount: monthlyIncome, hidden: hidden)
            }
        }
        .cardStyle()
    }

    private var cards: some View {
        let list = occurrences
        let overlap: CGFloat = 28
        let defaultExpanded = list.first(where: { !$0.paid })?.id ?? list.last?.id
        let current = list.contains(where: { $0.id == expandedID }) ? expandedID : defaultExpanded
        return VStack(spacing: stackMode ? -overlap : 14) {
            ForEach(Array(list.enumerated()), id: \.element.id) { i, occ in
                let expanded = !stackMode || occ.id == current
                let isLast = i == list.count - 1
                BillCard(occ: occ, expanded: expanded, hidden: hidden,
                         bottomInset: stackMode && !isLast ? overlap : 0,
                         onToggle: {
                             withAnimation(.snappy) {
                                 if occ.paid { BillService.markUnpaid(occ, context: context) } else { BillService.markPaid(occ, context: context) }
                             }
                         },
                         onEdit: { editing = occ.bill })
                    .frame(height: expanded ? 220 + (stackMode && !isLast ? overlap : 0) : 76 + overlap, alignment: .top)
                    .zIndex(Double(i))
                    .onTapGesture {
                        withAnimation(.spring(duration: 0.4, bounce: 0.2)) { expandedID = occ.id }
                    }
            }
        }
    }
}

struct BillCard: View {
    var occ: BillOccurrence
    var expanded: Bool
    var hidden: Bool
    var bottomInset: CGFloat = 0
    var onToggle: () -> Void
    var onEdit: () -> Void

    private var tint: Color { occ.bill.category?.color ?? .orange }

    var body: some View {
        ZStack(alignment: .top) {
            GradientCardBackground(color: Color(hex: "#2C2C2E"))
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 12) {
                    if let logo = BrandLogo.subscriptionLogoName(name: occ.bill.name, platform: occ.bill.platform) {
                        MerchantLogo(name: logo, size: 40)
                    } else if let c = occ.bill.category {
                        c.icon(size: 40, onDark: true)
                    } else {
                        CategoryIcon(symbol: "arrow.triangle.2.circlepath", color: .orange, size: 40, onDark: true)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(occ.bill.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                            if occ.bill.autoPay {
                                Image(systemName: "bolt.fill").font(.subheadline).foregroundStyle(.white.opacity(0.6))
                            }
                        }
                        Text(occ.bill.category?.name ?? (occ.bill.isSubscription ? "訂閱" : "帳單"))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text((occ.bill.receives ? "+" : "") + Money.format(occ.bill.amount, currency: occ.bill.currency, hidden: hidden))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                        DarkPill(text: occ.paid ? occ.bill.doneLabel : occ.bill.pendingLabel)
                    }
                }
                .foregroundStyle(.white)

                if expanded {
                    Spacer(minLength: 10)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(occ.bill.receives ? "入帳日" : "到期").font(.caption).foregroundStyle(.white.opacity(0.6))
                        Text(DateText.dueText(occ.due)).font(.headline)
                        HStack(spacing: 5) {
                            Text(occ.bill.recurrenceText + (occ.bill.platform.isEmpty ? "" : " ·"))
                            if !occ.bill.platform.isEmpty {
                                MerchantLogo(name: occ.bill.platform, size: 15)
                                Text(occ.bill.platform)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                    }
                    .foregroundStyle(.white)
                    .padding(.bottom, 12)

                    HStack(spacing: 12) {
                        Button(action: onToggle) {
                            Text(occ.paid ? "改為\(occ.bill.pendingLabel)" : "標記\(occ.bill.doneLabel)")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .foregroundStyle(Palette.onDarkButtonText)
                                .background(Palette.onDarkButton, in: .capsule)
                        }
                        Button(action: onEdit) {
                            Text("編輯")
                                .font(.subheadline.weight(.semibold))
                                .padding(.vertical, 11)
                                .padding(.horizontal, 24)
                                .foregroundStyle(.white)
                                .background(.black.opacity(0.5), in: .capsule)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(18)
            .padding(.bottom, bottomInset)
        }
        .clipShape(.rect(cornerRadius: 24, style: .continuous))
    }
}

struct BillCalendarSheet: View {
    var bills: [Bill]
    @Binding var month: Date
    var hidden: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let cal = Calendar.current
        let interval = DateText.monthInterval(month)
        let occs = BillService.occurrences(bills, in: interval)
        let firstWeekday = cal.component(.weekday, from: interval.start) - 1
        let days = cal.range(of: .day, in: .month, for: month)?.count ?? 30
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    MonthStepper(month: $month)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 10) {
                        ForEach(["日", "一", "二", "三", "四", "五", "六"], id: \.self) {
                            Text($0).font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(0..<firstWeekday, id: \.self) { _ in Color.clear.frame(height: 40) }
                        ForEach(1...days, id: \.self) { d in
                            let date = cal.date(byAdding: .day, value: d - 1, to: interval.start)!
                            let due = occs.filter { cal.isDate($0.due, inSameDayAs: date) }
                            VStack(spacing: 3) {
                                Text("\(d)")
                                    .font(.callout.weight(cal.isDateInToday(date) ? .bold : .regular))
                                    .foregroundStyle(cal.isDateInToday(date) ? Color.accentColor : .primary)
                                HStack(spacing: 2) {
                                    ForEach(due.prefix(3)) { o in
                                        Circle().fill(o.paid ? Color.green : (o.bill.category?.color ?? .orange)).frame(width: 6, height: 6)
                                    }
                                }
                                .frame(height: 6)
                            }
                            .frame(height: 40)
                        }
                    }
                    .cardStyle(padding: 14)

                    VStack(spacing: 10) {
                        ForEach(occs) { o in
                            HStack {
                                Text(cal.component(.day, from: o.due).description + "日").monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                                Text(o.bill.name)
                                Spacer()
                                Text(Money.format(o.bill.amount, currency: o.bill.currency, hidden: hidden)).monospacedDigit()
                                Image(systemName: o.paid ? "checkmark.circle.fill" : "circle").foregroundStyle(o.paid ? .green : .secondary)
                            }
                        }
                    }
                    .cardStyle(padding: 16)
                }
                .padding()
            }
            .background(Palette.background)
            .navigationTitle("帳單行事曆")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } } }
        }
    }
}


/// 規劃頁上方：預算、儲蓄目標、借貸
struct PlanningLinks: View {
    var body: some View {
        HStack(spacing: 10) {
            link("預算", "gauge.with.dots.needle.33percent", Color.accentColor) { BudgetsView() }
            link("儲蓄目標", "target", Color.accentColor) { GoalsView() }
            link("借貸", "person.2.fill", Color.accentColor) { LoansView() }
        }
    }

    private func link<D: View>(_ title: String, _ symbol: String, _ color: Color, @ViewBuilder dest: @escaping () -> D) -> some View {
        NavigationLink { dest() } label: {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.title3).foregroundStyle(color)
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Palette.card, in: .rect(cornerRadius: 18, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(ChipPressStyle())
    }
}
