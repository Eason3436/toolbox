import SwiftUI
import SwiftData

struct BillEditor: View {
    var bill: Bill?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var amountText = ""
    @State private var name = ""
    @State private var currency = Prefs.mainCurrency
    @State private var recurrence: Recurrence = .monthly
    @State private var anchor = Date.now
    @State private var category: Category?
    @State private var autoPay = false
    @State private var account: Account?
    @State private var platform = ""
    @State private var note = ""
    @State private var isSubscription = true
    @State private var showDate = false
    @State private var editingPlatform = false
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    AmountHeader(amountText: $amountText, title: $name, titlePrompt: "名稱，例如 Apple")

                    FlowLayout(spacing: 10) {
                        Menu {
                            Picker("幣別", selection: $currency) {
                                ForEach(Money.commonCurrencies, id: \.self) { Text($0).tag($0) }
                            }
                        } label: {
                            Chip(title: currency, symbol: "dollarsign.arrow.circlepath", showsChevron: true)
                        }
                        Menu {
                            Picker("週期", selection: $recurrence) {
                                ForEach(Recurrence.allCases) { Text($0.label).tag($0) }
                            }
                        } label: {
                            Chip(title: recurrence.label, symbol: "repeat", showsChevron: true)
                        }
                        Button { showDate = true } label: {
                            Chip(title: dateLabel, symbol: "calendar", showsChevron: true)
                        }
                    }
                    .buttonStyle(.plain)

                    CategoryChips(income: false, selected: $category)

                    Button {
                        withAnimation(.snappy) { autoPay.toggle() }
                    } label: {
                        Chip(title: "自動扣繳", symbol: "bolt.fill", symbolColor: autoPay ? .accentColor : .secondary,
                             selected: autoPay, tint: .accentColor, removable: autoPay)
                    }
                    .buttonStyle(.plain)

                    FlowLayout(spacing: 10) {
                        AccountMenuChip(account: $account)
                        if editingPlatform || !platform.isEmpty {
                            TextField("平台，例如 App Store", text: $platform)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 12)
                                .frame(minWidth: 160)
                                .background(Color(.secondarySystemGroupedBackground), in: .capsule)
                        } else {
                            Button { editingPlatform = true } label: { DashedChip(title: "平台") }
                                .buttonStyle(.plain)
                        }
                        NoteChip(note: $note)
                    }

                    Picker("種類", selection: $isSubscription) {
                        Text("訂閱").tag(true)
                        Text("一般帳單").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 40)

                    if bill != nil {
                        Button("刪除帳單", role: .destructive) { confirmDelete = true }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 30)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(.systemGroupedBackground))
            .navigationTitle(bill == nil ? "新增帳單" : "編輯帳單")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) { save() }
                        .disabled((Money.parse(amountText) ?? 0) <= 0 || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .sheet(isPresented: $showDate) {
                NavigationStack {
                    DatePicker("第一次到期日", selection: $anchor, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .padding()
                        .navigationTitle("到期日")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(role: .confirm) { showDate = false } } }
                }
                .presentationDetents([.medium, .large])
            }
            .confirmationDialog("確定刪除這個帳單？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("刪除", role: .destructive) {
                    if let bill { context.delete(bill); try? context.save() }
                    dismiss()
                }
            } message: {
                Text("已經記下的付款紀錄會保留。")
            }
            .onAppear(perform: load)
        }
    }

    private var dateLabel: String {
        let cal = Calendar.current
        let d = cal.component(.day, from: anchor)
        switch recurrence {
        case .monthly: return "\(d)日"
        case .yearly: return "\(cal.component(.month, from: anchor))月\(d)日"
        case .weekly:
            return "週" + ["日", "一", "二", "三", "四", "五", "六"][cal.component(.weekday, from: anchor) - 1]
        case .once:
            return "\(cal.component(.month, from: anchor))/\(d)"
        }
    }

    private func load() {
        guard let bill else { return }
        amountText = Money.format(bill.amount, currency: bill.currency).replacingOccurrences(of: ",", with: "")
        name = bill.name
        currency = bill.currency
        recurrence = bill.recurrence
        anchor = bill.anchorDate
        category = bill.category
        autoPay = bill.autoPay
        account = bill.account
        platform = bill.platform
        note = bill.note
        isSubscription = bill.isSubscription
    }

    private func save() {
        let target = bill ?? {
            let b = Bill(name: name, amount: 0)
            context.insert(b)
            return b
        }()
        target.name = name.trimmingCharacters(in: .whitespaces)
        target.amount = Money.parse(amountText) ?? 0
        target.currency = currency
        target.recurrence = recurrence
        target.anchorDate = Calendar.current.startOfDay(for: anchor)
        target.category = category
        target.autoPay = autoPay
        target.account = account
        target.platform = platform
        target.note = note
        target.isSubscription = isSubscription
        try? context.save()
        if autoPay { BillService.processAutoPay(context: context) }
        dismiss()
    }
}
