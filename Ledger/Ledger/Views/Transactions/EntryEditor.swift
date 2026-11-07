import SwiftUI
import SwiftData

struct EntryEditor: View {
    var entry: Entry?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Category.order) private var categories: [Category]
    @Query(sort: \Goal.order) private var goals: [Goal]
    @State private var goal: Goal?
    @State private var excludeFromBudget = false

    @State private var amountText = ""
    @State private var pad = AmountPad()
    @State private var title = ""
    @State private var kind: EntryKind = .expense
    @State private var date = Date.now
    @State private var category: Category?
    @State private var account: Account?
    @State private var note = ""
    @State private var parsing = false
    @State private var parseMessage: String?
    @State private var showPasteSheet = false
    @State private var pasteText = ""
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    AmountHeader(amountText: $amountText, title: $title, titlePrompt: kind == .income ? "來源" : "商家",
                                 currency: account?.currency ?? Prefs.mainCurrency, pad: $pad)

                    HStack(spacing: 10) {
                        Menu {
                            Picker("類型", selection: $kind) {
                                Label("支出", systemImage: "arrow.up.right").tag(EntryKind.expense)
                                Label("收入", systemImage: "arrow.down.left").tag(EntryKind.income)
                            }
                        } label: {
                            Chip(title: kind.label, symbol: kind == .income ? "arrow.down.left" : "arrow.up.right",
                                 symbolColor: kind == .income ? .green : .orange, showsChevron: true)
                        }
                        .buttonStyle(.plain)

                        DatePicker("", selection: $date)
                            .labelsHidden()
                            .datePickerStyle(.compact)
                    }

                    CategoryChips(income: kind == .income, selected: $category)
                        .autoCategory(from: title, income: kind == .income, selected: $category, enabled: entry == nil, date: date)

                    FlowLayout(spacing: 10) {
                        AccountMenuChip(account: $account)
                        if !goals.filter({ !$0.archived }).isEmpty {
                            Menu {
                                ForEach(goals.filter { !$0.archived }) { g in
                                    Button { goal = g } label: { Label(g.name, systemImage: goal?.id == g.id ? "checkmark" : g.symbol) }
                                }
                                if goal != nil {
                                    Divider()
                                    Button("不歸入目標", systemImage: "xmark") { goal = nil }
                                }
                            } label: {
                                if let goal {
                                    Chip(title: goal.name, symbol: goal.symbol, symbolColor: goal.color, showsChevron: true)
                                } else {
                                    DashedChip(title: "目標")
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        if kind == .expense {
                            Button {
                                excludeFromBudget.toggle()
                            } label: {
                                Chip(title: "不計入預算", symbol: "chart.pie", selected: excludeFromBudget, tint: .purple, removable: true)
                            }
                            .buttonStyle(ChipPressStyle())
                        }
                        NoteChip(note: $note)
                    }

                    if entry == nil {
                        Button {
                            pasteText = UIPasteboard.general.string ?? ""
                            showPasteSheet = true
                        } label: {
                            Label("貼上通知，用 Apple Intelligence 辨識", systemImage: "sparkles")
                                .font(.body.weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.glass)
                        .disabled(parsing)
                    }
                    if parsing { ProgressView("辨識中…") }
                    if let parseMessage {
                        Text(parseMessage).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }

                    if let entry, let raw = entry.rawText {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("原始通知", systemImage: "bell.badge").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            Text(raw).font(.footnote).textSelection(.enabled)
                        }
                        .cardStyle(padding: 16)
                    }

                    if entry != nil {
                        Button("刪除這筆", role: .destructive) { confirmDelete = true }
                            .padding(.top, 8)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 30)
            }
            .amountKeypad(text: $amountText, pad: $pad)
            .scrollDismissesKeyboard(.interactively)
            .background(Color(.systemGroupedBackground))
            .navigationTitle(entry == nil ? "記一筆" : "編輯記帳")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) { save() }
                        .disabled((Money.parse(amountText) ?? 0) <= 0)
                }
            }
            .sensoryFeedback(.selection, trigger: category?.id)
            .onChange(of: kind) { _, newKind in
                if let c = category, c.isIncome != (newKind == .income) { category = nil }
            }
            .confirmationDialog("確定刪除？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("刪除", role: .destructive) {
                    if let entry { context.delete(entry); try? context.save() }
                    dismiss()
                }
            }
            .sheet(isPresented: $showPasteSheet) { pasteSheet }
            .onAppear(perform: load)
        }
    }

    private var pasteSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("把銀行通知的全文貼在這裡", text: $pasteText, axis: .vertical)
                        .lineLimit(5...12)
                } footer: {
                    Text("Apple Intelligence：\(NoticeParser.aiStatusText)。辨識完全在 iPhone 上進行，不會上傳。")
                }
            }
            .navigationTitle("辨識通知")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(role: .close) { showPasteSheet = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) {
                        showPasteSheet = false
                        Task { await parse(pasteText) }
                    }
                    .disabled(pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func parse(_ text: String) async {
        parsing = true
        defer { parsing = false }
        guard let p = await NoticeParser.parse(text, categories: categories.map(\.name), date: date) else {
            parseMessage = "看不出金額，請手動輸入。"
            return
        }
        kind = p.isIncome ? .income : .expense
        amountText = Money.format(p.amount, currency: p.currency).replacingOccurrences(of: ",", with: "")
        title = p.merchant
        category = categories.first { $0.name == p.categoryName && $0.isIncome == p.isIncome }
            ?? Learned.category(for: p.merchant, in: categories.filter { $0.isIncome == p.isIncome })
        if !p.cardLast4.isEmpty, let acc = Store.accounts().first(where: { $0.cardLast4 == p.cardLast4 }) {
            account = acc
        }
        parseMessage = (p.usedAI ? "已用 Apple Intelligence 辨識" : "已用規則辨識（Apple Intelligence 無法使用）") + (p.currency != Prefs.mainCurrency ? "，幣別 \(p.currency)" : "")
    }

    private func load() {
        if let entry {
            amountText = Money.format(entry.amount, currency: entry.account?.currency ?? Prefs.mainCurrency).replacingOccurrences(of: ",", with: "")
            title = entry.title
            kind = entry.kind == .transfer ? .expense : entry.kind
            date = entry.date
            category = entry.category
            account = entry.account
            note = entry.note
            goal = entry.goal
            excludeFromBudget = entry.excludeFromBudget
        } else {
            account = Store.account(id: UserDefaults.standard.string(forKey: Prefs.selectedAccountKey)) ?? Store.account(id: Prefs.defaultAccountID) ?? Store.accounts().first
        }
    }

    private func save() {
        let amount = Money.parse(amountText) ?? 0
        let finalTitle = title.trimmingCharacters(in: .whitespaces).isEmpty ? (category?.name ?? kind.label) : title.trimmingCharacters(in: .whitespaces)
        if let entry {
            entry.amount = amount
            entry.title = finalTitle
            if entry.kind != .transfer { entry.kind = kind }
            entry.date = date
            entry.category = category
            entry.account = account
            entry.note = note
            entry.goal = goal
            entry.excludeFromBudget = excludeFromBudget
        } else {
            let e = Entry(title: finalTitle, amount: amount, kind: kind, date: date, category: category, account: account, note: note)
            e.goal = goal
            e.excludeFromBudget = excludeFromBudget
            context.insert(e)
        }
        try? context.save()
        dismiss()
    }
}
