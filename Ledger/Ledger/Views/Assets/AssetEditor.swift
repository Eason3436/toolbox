import SwiftUI
import SwiftData

struct AssetEditor: View {
    var asset: Asset?
    var initialKind: AssetKind = .stock

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Asset.order) private var assets: [Asset]

    @State private var kind: AssetKind = .stock
    @State private var name = ""
    @State private var ticker = ""
    @State private var quantityText = ""
    @State private var costText = ""
    @State private var valueText = ""
    @State private var currency = Prefs.mainCurrency
    @State private var autoQuote = true
    @State private var note = ""
    @State private var lookingUp = false
    @State private var quote: Quote?
    @State private var lookupError: String?
    @State private var confirmDelete = false

    private var quoteMode: Bool { kind.supportsQuote && autoQuote }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(AssetKind.allCases) { k in
                                Button {
                                    withAnimation(.snappy) { kind = k }
                                } label: {
                                    Chip(title: k.label, symbol: k.symbol, selected: kind == k, tint: k.group.color)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .listRowBackground(Color.clear)
                }

                if kind.supportsQuote {
                    Section {
                        Toggle("自動報價", isOn: $autoQuote)
                        if autoQuote {
                            HStack {
                                TextField(kind == .crypto ? "代號，例如 BTC-USD" : "代號，例如 2330、0050、AAPL", text: $ticker)
                                    .textInputAutocapitalization(.characters)
                                    .autocorrectionDisabled()
                                    .onSubmit { Task { await lookup() } }
                                Button {
                                    Task { await lookup() }
                                } label: {
                                    if lookingUp { ProgressView() } else { Text("查詢") }
                                }
                                .buttonStyle(.glass)
                                .disabled(ticker.isEmpty || lookingUp)
                            }
                            if let quote {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(quote.name ?? quote.symbol).font(.subheadline.weight(.semibold))
                                        Text(quote.symbol).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text("\(quote.currency) \(Money.format(quote.price, currency: "USD"))").monospacedDigit()
                                }
                            }
                            if let lookupError {
                                Text(lookupError).font(.footnote).foregroundStyle(.red)
                            }
                        }
                    } header: {
                        Text("報價")
                    } footer: {
                        if autoQuote {
                            Text("台股輸入數字代號即可（上市自動加 .TW、上櫃 .TWO）。美股輸入英文代號，加密貨幣用 BTC-USD 這種格式。")
                        }
                    }
                }

                Section("資料") {
                    TextField("名稱", text: $name)
                    if quoteMode, !(asset?.lots ?? []).isEmpty {
                        LabeledContent("持股", value: "由買賣紀錄計算")
                    } else if quoteMode {
                        TextField("持有數量（股數／單位）", text: $quantityText)
                            .keyboardType(.decimalPad)
                        TextField("平均成本（每股，選填）", text: $costText)
                            .keyboardType(.decimalPad)
                    } else {
                        TextField(kind == .loan ? "剩餘本金" : "目前價值", text: $valueText)
                            .keyboardType(.decimalPad)
                        Picker("幣別", selection: $currency) {
                            ForEach(Money.commonCurrencies, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    TextField("備註", text: $note, axis: .vertical)
                }

                if quoteMode, let price = quote?.price ?? asset?.lastPrice, price > 0, let qty = Money.parse(quantityText) {
                    Section {
                        HStack {
                            Text("目前市值")
                            Spacer()
                            Text("\(quote?.currency ?? currency) \(Money.format(price * qty, currency: quote?.currency ?? currency))")
                                .monospacedDigit().font(.headline)
                        }
                    }
                }

                if asset != nil {
                    Section {
                        Button("刪除資產", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle(asset == nil ? "新增資產" : "編輯資產")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) { Task { await save() } }
                        .disabled(!canSave)
                }
            }
            .confirmationDialog("確定刪除？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("刪除", role: .destructive) {
                    if let asset { context.delete(asset); try? context.save() }
                    dismiss()
                }
            }
            .onAppear(perform: load)
        }
    }

    private var canSave: Bool {
        if quoteMode { return !ticker.isEmpty && ((Money.parse(quantityText) ?? 0) > 0 || !(asset?.lots ?? []).isEmpty) }
        return !name.trimmingCharacters(in: .whitespaces).isEmpty && Money.parse(valueText) != nil
    }

    private func lookup() async {
        lookingUp = true
        lookupError = nil
        defer { lookingUp = false }
        do {
            let q = try await QuoteService.resolve(ticker)
            quote = q
            ticker = q.symbol
            currency = q.currency
            if name.isEmpty { name = q.name ?? q.symbol }
        } catch {
            quote = nil
            lookupError = error.localizedDescription
        }
    }

    private func load() {
        guard let asset else {
            kind = initialKind
            autoQuote = initialKind.supportsQuote
            return
        }
        kind = asset.kind
        name = asset.name
        ticker = asset.ticker
        quantityText = asset.quantity == 0 ? "" : String(asset.quantity.formatted(.number.grouping(.never)))
        costText = asset.costPerUnit == 0 ? "" : String(asset.costPerUnit.formatted(.number.grouping(.never)))
        valueText = asset.manualValue == 0 ? "" : String(asset.manualValue.formatted(.number.grouping(.never)))
        currency = asset.currency
        autoQuote = asset.autoQuote
        note = asset.note
    }

    private func save() async {
        if quoteMode && quote == nil && asset?.ticker.uppercased() != ticker.uppercased() {
            await lookup()
            if quote == nil { return }
        }
        let target = asset ?? {
            let a = Asset(name: name, kind: kind)
            a.order = (assets.map(\.order).max() ?? 0) + 1
            context.insert(a)
            return a
        }()
        target.kind = kind
        target.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? (quote?.name ?? ticker) : name.trimmingCharacters(in: .whitespaces)
        target.autoQuote = quoteMode
        target.note = note
        if quoteMode {
            target.ticker = ticker.uppercased()
            if (target.lots ?? []).isEmpty {
                target.quantity = Money.parse(quantityText) ?? 0
                target.costPerUnit = Money.parse(costText) ?? 0
                // 新資產：把持股記成第一筆買入
                if asset == nil, target.quantity > 0 {
                    let lot = AssetLot(date: .now, quantity: target.quantity, price: target.costPerUnit > 0 ? target.costPerUnit : (quote?.price ?? 0))
                    lot.asset = target
                    context.insert(lot)
                    if target.costPerUnit == 0 { target.costPerUnit = lot.price }
                }
            }
            if let q = quote {
                target.lastPrice = q.price
                target.previousClose = q.previousClose
                target.currency = q.currency
                target.priceUpdatedAt = .now
            }
        } else {
            target.manualValue = Money.parse(valueText) ?? 0
            target.currency = currency
        }
        try? context.save()
        if target.currency != Prefs.mainCurrency {
            await QuoteService.updateRates(for: [target.currency])
        }
        dismiss()
    }
}
