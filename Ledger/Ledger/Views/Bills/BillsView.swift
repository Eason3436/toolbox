import SwiftUI
import SwiftData

enum BillFilter: String, CaseIterable, Identifiable {
    case all, subscription, bill, income, unpaid
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: "全部"
        case .subscription: "訂閱"
        case .bill: "一般帳單"
        case .income: "固定收入"
        case .unpaid: "未完成"
        }
    }
}

/// 帳單頁的兩個分頁：即將到來（依日期）／訂閱（全部列出、每月平均）
enum BillPage: String, CaseIterable, Identifiable {
    case upcoming, all
    var id: String { rawValue }
    var label: String { self == .upcoming ? "即將到來" : "訂閱" }
}

enum BillSort: String, CaseIterable, Identifiable {
    case due, amount, name
    var id: String { rawValue }
    var label: String {
        switch self {
        case .due: "依續訂日"
        case .amount: "依金額"
        case .name: "依名稱"
        }
    }
}

/// 週一開頭的日曆、到期文字
enum BillDates {
    static var calendar: Calendar {
        var c = Calendar.current
        c.firstWeekday = 2
        return c
    }

    static func daysFromToday(_ date: Date) -> Int {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        return cal.dateComponents([.day], from: today, to: cal.startOfDay(for: date)).day ?? 0
    }

    static func verb(_ bill: Bill) -> String {
        if bill.receives { return "入帳" }
        return bill.isSubscription ? "續訂" : "到期"
    }

    /// 「明天續訂」「於12月2日續訂」「已逾期 3 天」
    static func dueText(_ occ: BillOccurrence) -> String {
        let d = daysFromToday(occ.due)
        let v = verb(occ.bill)
        if occ.paid && d <= 0 { return occ.bill.doneLabel }
        if d < 0 { return "已逾期 \(-d) 天" }
        if d == 0 { return "今天\(v)" }
        if d == 1 { return "明天\(v)" }
        if d == 2 { return "後天\(v)" }
        return "於\(monthDay(occ.due))\(v)"
    }

    static func monthDay(_ date: Date) -> String {
        let cal = Calendar.current
        return "\(cal.component(.month, from: date))月\(cal.component(.day, from: date))日"
    }

    /// 1 單位帳單幣別換成主幣別
    static func mainAmount(_ bill: Bill) -> Double {
        bill.amount * QuoteService.rate(from: bill.currency)
    }

    static func color(_ bill: Bill) -> Color {
        BrandLogo.subscriptionGlyph(name: bill.name, platform: bill.platform)?.color
            ?? bill.category?.color ?? .orange
    }
}

struct BillsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Bill.createdAt) private var bills: [Bill]
    @AppStorage(Prefs.hideAmountsKey) private var hidden = false
    @AppStorage("billPage") private var pageRaw = BillPage.upcoming.rawValue
    @AppStorage("billSort") private var sortRaw = BillSort.due.rawValue

    @State private var filter: BillFilter = .all
    @State private var editing: Bill?
    @State private var acting: BillOccurrence?

    private var page: BillPage { BillPage(rawValue: pageRaw) ?? .upcoming }
    private var sort: BillSort { BillSort(rawValue: sortRaw) ?? .due }

    private func matches(_ b: Bill) -> Bool {
        switch filter {
        case .all, .unpaid: true
        case .subscription: b.isSubscription && !b.receives
        case .bill: !b.isSubscription && !b.receives
        case .income: b.receives
        }
    }

    private var shownBills: [Bill] { bills.filter(matches) }

    /// 每個帳單一筆：最早還沒繳的那期，都繳了就是下一期
    private var occurrences: [BillOccurrence] {
        var list = BillService.upcoming(shownBills)
        if filter == .unpaid { list = list.filter { !$0.paid } }
        return list
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Picker("分頁", selection: $pageRaw) {
                        ForEach(BillPage.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)

                    if bills.isEmpty {
                        EmptyHint(symbol: "calendar.badge.clock", title: "還沒有帳單", message: "按右下角的 ＋ 新增訂閱或固定帳單")
                    } else if page == .upcoming {
                        upcomingPage
                    } else {
                        allPage
                    }
                    PlanningSection()
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
                .animation(.snappy, value: pageRaw)
            }
            .background(alignment: .top) { glow }
            .background(Palette.background)
            .ledgerNavigation(page.label)
            .toolbar {
                HeaderTitle(title: page.label) {
                    Picker("顯示", selection: $filter) {
                        ForEach(BillFilter.allCases) { Text($0.label).tag($0) }
                    }
                }
            }
            .sheet(item: $editing) { BillEditor(bill: $0) }
            .confirmationDialog(acting?.bill.name ?? "", isPresented: Binding(get: { acting != nil }, set: { if !$0 { acting = nil } }),
                                titleVisibility: .visible, presenting: acting) { occ in
                Button(occ.paid ? "改為\(occ.bill.pendingLabel)" : "標記\(occ.bill.doneLabel)") { toggle(occ) }
                Button("編輯") { editing = occ.bill }
            } message: { occ in
                Text("\(BillDates.monthDay(occ.due))・\(Money.format(occ.bill.amount, currency: occ.bill.currency, hidden: hidden))")
            }
        }
    }

    private func toggle(_ occ: BillOccurrence) {
        withAnimation(.snappy) {
            if occ.paid { BillService.markUnpaid(occ, context: context) } else { BillService.markPaid(occ, context: context) }
        }
    }

    /// 頁面上方的顏色光暈：用下一筆（或最貴的）訂閱的品牌色
    private var glow: some View {
        let bill: Bill? = page == .upcoming
            ? nextDue?.bill
            : shownBills.filter(\.active).max { BillService.monthlyEquivalent($0) < BillService.monthlyEquivalent($1) }
        let color: Color = bill.map(BillDates.color) ?? .clear
        return LinearGradient(colors: [color.opacity(0.45), color.opacity(0.12), .clear], startPoint: .top, endPoint: .bottom)
            .frame(height: 460)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 0.4), value: pageRaw)
    }

    // MARK: - 即將到來

    private var nextDue: BillOccurrence? {
        let list = occurrences.filter { !$0.paid }
        return list.first { BillDates.daysFromToday($0.due) >= 0 } ?? list.first
    }

    @ViewBuilder
    private var upcomingPage: some View {
        if let next = nextDue {
            hero(next)
        }
        WeekStrip(occurrences: BillService.occurrences(shownBills, in: weekInterval))
        NavigationLink {
            BillMonthView(bills: shownBills, hidden: hidden)
        } label: {
            MonthRemainingCard(bills: shownBills, hidden: hidden)
        }
        .buttonStyle(PressableStyle())

        ForEach(sections, id: \.title) { sec in
            VStack(alignment: .leading, spacing: 10) {
                Text(sec.title).font(.title2.weight(.bold))
                    .foregroundStyle(sec.title == "逾期" ? Color.red : Color.primary)
                    .padding(.leading, 6)
                BillListCard(items: sec.items, hidden: hidden, onTap: { acting = $0 },
                             onToggle: toggle, onEdit: { editing = $0 })
            }
        }
    }

    private var weekInterval: DateInterval {
        let cal = BillDates.calendar
        return cal.dateInterval(of: .weekOfYear, for: .now) ?? DateInterval(start: .now, duration: 7 * 86400)
    }

    private func hero(_ occ: BillOccurrence) -> some View {
        Button { acting = occ } label: {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(occ.bill.name) \(BillDates.dueText(occ))")
                        .font(.title.weight(.bold))
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                        .minimumScaleFactor(0.7)
                    Text("\(Money.format(occ.bill.amount, currency: occ.bill.currency, hidden: hidden))・\(occ.bill.recurrence.label)")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 8)
                BillLogo(bill: occ.bill, size: 92)
                    .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
            }
            .padding(.horizontal, 4)
            .contentShape(.rect)
        }
        .buttonStyle(PressableStyle())
        .foregroundStyle(.primary)
    }

    private struct DueSection {
        var title: String
        var items: [BillOccurrence]
    }

    /// 逾期／今天／明天／本週／11月稍後／12月…
    private var sections: [DueSection] {
        let cal = Calendar.current
        let week = weekInterval
        let now = Date.now
        var order: [String] = []
        var dict: [String: [BillOccurrence]] = [:]
        for occ in occurrences {
            let d = BillDates.daysFromToday(occ.due)
            let title: String
            if d < 0 && !occ.paid {
                title = "逾期"
            } else if d <= 0 {
                title = "今天"
            } else if d == 1 {
                title = "明天"
            } else if occ.due < week.end {
                title = "本週"
            } else if cal.isDate(occ.due, equalTo: now, toGranularity: .month) {
                title = "\(cal.component(.month, from: occ.due))月稍後"
            } else if cal.isDate(occ.due, equalTo: now, toGranularity: .year) {
                title = "\(cal.component(.month, from: occ.due))月"
            } else {
                title = "\(cal.component(.year, from: occ.due))年\(cal.component(.month, from: occ.due))月"
            }
            if dict[title] == nil {
                // 逾期放最前面
                if title == "逾期" { order.insert(title, at: 0) } else { order.append(title) }
            }
            dict[title, default: []].append(occ)
        }
        return order.map { DueSection(title: $0, items: dict[$0] ?? []) }
    }

    // MARK: - 訂閱（全部）

    private var activeBills: [Bill] { shownBills.filter(\.active) }

    private var sortedActive: [BillOccurrence] {
        let upcoming = BillService.upcoming(activeBills)
        switch sort {
        case .due: return upcoming
        case .amount: return upcoming.sorted { BillDates.mainAmount($0.bill) > BillDates.mainAmount($1.bill) }
        case .name: return upcoming.sorted { $0.bill.name.localizedStandardCompare($1.bill.name) == .orderedAscending }
        }
    }

    @ViewBuilder
    private var allPage: some View {
        let spending: [Bill] = activeBills.filter { !$0.receives }
        let monthly: Double = spending.reduce(0) { $0 + BillService.monthlyEquivalent($1) * QuoteService.rate(from: $1.currency) }
        HStack(alignment: .top, spacing: 12) {
            averageCard(monthly: monthly)
            ActiveLogosCard(bills: activeBills)
                .frame(width: 128)
        }
        .fixedSize(horizontal: false, vertical: true)

        let list = sortedActive
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(filter == .all || filter == .subscription ? "所有訂閱" : filter.label)
                    .font(.title2.weight(.bold))
                Spacer()
                Menu {
                    Picker("排序", selection: $sortRaw) {
                        ForEach(BillSort.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, height: 36)
                }
            }
            .padding(.leading, 6)
            if list.isEmpty {
                Text("沒有使用中的項目").foregroundStyle(.secondary).cardStyle()
            } else {
                BillListCard(items: list, hidden: hidden, highlightSoon: true, onTap: { editing = $0.bill },
                             onToggle: toggle, onEdit: { editing = $0 })
            }
        }

        let inactive = shownBills.filter { !$0.active }
        if !inactive.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("非使用中").font(.title2.weight(.bold))
                    Spacer()
                    Text("\(inactive.count) 個").foregroundStyle(.secondary)
                }
                .padding(.horizontal, 6)
                NavigationLink {
                    InactiveBillsView(bills: inactive, hidden: hidden)
                } label: {
                    HStack {
                        Text("查看不活躍訂閱")
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(.primary)
                    .cardStyle()
                }
                .buttonStyle(PressableStyle())
            }
        }
    }

    private func averageCard(monthly: Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("每月平均", systemImage: "calendar")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            MoneyText(value: monthly, hidden: hidden, font: .system(size: 32, weight: .bold, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.5)
            Divider()
            Label("每年平均", systemImage: "calendar.badge.clock")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Text(Money.format(monthly * 12, hidden: hidden))
                .font(.title3.weight(.bold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .cardStyle(padding: 18)
    }
}

// MARK: - 元件

/// 圓形的服務 logo；沒有 logo 就用單色圖示或分類圖示
struct BillLogo: View {
    var bill: Bill
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let name = BrandLogo.subscriptionLogoName(name: bill.name, platform: bill.platform),
               let img = BrandLogo.image(for: name) {
                Image(uiImage: img)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else if let g = BrandLogo.subscriptionGlyph(name: bill.name, platform: bill.platform) {
                ZStack {
                    Circle().fill(g.color.opacity(0.22))
                    Image("brandmono-\(g.id)")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: size * 0.52, height: size * 0.52)
                        .foregroundStyle(g.color)
                }
            } else {
                let color: Color = bill.category?.color ?? .orange
                ZStack {
                    Circle().fill(color.opacity(0.22))
                    Image(systemName: bill.category?.symbol ?? "arrow.triangle.2.circlepath")
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(color)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
    }
}

/// 一張卡片裡的帳單列表
struct BillListCard: View {
    var items: [BillOccurrence]
    var hidden: Bool
    var highlightSoon: Bool = false
    var onTap: (BillOccurrence) -> Void
    var onToggle: (BillOccurrence) -> Void
    var onEdit: (Bill) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, occ in
                Button { onTap(occ) } label: { row(occ) }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(occ.paid ? "改為\(occ.bill.pendingLabel)" : "標記\(occ.bill.doneLabel)",
                               systemImage: occ.paid ? "arrow.uturn.backward" : "checkmark.circle") { onToggle(occ) }
                        Button("編輯", systemImage: "pencil") { onEdit(occ.bill) }
                    }
                if i < items.count - 1 {
                    Divider().padding(.leading, 74)
                }
            }
        }
        .padding(.vertical, 4)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 28, style: .continuous))
    }

    private func row(_ occ: BillOccurrence) -> some View {
        let d = BillDates.daysFromToday(occ.due)
        let overdue = d < 0 && !occ.paid
        let soon = highlightSoon && !occ.paid && d >= 0 && d <= 3
        let subColor: Color = overdue ? .red : (soon ? .orange : .secondary)
        let sign: String = occ.bill.receives ? "+" : ""
        return HStack(spacing: 14) {
            BillLogo(bill: occ.bill, size: 46)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(occ.bill.name).font(.headline).lineLimit(1)
                    if occ.bill.autoPay {
                        Image(systemName: "bolt.fill").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(BillDates.dueText(occ))
                    .font(.subheadline)
                    .foregroundStyle(subColor)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(sign + Money.format(occ.bill.amount, currency: occ.bill.currency, hidden: hidden))
                    .font(.headline).monospacedDigit()
                    .foregroundStyle(occ.bill.receives ? Color.green : Color.primary)
                HStack(spacing: 4) {
                    if occ.paid {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    Text(occ.bill.recurrence.label)
                    Image(systemName: occ.bill.recurrence == .once ? "1.circle" : "repeat")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(.rect)
    }
}

/// 這一週（週一到週日），有到期的日子下面放 logo
struct WeekStrip: View {
    var occurrences: [BillOccurrence]

    var body: some View {
        let cal = BillDates.calendar
        let start = cal.dateInterval(of: .weekOfYear, for: .now)?.start ?? cal.startOfDay(for: .now)
        let days: [Date] = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
        let names = ["一", "二", "三", "四", "五", "六", "日"]
        HStack(spacing: 0) {
            ForEach(Array(days.enumerated()), id: \.offset) { i, day in
                VStack(spacing: 8) {
                    Text(names[i]).font(.subheadline).foregroundStyle(.secondary)
                    DayNumber(date: day, size: 36, font: .title3.weight(.semibold))
                    DueLogos(items: occurrences.filter { cal.isDate($0.due, inSameDayAs: day) }, size: 20)
                        .frame(height: 22)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// 日期數字；今天用主題色圓圈
struct DayNumber: View {
    var date: Date
    var size: CGFloat = 32
    var font: Font = .body
    var dimmed: Bool = false

    var body: some View {
        let today = Calendar.current.isDateInToday(date)
        Text("\(Calendar.current.component(.day, from: date))")
            .font(font)
            .monospacedDigit()
            .foregroundStyle(today ? Color.white : (dimmed ? Color.secondary.opacity(0.6) : Color.primary))
            .frame(width: size, height: size)
            .background { if today { Circle().fill(Color.accentColor) } }
    }
}

/// 同一天的幾個 logo 疊在一起
struct DueLogos: View {
    var items: [BillOccurrence]
    var size: CGFloat

    var body: some View {
        HStack(spacing: -size * 0.35) {
            ForEach(items.prefix(3)) { o in
                BillLogo(bill: o.bill, size: size)
                    .opacity(o.paid ? 0.45 : 1)
            }
        }
    }
}

/// 本月還要付多少＋小點點月曆
struct MonthRemainingCard: View {
    var bills: [Bill]
    var hidden: Bool

    var body: some View {
        let cal = BillDates.calendar
        let month = DateText.monthInterval(.now)
        let occs = BillService.occurrences(bills, in: month).filter { !$0.bill.receives }
        let remaining = occs.filter { !$0.paid && BillDates.daysFromToday($0.due) >= 0 }
            .reduce(0) { $0 + BillDates.mainAmount($1.bill) }
        let total = occs.reduce(0) { $0 + BillDates.mainAmount($1.bill) }
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Label("\(cal.component(.month, from: .now))月剩餘", systemImage: "calendar")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                MoneyText(value: remaining, hidden: hidden, font: .system(size: 34, weight: .bold, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.5)
                Text("總額 \(Money.format(total, hidden: hidden))")
                    .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 4)
            MonthDots(occurrences: occs)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .foregroundStyle(.primary)
        .cardStyle()
    }
}

/// 一個月的每一天一個點：今天主題色、有付款的日子亮起來
struct MonthDots: View {
    var occurrences: [BillOccurrence]

    var body: some View {
        let cal = BillDates.calendar
        let month = DateText.monthInterval(.now)
        let count = cal.range(of: .day, in: .month, for: month.start)?.count ?? 30
        let lead = (cal.component(.weekday, from: month.start) - cal.firstWeekday + 7) % 7
        let cells = Int((Double(lead + count) / 7).rounded(.up)) * 7
        let dueDays: Set<Int> = Set(occurrences.map { cal.component(.day, from: $0.due) })
        let today = cal.component(.day, from: .now)
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(7), spacing: 6), count: 7), spacing: 6) {
            ForEach(0..<cells, id: \.self) { i in
                let day = i - lead + 1
                Circle()
                    .fill(dotColor(day: day, count: count, today: today, due: dueDays.contains(day)))
                    .frame(width: 7, height: 7)
            }
        }
        .frame(width: 7 * 7 + 6 * 6)
    }

    private func dotColor(day: Int, count: Int, today: Int, due: Bool) -> Color {
        if day < 1 || day > count { return .clear }
        if day == today { return .accentColor }
        if due { return day < today ? Color.primary.opacity(0.45) : Color.primary }
        return Color.secondary.opacity(day < today ? 0.25 : 0.4)
    }
}

/// 右上角：使用中的訂閱 logo 疊在一起＋數量
struct ActiveLogosCard: View {
    var bills: [Bill]

    var body: some View {
        let top: [Bill] = bills.sorted { BillService.monthlyEquivalent($0) > BillService.monthlyEquivalent($1) }
        let offsets: [CGSize] = [.zero, CGSize(width: 34, height: -26), CGSize(width: 42, height: 8), CGSize(width: 28, height: 36)]
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                ForEach(Array(top.prefix(4).enumerated()), id: \.element.id) { i, b in
                    BillLogo(bill: b, size: i == 0 ? 58 : 24)
                        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                        .offset(offsets[i])
                        .zIndex(Double(4 - i))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 92)
            .offset(x: -14)
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(bills.count)").font(.system(size: 38, weight: .bold, design: .rounded))
                Text("個使用中").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .frame(maxHeight: .infinity)
        .cardStyle(padding: 16)
    }
}

// MARK: - 月曆

struct BillMonthView: View {
    var bills: [Bill]
    var hidden: Bool
    @State private var month = Date.now

    var body: some View {
        let cal = BillDates.calendar
        let interval = DateText.monthInterval(month)
        let occs = BillService.occurrences(bills, in: interval).filter { !$0.bill.receives }
        let remaining = occs.filter { !$0.paid && BillDates.daysFromToday($0.due) >= 0 }
            .reduce(0) { $0 + BillDates.mainAmount($1.bill) }
        let total = occs.reduce(0) { $0 + BillDates.mainAmount($1.bill) }
        let later = BillService.occurrences(bills, in: interval)
            .filter { BillDates.daysFromToday($0.due) >= 0 }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("\(cal.component(.year, from: month))年\(cal.component(.month, from: month))月")
                        .font(.largeTitle.weight(.bold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Spacer()
                    MonthStepper(month: $month).labelsHidden()
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(cal.isDate(month, equalTo: .now, toGranularity: .month) ? "本月剩餘付款" : "這個月要付")
                        .font(.subheadline).foregroundStyle(.secondary)
                    MoneyText(value: cal.isDate(month, equalTo: .now, toGranularity: .month) ? remaining : total,
                              hidden: hidden, font: .system(size: 34, weight: .bold, design: .rounded))
                    Text("總額 \(Money.format(total, hidden: hidden))").font(.subheadline).monospacedDigit()
                    Divider().padding(.vertical, 8)
                    MonthGrid(month: month, occurrences: occs)
                }
                .cardStyle()
                .gesture(DragGesture(minimumDistance: 30).onEnded { v in
                    guard abs(v.translation.width) > abs(v.translation.height) else { return }
                    withAnimation(.snappy) { month = DateText.addMonths(month, v.translation.width < 0 ? 1 : -1) }
                })

                if !later.isEmpty {
                    Text("即將到來").font(.title2.weight(.bold)).padding(.leading, 6)
                    BillListCard(items: later, hidden: hidden, onTap: { _ in }, onToggle: { _ in }, onEdit: { _ in })
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .background(Palette.background)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct MonthGrid: View {
    var month: Date
    var occurrences: [BillOccurrence]

    var body: some View {
        let cal = BillDates.calendar
        let start = DateText.monthInterval(month).start
        let count = cal.range(of: .day, in: .month, for: start)?.count ?? 30
        let lead = (cal.component(.weekday, from: start) - cal.firstWeekday + 7) % 7
        let cells = Int((Double(lead + count) / 7).rounded(.up)) * 7
        let names = ["週一", "週二", "週三", "週四", "週五", "週六", "週日"]
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 6) {
            ForEach(names, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            ForEach(0..<cells, id: \.self) { i in
                let date = cal.date(byAdding: .day, value: i - lead, to: start) ?? start
                let inMonth = i >= lead && i < lead + count
                VStack(spacing: 4) {
                    DayNumber(date: date, size: 30, font: .callout.weight(.medium), dimmed: !inMonth)
                    DueLogos(items: inMonth ? occurrences.filter { cal.isDate($0.due, inSameDayAs: date) } : [], size: 26)
                        .frame(height: 28)
                }
            }
        }
    }
}

/// 停用的帳單，點進去可以編輯或重新啟用
struct InactiveBillsView: View {
    var bills: [Bill]
    var hidden: Bool
    @State private var editing: Bill?

    var body: some View {
        List {
            ForEach(bills) { b in
                Button { editing = b } label: {
                    HStack(spacing: 14) {
                        BillLogo(bill: b, size: 40).saturation(0.2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(b.name).font(.headline)
                            Text(b.recurrenceText).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Money.format(b.amount, currency: b.currency, hidden: hidden))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("非使用中")
        .sheet(item: $editing) { BillEditor(bill: $0) }
    }
}

/// 規劃：預算、儲蓄目標、借貸
struct PlanningSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("規劃").font(.title2.weight(.bold)).padding(.leading, 6)
            PlanningLinks()
        }
        .padding(.top, 6)
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
