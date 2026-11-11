import SwiftUI
import SwiftData

struct AccountEditor: View {
    var account: Account?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Account.order) private var accounts: [Account]

    @State private var name = ""
    @State private var kind: AccountKind = .debit
    @State private var currency = Prefs.mainCurrency
    @State private var color: Color = Color(hex: "#2C2C2E")
    @State private var initialText = ""
    @State private var last4 = ""
    @State private var confirmDelete = false

    private let palette = ["#2C2C2E", "#1F3A5F", "#2F7D32", "#A0522D", "#5E1F3C", "#6A4C9C", "#B3261E", "#00796B", "#C77700", "#455A64"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AccountCard(account: preview, hidden: false)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                Section("基本資料") {
                    TextField("名稱，例如：台新 日常", text: $name)
                    Picker("類型", selection: $kind) {
                        ForEach(AccountKind.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                    }
                    Picker("幣別", selection: $currency) {
                        ForEach(Money.commonCurrencies, id: \.self) { Text($0).tag($0) }
                    }
                    TextField("期初餘額", text: $initialText)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("卡號末四碼（比對銀行通知用）", text: $last4)
                        .keyboardType(.numberPad)
                }
                Section("顏色") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 14) {
                        ForEach(palette, id: \.self) { hex in
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 40, height: 40)
                                .overlay {
                                    if color.hexString == hex {
                                        Image(systemName: "checkmark").font(.headline).foregroundStyle(.white)
                                    }
                                }
                                .onTapGesture { color = Color(hex: hex) }
                        }
                    }
                    .padding(.vertical, 6)
                    ColorPicker("自訂顏色", selection: $color, supportsOpacity: false)
                }
                if let account {
                    Section {
                        Button(account.archived ? "取消封存" : "封存帳戶") {
                            account.archived.toggle()
                            try? context.save()
                            dismiss()
                        }
                        Button("刪除帳戶", role: .destructive) { confirmDelete = true }
                    } footer: {
                        Text("刪除時可以選擇保留交易（變成「未指定帳戶」）或一起刪除。")
                    }
                }
            }
            .navigationTitle(account == nil ? "新增帳戶" : "編輯帳戶")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog("刪除「\(account?.name ?? "")」？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("只刪帳戶，保留交易", role: .destructive) {
                    if let account { Haptics.shared.trash(); Store.delete(account, withEntries: false, context: context) }
                    dismiss()
                }
                Button("連同 \(account?.entries?.count ?? 0) 筆交易一起刪除", role: .destructive) {
                    if let account { Haptics.shared.trash(); Store.delete(account, withEntries: true, context: context) }
                    dismiss()
                }
            } message: {
                Text("刪除後無法復原。")
            }
            .onAppear(perform: load)
        }
    }

    private var preview: Account {
        let a = Account(name: name.isEmpty ? "新帳戶" : name, kind: kind, currency: currency, colorHex: color.hexString,
                        initialBalance: Money.parse(initialText) ?? 0)
        a.cardLast4 = last4
        return a
    }

    private func load() {
        guard let account else { return }
        name = account.name
        kind = account.kind
        currency = account.currency
        color = account.color
        initialText = account.initialBalance == 0 ? "" : Money.format(account.initialBalance, currency: account.currency)
        last4 = account.cardLast4
    }

    private func save() {
        let target: Account
        if let account {
            target = account
        } else {
            target = Account(name: name, order: (accounts.map(\.order).max() ?? 0) + 1)
            context.insert(target)
            UserDefaults.standard.set(target.id.uuidString, forKey: Prefs.selectedAccountKey)
        }
        target.name = name.trimmingCharacters(in: .whitespaces)
        target.kind = kind
        target.currency = currency
        target.colorHex = color.hexString
        target.initialBalance = Money.parse(initialText) ?? 0
        target.cardLast4 = String(last4.filter(\.isNumber).suffix(4))
        try? context.save()
        dismiss()
    }
}

struct TransferEditor: View {
    var from: Account?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Account.order) private var accounts: [Account]

    @State private var fromID: UUID?
    @State private var toID: UUID?
    @State private var amountText = ""
    @State private var pad = AmountPad()
    @State private var date = Date.now
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AmountField(text: $amountText, pad: $pad,
                                currencyCode: accounts.first(where: { $0.id == fromID })?.currency ?? Prefs.mainCurrency)
                        .listRowBackground(Color.clear)
                }
                Section {
                    Picker("從", selection: $fromID) {
                        ForEach(accounts.filter { !$0.archived }) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Picker("到", selection: $toID) {
                        ForEach(accounts.filter { !$0.archived }) { Text($0.name).tag(Optional($0.id)) }
                    }
                    DatePicker("日期", selection: $date)
                    TextField("備註", text: $note)
                }
            }
            .amountKeypad(text: $amountText, pad: $pad)
            .navigationTitle("轉帳")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) { save() }
                        .disabled((Money.parse(amountText) ?? 0) <= 0 || fromID == nil || toID == nil || fromID == toID)
                }
            }
            .onAppear {
                fromID = from?.id ?? accounts.first?.id
                toID = accounts.first { $0.id != fromID && !$0.archived }?.id
            }
        }
    }

    private func save() {
        let a = accounts.first { $0.id == fromID }
        let b = accounts.first { $0.id == toID }
        let e = Entry(title: "轉帳到 \(b?.name ?? "")", amount: Money.parse(amountText) ?? 0, kind: .transfer, date: date, account: a, note: note)
        e.toAccount = b
        context.insert(e)
        try? context.save()
        dismiss()
    }
}

/// 刪除帳戶的確認對話框（主頁選單、資產頁滑動都用這個）
struct AccountDeleteDialog: ViewModifier {
    @Binding var account: Account?
    @Environment(\.modelContext) private var context

    func body(content: Content) -> some View {
        content.confirmationDialog("刪除「\(account?.name ?? "")」？",
                                   isPresented: Binding(get: { account != nil }, set: { if !$0 { account = nil } }),
                                   titleVisibility: .visible) {
            Button("只刪帳戶，保留交易", role: .destructive) {
                if let account { withAnimation { Haptics.shared.trash(); Store.delete(account, withEntries: false, context: context) } }
                account = nil
            }
            Button("連同 \(account?.entries?.count ?? 0) 筆交易一起刪除", role: .destructive) {
                if let account { withAnimation { Haptics.shared.trash(); Store.delete(account, withEntries: true, context: context) } }
                account = nil
            }
        } message: {
            Text("刪除後無法復原。")
        }
    }
}

extension View {
    func accountDeleteDialog(_ account: Binding<Account?>) -> some View {
        modifier(AccountDeleteDialog(account: account))
    }
}
