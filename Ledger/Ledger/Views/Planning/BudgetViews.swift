import SwiftUI
import SwiftData
import Charts

struct BudgetCard: View {
    var budget: Budget
    var entries: [Entry]
    var hidden: Bool

    var body: some View {
        let interval = budget.interval()
        let spent = budget.spent(in: interval, entries: entries)
        let ratio = budget.amount > 0 ? spent / budget.amount : 0
        let elapsed = min(max(Date.now.timeIntervalSince(interval.start) / interval.duration, 0), 1)
        let daysLeft = max(Calendar.current.dateComponents([.day], from: .now, to: interval.end).day ?? 0, 1)
        let remain = budget.amount - spent

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(budget.name).font(.headline)
                Spacer()
                Text(budget.period.label).font(.subheadline).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline) {
                MoneyText(value: max(remain, 0), hidden: hidden, font: .system(size: 30, weight: .bold, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(remain >= 0 ? "可用" : "超支 \(Money.format(-remain, hidden: hidden))")
                    .foregroundStyle(remain >= 0 ? Color.secondary : Color.red)
            }
            BudgetBar(ratio: ratio, elapsed: elapsed, color: budget.color)
            HStack {
                Text("已花 \(Money.format(spent, hidden: hidden)) / \(Money.format(budget.amount, hidden: hidden))")
                Spacer()
                if remain > 0 {
                    Text("每天可花 \(Money.format(remain / Double(daysLeft), hidden: hidden))")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .foregroundStyle(.primary)
        .cardStyle()
    }
}

/// 預算進度條，含「今天」的位置標記
struct BudgetBar: View {
    var ratio: Double
    var elapsed: Double
    var color: Color
    @State private var animated = 0.0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.tertiarySystemFill))
                Capsule()
                    .fill(ratio > 1 ? Color.red.gradient : color.gradient)
                    .frame(width: max(12, geo.size.width * min(animated, 1)))
                Rectangle()
                    .fill(Color.primary.opacity(0.55))
                    .frame(width: 2, height: 20)
                    .offset(x: geo.size.width * elapsed - 1)
            }
        }
        .frame(height: 14)
        .onAppear { withAnimation(.spring(response: 0.8, dampingFraction: 0.8).delay(0.1)) { animated = ratio } }
        .onChange(of: ratio) { _, v in withAnimation(.spring) { animated = v } }
    }
}

struct BudgetsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Budget.order) private var budgets: [Budget]
    @Query(sort: \Entry.date, order: .reverse) private var entries: [Entry]
    @AppStorage(Prefs.hideAmountsKey) private var hidden = false
    @State private var adding = false
    @State private var showArchived = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                let list = budgets.filter { $0.archived == showArchived }
                if list.isEmpty {
                    EmptyHint(symbol: "chart.pie", title: showArchived ? "沒有封存的預算" : "還沒有預算", message: "按右上角 ＋ 建立，例如「每月生活費 20,000」")
                }
                ForEach(Array(list.enumerated()), id: \.element.id) { i, b in
                    NavigationLink { BudgetDetailView(budget: b) } label: {
                        BudgetCard(budget: b, entries: entries, hidden: hidden)
                    }
                    .pressable()
                    .appearEffect(delay: Double(i) * 0.05)
                }
            }
            .padding()
        }
        .background(Palette.background)
        .navigationTitle("預算")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { withAnimation { showArchived.toggle() } } label: {
                    Image(systemName: showArchived ? "archivebox.fill" : "archivebox")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("新增", systemImage: "plus") { adding = true }
            }
        }
        .sheet(isPresented: $adding) { BudgetEditor(budget: nil) }
    }
}

struct BudgetDetailView: View {
    var budget: Budget
    @Query(sort: \Entry.date, order: .reverse) private var entries: [Entry]
    @AppStorage(Prefs.hideAmountsKey) private var hidden = false
    @State private var editing = false
    @State private var offset = 0
    @State private var editingEntry: Entry?

    var body: some View {
        let interval = budget.interval(offset: offset)
        let inPeriod = entries.filter { interval.contains($0.date) && budget.includes($0) }
        let history = (-5...0).map { o -> (String, Double) in
            let iv = budget.interval(offset: o)
            return (label(iv), budget.spent(in: iv, entries: entries))
        }
        let byCat = Dictionary(grouping: inPeriod) { $0.category?.main.id }
            .map { (cat: $0.value.first?.category?.main, total: $0.value.reduce(0) { $0 + $1.amount }) }
            .sorted { $0.total > $1.total }

        ScrollView {
            VStack(spacing: 16) {
                HStack {
                    Button { withAnimation(.snappy) { offset -= 1 } } label: { Image(systemName: "chevron.left").frame(width: 40, height: 40) }
                    Spacer()
                    Text(label(interval)).font(.headline).contentTransition(.numericText())
                    Spacer()
                    Button { withAnimation(.snappy) { offset = min(offset + 1, 0) } } label: { Image(systemName: "chevron.right").frame(width: 40, height: 40) }
                        .disabled(offset >= 0)
                }
                .padding(.horizontal, 8)
                .glassEffect(.regular.interactive(), in: .capsule)

                BudgetCard(budget: budget, entries: offset == 0 ? entries : inPeriod, hidden: hidden)

                VStack(alignment: .leading, spacing: 10) {
                    Text("近 6 期").font(.headline)
                    Chart {
                        ForEach(history, id: \.0) { item in
                            BarMark(x: .value("期間", item.0), y: .value("花費", item.1))
                                .foregroundStyle(item.1 > budget.amount ? Color.red.gradient : budget.color.gradient)
                                .cornerRadius(6)
                        }
                        RuleMark(y: .value("預算", budget.amount))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .foregroundStyle(.secondary)
                    }
                    .frame(height: 180)
                }
                .cardStyle()

                if !byCat.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("分類").font(.headline)
                        Chart(byCat, id: \.cat?.id) { item in
                            SectorMark(angle: .value("金額", item.total), innerRadius: .ratio(0.62), angularInset: 1.5)
                                .foregroundStyle(item.cat?.color ?? .gray)
                                .cornerRadius(4)
                        }
                        .frame(height: 180)
                        ForEach(byCat, id: \.cat?.id) { item in
                            HStack {
                                Circle().fill(item.cat?.color ?? .gray).frame(width: 10, height: 10)
                                Text(item.cat?.name ?? "未分類")
                                Spacer()
                                Text(Money.format(item.total, hidden: hidden)).monospacedDigit()
                            }
                        }
                    }
                    .cardStyle()
                }

                if !inPeriod.isEmpty {
                    VStack(spacing: 4) {
                        ForEach(inPeriod) { e in
                            Button { editingEntry = e } label: { EntryRow(entry: e, hidden: hidden) }
                                .buttonStyle(.plain)
                        }
                    }
                    .cardStyle()
                }
            }
            .padding()
        }
        .background(Palette.background)
        .navigationTitle(budget.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button("編輯") { editing = true } }
        }
        .sheet(isPresented: $editing) { BudgetEditor(budget: budget) }
        .sheet(item: $editingEntry) { EntryDetailView(entry: $0) }
    }

    private func label(_ iv: DateInterval) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hant_TW")
        switch budget.period {
        case .weekly: f.dateFormat = "M/d"
        case .monthly: f.dateFormat = "M月"
        case .yearly: f.dateFormat = "yyyy"
        }
        return f.string(from: iv.start)
    }
}

struct BudgetEditor: View {
    var budget: Budget?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Category.order) private var categories: [Category]
    @Query(sort: \Budget.order) private var budgets: [Budget]

    @State private var name = ""
    @State private var amountText = ""
    @State private var period: BudgetPeriod = .monthly
    @State private var pad = AmountPad()
    @State private var selected: Set<UUID> = []
    @State private var color = Color(hex: "#5E1F3C")
    @State private var pinned = true
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    AmountHeader(amountText: $amountText, title: $name, titlePrompt: "預算名稱，例如 生活費", pad: $pad)
                    Picker("週期", selection: $period) {
                        ForEach(BudgetPeriod.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 30)

                    VStack(spacing: 10) {
                        Text(selected.isEmpty ? "包含：全部支出分類" : "包含 \(selected.count) 個分類")
                            .font(.subheadline).foregroundStyle(.secondary)
                        FlowLayout(spacing: 10) {
                            ForEach(categories.filter { !$0.isIncome && !$0.isSub }) { c in
                                Button {
                                    withAnimation(.snappy) {
                                        if selected.contains(c.id) { selected.remove(c.id) } else { selected.insert(c.id) }
                                    }
                                } label: {
                                    Chip(title: c.name, symbol: c.symbol, symbolColor: c.color, selected: selected.contains(c.id), tint: c.color)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    HStack(spacing: 14) {
                        ColorPicker("顏色", selection: $color, supportsOpacity: false).fixedSize()
                        Toggle("顯示在首頁", isOn: $pinned).fixedSize()
                    }
                    .padding(.horizontal)

                    if let budget {
                        HStack(spacing: 12) {
                            Button(budget.archived ? "取消封存" : "封存") {
                                budget.archived.toggle()
                                try? context.save()
                                dismiss()
                            }
                            .buttonStyle(.glass)
                            Button("刪除", role: .destructive) { confirmDelete = true }
                                .buttonStyle(.glass)
                        }
                    }
                }
                .padding()
            }
            .amountKeypad(text: $amountText, pad: $pad)
            .background(Palette.background)
            .navigationTitle(budget == nil ? "新增預算" : "編輯預算")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) { save() }
                        .disabled((Money.parse(amountText) ?? 0) <= 0 || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog("確定刪除預算？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("刪除", role: .destructive) {
                    if let budget { context.delete(budget); try? context.save() }
                    dismiss()
                }
            }
            .onAppear {
                guard let budget else { return }
                name = budget.name
                amountText = Money.format(budget.amount).replacingOccurrences(of: ",", with: "")
                period = budget.period
                selected = Set((budget.categories ?? []).map(\.id))
                color = budget.color
                pinned = budget.pinned
            }
        }
    }

    private func save() {
        let b = budget ?? {
            let n = Budget(name: name, amount: 0)
            n.order = (budgets.map(\.order).max() ?? 0) + 1
            context.insert(n)
            return n
        }()
        b.name = name.trimmingCharacters(in: .whitespaces)
        b.amount = Money.parse(amountText) ?? 0
        b.period = period
        b.categories = categories.filter { selected.contains($0.id) }
        b.colorHex = color.hexString
        b.pinned = pinned
        try? context.save()
        dismiss()
    }
}
