import SwiftUI
import SwiftData

// MARK: - 儲蓄目標

struct GoalRow: View {
    var goal: Goal
    var hidden: Bool
    @State private var shown = 0.0

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().stroke(goal.color.opacity(0.18), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: shown)
                    .stroke(goal.color.gradient, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: goal.symbol).font(.headline).foregroundStyle(goal.color)
            }
            .frame(width: 54, height: 54)
            VStack(alignment: .leading, spacing: 4) {
                Text(goal.name).font(.headline)
                Text("\(Money.format(goal.saved, hidden: hidden)) / \(Money.format(goal.target, hidden: hidden))")
                    .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                if let end = goal.endDate {
                    let days = Calendar.current.dateComponents([.day], from: .now, to: end).day ?? 0
                    Text(days >= 0 ? "還有 \(days) 天" : "已到期").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(Money.percent(goal.progress)).font(.title3.weight(.bold)).monospacedDigit().foregroundStyle(goal.color)
        }
        .foregroundStyle(.primary)
        .cardStyle(padding: 16)
        .onAppear { withAnimation(.spring(response: 0.9, dampingFraction: 0.8).delay(0.1)) { shown = goal.progress } }
        .onChange(of: goal.progress) { _, v in withAnimation(.spring) { shown = v } }
    }
}

struct GoalsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Goal.order) private var goals: [Goal]
    @AppStorage(Prefs.hideAmountsKey) private var hidden = false
    @State private var adding = false
    @State private var editing: Goal?
    @State private var depositing: Goal?

    var body: some View {
        List {
            if goals.isEmpty {
                EmptyHint(symbol: "target", title: "還沒有目標", message: "例如「日本旅遊 60,000」，之後記帳時可以把交易歸到目標")
                    .listRowBackground(Color.clear)
            }
            ForEach(goals.filter { !$0.archived }) { g in
                GoalRow(goal: g, hidden: hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .onTapGesture { editing = g }
                    .swipeActions(edge: .leading) {
                        Button("存入", systemImage: "plus") { depositing = g }.tint(g.color)
                    }
                    .swipeActions {
                        Button("封存", systemImage: "archivebox") { g.archived = true; try? context.save() }
                    }
            }
            let archived = goals.filter(\.archived)
            if !archived.isEmpty {
                Section("已封存") {
                    ForEach(archived) { g in
                        Text(g.name).foregroundStyle(.secondary)
                            .swipeActions {
                                Button("還原") { g.archived = false; try? context.save() }
                                Button("刪除", role: .destructive) { Haptics.shared.trash(); context.delete(g); try? context.save() }
                            }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Palette.background)
        .navigationTitle("儲蓄目標")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button("新增", systemImage: "plus") { adding = true } }
        }
        .sheet(isPresented: $adding) { GoalEditor(goal: nil) }
        .sheet(item: $editing) { GoalEditor(goal: $0) }
        .sheet(item: $depositing) { GoalDepositSheet(goal: $0).presentationDetents([.large]) }
    }
}

struct GoalDepositSheet: View {
    var goal: Goal
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var amountText = ""
    @State private var account: Account?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                AccountMenuChip(account: $account, placeholder: "從哪個帳戶")
                Spacer(minLength: 0)
                AnimatedAmountInput(text: $amountText, currencyCode: account?.currency ?? Prefs.mainCurrency)
            }
            .padding()
            .navigationTitle("存入「\(goal.name)」")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) {
                        let e = Entry(title: "存入：\(goal.name)", amount: Money.parse(amountText) ?? 0, kind: .expense, account: account)
                        e.goal = goal
                        e.excludeFromBudget = true
                        context.insert(e)
                        try? context.save()
                        dismiss()
                    }
                    .disabled((Money.parse(amountText) ?? 0) <= 0)
                }
            }
        }
    }
}

struct GoalEditor: View {
    var goal: Goal?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Goal.order) private var goals: [Goal]
    @State private var name = ""
    @State private var amountText = ""
    @State private var hasEnd = false
    @State private var pad = AmountPad()
    @State private var end = Calendar.current.date(byAdding: .month, value: 6, to: .now)!
    @State private var color = Color(hex: "#2D5DA0")
    @State private var symbol = "star.fill"
    @State private var confirmDelete = false

    private let symbols = ["star.fill", "airplane", "car.fill", "house.fill", "gift.fill", "laptopcomputer", "iphone", "camera.fill", "graduationcap.fill", "heart.fill", "pawprint.fill", "banknote.fill"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    AmountHeader(amountText: $amountText, title: $name, titlePrompt: "目標名稱", pad: $pad)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(symbols, id: \.self) { s in
                            Image(systemName: s)
                                .font(.title3)
                                .frame(width: 46, height: 46)
                                .foregroundStyle(symbol == s ? .white : color)
                                .background(symbol == s ? color : color.opacity(0.12), in: .circle)
                                .onTapGesture { withAnimation(.snappy) { symbol = s } }
                        }
                    }
                    VStack(spacing: 12) {
                        ColorPicker("顏色", selection: $color, supportsOpacity: false)
                        Toggle("設定期限", isOn: $hasEnd.animation())
                        if hasEnd { DatePicker("期限", selection: $end, displayedComponents: .date) }
                    }
                    .cardStyle()
                    if goal != nil {
                        Button("刪除目標", role: .destructive) { confirmDelete = true }
                    }
                }
                .padding()
            }
            .amountKeypad(text: $amountText, pad: $pad)
            .background(Palette.background)
            .navigationTitle(goal == nil ? "新增目標" : "編輯目標")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) { save() }
                        .disabled((Money.parse(amountText) ?? 0) <= 0 || name.isEmpty)
                }
            }
            .confirmationDialog("刪除目標？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("刪除", role: .destructive) {
                    if let goal { Haptics.shared.trash(); context.delete(goal); try? context.save() }
                    dismiss()
                }
            }
            .onAppear {
                guard let goal else { return }
                name = goal.name
                amountText = Money.format(goal.target).replacingOccurrences(of: ",", with: "")
                hasEnd = goal.endDate != nil
                end = goal.endDate ?? end
                color = goal.color
                symbol = goal.symbol
            }
        }
    }

    private func save() {
        let g = goal ?? {
            let n = Goal(name: name, target: 0)
            n.order = (goals.map(\.order).max() ?? 0) + 1
            context.insert(n)
            return n
        }()
        g.name = name
        g.target = Money.parse(amountText) ?? 0
        g.endDate = hasEnd ? end : nil
        g.colorHex = color.hexString
        g.symbol = symbol
        try? context.save()
        dismiss()
    }
}

// MARK: - 借貸

struct LoansView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Loan.date, order: .reverse) private var loans: [Loan]
    @AppStorage(Prefs.hideAmountsKey) private var hidden = false
    @State private var adding = false
    @State private var editing: Loan?
    @State private var showClosed = false

    var body: some View {
        List {
            let open = loans.filter { !$0.closed && $0.remaining > 0 }
            let lent = open.filter { $0.direction == .lent }.reduce(0) { $0 + $1.remaining }
            let borrowed = open.filter { $0.direction == .borrowed }.reduce(0) { $0 + $1.remaining }
            Section {
                HStack {
                    VStack(alignment: .leading) {
                        Text("別人欠我").font(.subheadline).foregroundStyle(.secondary)
                        Text(Money.format(lent, hidden: hidden)).font(.title.weight(.bold)).foregroundStyle(.green).monospacedDigit()
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text("我欠別人").font(.subheadline).foregroundStyle(.secondary)
                        Text(Money.format(borrowed, hidden: hidden)).font(.title.weight(.bold)).foregroundStyle(.red).monospacedDigit()
                    }
                }
                .padding(.vertical, 6)
            }
            ForEach(LoanDirection.allCases) { dir in
                let items = loans.filter { $0.direction == dir && ((!$0.closed && $0.remaining > 0) || showClosed) }
                if !items.isEmpty {
                    Section(dir.label) {
                        ForEach(items) { l in
                            Button { editing = l } label: {
                                HStack {
                                    CategoryIcon(symbol: dir == .lent ? "arrow.up.forward" : "arrow.down.backward", color: dir == .lent ? .green : .red, size: 40)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(l.person).font(.headline)
                                        Text(l.note.isEmpty ? DateText.short(l.date) : l.note).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(Money.format(l.remaining, currency: l.currency, hidden: hidden)).font(.headline).monospacedDigit()
                                        if l.repaid > 0 {
                                            Text("共 \(Money.format(l.amount, currency: l.currency, hidden: hidden))").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .opacity(l.closed || l.remaining <= 0 ? 0.5 : 1)
                            }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button("刪除", role: .destructive) { Haptics.shared.trash(); context.delete(l); try? context.save() }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("借貸")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { withAnimation { showClosed.toggle() } } label: {
                    Image(systemName: showClosed ? "eye" : "eye.slash")
                }
            }
            ToolbarItem(placement: .topBarTrailing) { Button("新增", systemImage: "plus") { adding = true } }
        }
        .sheet(isPresented: $adding) { LoanEditor(loan: nil) }
        .sheet(item: $editing) { LoanEditor(loan: $0) }
    }
}

struct LoanEditor: View {
    var loan: Loan?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var person = ""
    @State private var amountText = ""
    @State private var direction: LoanDirection = .lent
    @State private var pad = AmountPad()
    @State private var date = Date.now
    @State private var note = ""
    @State private var records: [LoanRecord] = []
    @State private var repayText = ""
    @State private var closed = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("", selection: $direction) {
                        ForEach(LoanDirection.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    AmountField(text: $amountText, pad: $pad, currencyCode: loan?.currency ?? Prefs.mainCurrency)
                        .listRowBackground(Color.clear)
                }
                Section {
                    TextField(direction == .lent ? "借給誰" : "跟誰借", text: $person)
                    DatePicker("日期", selection: $date, displayedComponents: .date)
                    TextField("備註", text: $note)
                }
                if loan != nil {
                    Section {
                        ForEach(records) { r in
                            HStack {
                                Text(DateText.short(r.date)).foregroundStyle(.secondary)
                                Spacer()
                                Text(Money.format(r.amount)).monospacedDigit()
                            }
                        }
                        .onDelete { records.remove(atOffsets: $0) }
                        HStack {
                            TextField("還款金額", text: $repayText).keyboardType(.decimalPad)
                            Button(direction.verb) {
                                if let v = Money.parse(repayText), v > 0 {
                                    withAnimation { records.append(LoanRecord(date: .now, amount: v)) }
                                    repayText = ""
                                }
                            }
                            .buttonStyle(.glass)
                        }
                        Toggle("已結清", isOn: $closed)
                    } header: {
                        Text("還款紀錄")
                    }
                }
            }
            .amountKeypad(text: $amountText, pad: $pad)
            .navigationTitle(loan == nil ? "新增借貸" : "借貸")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) { save() }
                        .disabled(person.isEmpty || (Money.parse(amountText) ?? 0) <= 0)
                }
            }
            .onAppear {
                guard let loan else { return }
                person = loan.person
                amountText = Money.format(loan.amount, currency: loan.currency).replacingOccurrences(of: ",", with: "")
                direction = loan.direction
                date = loan.date
                note = loan.note
                records = loan.records
                closed = loan.closed
            }
        }
    }

    private func save() {
        let l = loan ?? {
            let n = Loan(person: person, amount: 0, direction: direction)
            context.insert(n)
            return n
        }()
        l.person = person
        l.amount = Money.parse(amountText) ?? 0
        l.direction = direction
        l.date = date
        l.note = note
        l.records = records
        l.closed = closed
        try? context.save()
        dismiss()
    }
}
