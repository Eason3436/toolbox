import SwiftUI
import SwiftData
import PhotosUI

struct EntryEditor: View {
    var entry: Entry?
    var start: AddStart = .normal

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.entrySavedHandler) private var savedHandler
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

    // 智慧輸入
    @State private var smartMode: SmartMode?
    @State private var sentence = ""
    @FocusState private var sentenceFocused: Bool
    @State private var photo: PhotosPickerItem?
    @State private var receipt: Receipt?
    @State private var smartMessage: String?
    @State private var showScanner = false

    enum SmartMode { case sentence }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Picker("類型", selection: $kind.animation(Motion.chip)) {
                        Text("支出").tag(EntryKind.expense)
                        Text("收入").tag(EntryKind.income)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)

                    AmountHeader(amountText: $amountText, title: $title, titlePrompt: kind == .income ? "來源" : "商家",
                                 currency: account?.currency ?? Prefs.mainCurrency, pad: $pad)

                    if entry == nil { smartCard } else { receiptButton }

                    if let receipt {
                        ReceiptPaperView(receipt: receipt, entryAmount: Money.parse(amountText) ?? 0)
                            .frame(maxWidth: 260)
                            .overlay(alignment: .topTrailing) {
                                Button {
                                    withAnimation(Motion.layout) { self.receipt = nil }
                                } label: {
                                    Image(systemName: "xmark").font(.caption.weight(.bold)).frame(width: 26, height: 26)
                                }
                                .buttonStyle(.glass).buttonBorderShape(.circle)
                                .offset(x: 10, y: -8)
                            }
                            .transition(.scale(scale: 0.9, anchor: .top).combined(with: .opacity))
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("分類")
                        CategoryChips(income: kind == .income, selected: $category)
                            .autoCategory(from: title, income: kind == .income, selected: $category, enabled: entry == nil, date: date)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("細節")
                        detailsCard
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
                .animation(Motion.layout, value: receipt)
                .animation(Motion.layout, value: smartMode)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .amountKeypad(text: $amountText, pad: $pad)
            .scrollDismissesKeyboard(.interactively)
            .background(Palette.background)
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
            .onChange(of: photo) { _, item in
                guard let item else { return }
                Task { await scanReceipt(item) }
            }
            .confirmationDialog("確定刪除？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("刪除", role: .destructive) {
                    if let entry { context.delete(entry); try? context.save() }
                    dismiss()
                }
            }
            .sheet(isPresented: $showPasteSheet) { pasteSheet }
            .photosPicker(isPresented: $showScanner, selection: $photo, matching: .images)
            .onAppear(perform: load)
            .task {
                // 從首頁的快速按鈕進來：直接打開一句話輸入或選發票照片
                guard entry == nil, start != .normal else { return }
                try? await Task.sleep(for: .milliseconds(350))
                switch start {
                case .sentence:
                    pad.visible = false
                    withAnimation(Motion.layout) { smartMode = .sentence }
                    sentenceFocused = true
                case .scan:
                    pad.visible = false
                    showScanner = true
                case .normal: break
                }
            }
        }
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.leading, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 智慧輸入：一句話／掃發票（貼通知只在捷徑用）

    private var smartCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                smartButton("一句話", "text.bubble.fill", active: smartMode == .sentence) {
                    withAnimation(Motion.layout) { smartMode = smartMode == .sentence ? nil : .sentence }
                    if smartMode == .sentence {
                        pad.visible = false
                        sentenceFocused = true
                    }
                }
                smartButton("掃發票", "doc.text.viewfinder", active: false) { showScanner = true }
            }

            if smartMode == .sentence {
                HStack(spacing: 8) {
                    TextField("例如：昨天中午麥當勞 150 用台新", text: $sentence, axis: .vertical)
                        .lineLimit(1...3)
                        .focused($sentenceFocused)
                        .submitLabel(.send)
                        .onSubmit { Task { await parseSentence() } }
                    Button {
                        Task { await parseSentence() }
                    } label: {
                        Image(systemName: "arrow.up").font(.body.weight(.bold)).frame(width: 34, height: 34)
                    }
                    .buttonStyle(.glassProminent).buttonBorderShape(.circle)
                    .disabled(sentence.trimmingCharacters(in: .whitespaces).isEmpty || parsing)
                }
                .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 6)
                .background(Palette.card, in: .rect(cornerRadius: 22, style: .continuous))
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }

            if parsing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("辨識中…")
                }
                .font(.footnote).foregroundStyle(.secondary)
                .transition(.blurReplace)
            } else if let msg = smartMessage ?? parseMessage {
                Label(msg, systemImage: "checkmark.circle")
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .transition(.blurReplace)
            }
        }
        .animation(Motion.layout, value: parsing)
    }

    private func smartButton(_ title: String, _ symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { smartLabel(title, symbol, active: active) }
            .buttonStyle(ChipPressStyle())
    }

    private func smartLabel(_ title: String, _ symbol: String, active: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.title3)
                .foregroundStyle(active ? Color.white : Color.accentColor)
            Text(title).font(.caption.weight(.semibold))
                .foregroundStyle(active ? Color.white : Color.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(active ? Color.accentColor : Palette.card,
                    in: .rect(cornerRadius: 18, style: .continuous))
        .contentShape(.rect)
    }

    // MARK: 細節（帳戶、時間、目標、預算、備註）

    private var detailsCard: some View {
        VStack(spacing: 0) {
            detailRow("creditcard.fill", account?.color ?? .gray, "帳戶") {
                Menu {
                    ForEach(Store.accounts().filter { !$0.archived }) { a in
                        Button { account = a } label: {
                            Label(a.name, systemImage: account?.id == a.id ? "checkmark" : a.kind.symbol)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(account?.name ?? "選擇").foregroundStyle(account == nil ? .secondary : .primary)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Divider().padding(.leading, 52)
            detailRow("clock.fill", Palette.icon, "時間") {
                DatePicker("", selection: $date).labelsHidden()
            }
            if !goals.filter({ !$0.archived }).isEmpty {
                Divider().padding(.leading, 52)
                detailRow("target", Palette.icon, "儲蓄目標") {
                    Menu {
                        Button("不歸入目標") { goal = nil }
                        ForEach(goals.filter { !$0.archived }) { g in
                            Button { goal = g } label: { Label(g.name, systemImage: goal?.id == g.id ? "checkmark" : g.symbol) }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(goal?.name ?? "無").foregroundStyle(goal == nil ? .secondary : .primary)
                            Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if kind == .expense {
                Divider().padding(.leading, 52)
                detailRow("chart.pie.fill", Palette.icon, "不計入預算") {
                    Toggle("", isOn: $excludeFromBudget.animation(Motion.chip)).labelsHidden()
                }
            }
            Divider().padding(.leading, 52)
            HStack(alignment: .top, spacing: 12) {
                detailIcon("text.alignleft", .orange)
                TextField("備註", text: $note, axis: .vertical)
                    .lineLimit(1...4)
                    .padding(.top, 5)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
        .font(.subheadline)
        .background(Palette.card, in: .rect(cornerRadius: 20, style: .continuous))
    }

    private func detailIcon(_ symbol: String, _ color: Color) -> some View {
        Image(systemName: symbol)
            .font(.footnote.weight(.semibold)).foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(color.gradient, in: .rect(cornerRadius: 8, style: .continuous))
    }

    private func detailRow<V: View>(_ symbol: String, _ color: Color, _ title: String, @ViewBuilder trailing: () -> V) -> some View {
        HStack(spacing: 12) {
            detailIcon(symbol, color)
            Text(title)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 50)
    }

    // MARK: 智慧輸入的動作

    private func parseSentence() async {
        let text = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sentenceFocused = false
        parsing = true
        defer { parsing = false }
        do {
            let r = try await QuickEntryParser.parse(text)
            withAnimation(Motion.layout) {
                kind = r.isIncome ? .income : .expense
                if r.amount > 0 { amountText = Money.format(r.amount, currency: account?.currency ?? Prefs.mainCurrency).replacingOccurrences(of: ",", with: "") }
                if !r.merchant.isEmpty { title = r.merchant }
                if let c = r.category { category = c }
                date = r.date
                if let a = r.account { account = a }
                if !r.note.isEmpty { note = r.note }
                smartMode = nil
            }
            sentence = ""
            smartMessage = "已依照「\(text)」填好，看一下再按 ✓"
        } catch {
            smartMessage = error.localizedDescription
        }
    }

    /// 編輯時：匯入／重新匯入發票
    private var receiptButton: some View {
        VStack(spacing: 6) {
            Button { showScanner = true } label: {
                HStack(spacing: 8) {
                    if parsing {
                        ProgressView().controlSize(.small)
                        Text("正在讀發票…")
                    } else {
                        Image(systemName: receipt == nil ? "doc.text.viewfinder" : "arrow.triangle.2.circlepath")
                        Text(receipt == nil ? "匯入發票" : "重新匯入發票")
                    }
                }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            .buttonStyle(.glass)
            .disabled(parsing)
            if let msg = smartMessage {
                Text(msg).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
    }

    private func scanReceipt(_ item: PhotosPickerItem) async {
        parsing = true
        smartMessage = nil
        defer { parsing = false; photo = nil }
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            smartMessage = "讀不到這張照片"
            return
        }
        do {
            let (r, catName) = try await ReceiptService.analyze(imageData: data, income: false)
            withAnimation(Motion.layout) {
                kind = .expense
                receipt = r
                if r.total > 0 { amountText = Money.format(r.total, currency: account?.currency ?? Prefs.mainCurrency).replacingOccurrences(of: ",", with: "") }
                if !r.store.isEmpty { title = r.store }
                if let c = Store.categories(income: false).first(where: { $0.name == catName }) { category = c }
                if let d = r.parsedDate { date = d }
                pad.visible = false
            }
            smartMessage = "已從發票填好金額、商家和分類（照片不會存）"
        } catch {
            smartMessage = error.localizedDescription
        }
    }

    private var pasteSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("把銀行通知的全文貼在這裡", text: $pasteText, axis: .vertical)
                        .lineLimit(5...12)
                } footer: {
                    Text("辨識完全在 iPhone 上進行，不會上傳。")
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
        parseMessage = "已自動填好" + (p.currency != Prefs.mainCurrency ? "，幣別 \(p.currency)" : "")
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
            receipt = Receipt.from(entry.receiptJSON)
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
            let newJSON: String? = receipt?.json
            if Receipt.from(newJSON) != Receipt.from(entry.receiptJSON) {
                entry.receiptJSON = newJSON
                if let r = receipt {
                    let ctx = context
                    Task { @MainActor in
                        await BranchMatcher.apply(receipt: r, to: entry)
                        try? ctx.save()
                    }
                }
            }
        } else {
            let e = Entry(title: finalTitle, amount: amount, kind: kind, date: date, category: category, account: account, note: note)
            e.goal = goal
            e.receiptJSON = receipt?.json
            e.excludeFromBudget = excludeFromBudget
            context.insert(e)
            if let r = receipt {
                let ctx = context
                Task { @MainActor in
                    await BranchMatcher.apply(receipt: r, to: e)
                    try? ctx.save()
                }
            }
        }
        try? context.save()
        if entry == nil, let savedHandler {
            savedHandler(SavedEntrySummary(
                title: finalTitle,
                amountText: (kind == .income ? "+" : "-") + Money.format(amount, currency: account?.currency ?? Prefs.mainCurrency),
                symbol: category?.symbol ?? (kind == .income ? "arrow.down.left" : "tag.fill"),
                color: category?.color ?? .gray,
                income: kind == .income))
        } else {
            dismiss()
        }
    }
}
