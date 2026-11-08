import SwiftUI
import SwiftData
import PhotosUI

/// 設定 → 匯入發票照片：一次選很多張，辨識後用時間＋金額找到原本的記帳填進去
struct ReceiptBatchView: View {
    @Environment(\.modelContext) private var context
    @AppStorage(Prefs.hideAmountsKey) private var hidden = false

    @State private var picked: [PhotosPickerItem] = []
    @State private var rows: [Row] = []
    @State private var running = false

    struct Row: Identifiable {
        enum Status {
            case waiting, working
            case matched(Entry)
            case added(Entry)
            case unmatched(Receipt, category: String)
            case failed(String)
        }
        let id = UUID()
        var item: PhotosPickerItem
        var state: Status = .waiting
    }

    private var doneCount: Int {
        rows.filter { if case .waiting = $0.state { return false }; if case .working = $0.state { return false }; return true }.count
    }

    var body: some View {
        List {
            Section {
                PhotosPicker(selection: $picked, maxSelectionCount: nil, selectionBehavior: .ordered, matching: .images) {
                    Label("選擇發票照片", systemImage: "photo.on.rectangle.angled")
                }
                .disabled(running)
            } footer: {
                Text("在 iPhone 上辨識，照片不會存起來。用發票上的日期時間和金額找對應的記帳，找到就把發票內容和分店填進去；找不到的可以直接新增一筆。")
            }

            if !rows.isEmpty {
                Section {
                    if running {
                        ProgressView(value: Double(doneCount), total: Double(rows.count)) {
                            Text("辨識中 \(doneCount)/\(rows.count)").font(.subheadline)
                        }
                    } else {
                        summary
                    }
                }
                Section("結果") {
                    ForEach($rows) { $row in
                        rowView($row)
                    }
                }
            }
        }
        .navigationTitle("匯入發票照片")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            rows = items.map { Row(item: $0) }
            picked = []
            Task { await runAll() }
        }
    }

    private var summary: some View {
        let matched = rows.filter { if case .matched = $0.state { return true }; return false }.count
        let added = rows.filter { if case .added = $0.state { return true }; return false }.count
        let unmatched = rows.filter { if case .unmatched = $0.state { return true }; return false }.count
        let failed = rows.filter { if case .failed = $0.state { return true }; return false }.count
        return HStack(spacing: 0) {
            stat("填入", matched + added, .green)
            stat("找不到", unmatched, .orange)
            stat("失敗", failed, .secondary)
        }
    }

    private func stat(_ title: String, _ n: Int, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(n)").font(.title2.weight(.bold)).monospacedDigit().foregroundStyle(color)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func rowView(_ row: Binding<Row>) -> some View {
        switch row.wrappedValue.state {
        case .waiting:
            Label("等待中", systemImage: "clock").foregroundStyle(.secondary)
        case .working:
            HStack(spacing: 10) { ProgressView(); Text("辨識中…").foregroundStyle(.secondary) }
        case .matched(let e), .added(let e):
            HStack(spacing: 12) {
                MerchantLogo(name: e.title, size: 32) {
                    Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.title).lineLimit(1)
                    Text(e.date.formatted(.dateTime.month().day().hour().minute()) + (isAdded(row.wrappedValue) ? "・新增" : "・已填入"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(Money.format(e.amount, hidden: hidden)).monospacedDigit()
            }
        case .unmatched(let r, let cat):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    MerchantLogo(name: r.store, size: 32) {
                        Image(systemName: "questionmark.circle.fill").font(.title2).foregroundStyle(.orange)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.store.isEmpty ? "發票" : r.store).lineLimit(1)
                        Text(r.date.isEmpty ? "沒有對應的記帳" : "\(r.date)・沒有對應的記帳")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(Money.format(r.total, hidden: hidden)).monospacedDigit()
                }
                Button("新增成一筆記帳", systemImage: "plus.circle") {
                    let e = add(r, category: cat)
                    row.wrappedValue.state = .added(e)
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderless)
            }
        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.orange)
        }
    }

    private func isAdded(_ row: Row) -> Bool {
        if case .added = row.state { return true }
        return false
    }

    // MARK: 處理

    private func runAll() async {
        running = true
        defer { running = false }
        var used: Set<UUID> = []
        for i in rows.indices {
            rows[i].state = .working
            guard let data = try? await rows[i].item.loadTransferable(type: Data.self) else {
                rows[i].state = .failed("讀不到這張照片")
                continue
            }
            do {
                let (r, cat) = try await ReceiptService.analyze(imageData: data, income: false)
                if let e = findEntry(for: r, excluding: used) {
                    used.insert(e.id)
                    await fill(e, with: r)
                    rows[i].state = .matched(e)
                } else {
                    rows[i].state = .unmatched(r, category: cat)
                }
            } catch {
                rows[i].state = .failed(error.localizedDescription)
            }
        }
        try? context.save()
    }

    /// 金額一樣、時間最接近（同一天內；發票有時間就要在 3 小時內），沒有發票的優先
    private func findEntry(for r: Receipt, excluding used: Set<UUID>) -> Entry? {
        guard r.total > 0 else { return nil }
        let parsed = Self.parseDate(r.date)
        let lo = r.total - 0.5, hi = r.total + 0.5
        let expense = EntryKind.expense.rawValue
        let fetch = FetchDescriptor<Entry>(predicate: #Predicate<Entry> { e in
            e.kindRaw == expense && e.amount >= lo && e.amount <= hi
        })
        let candidates = ((try? context.fetch(fetch)) ?? []).filter { !used.contains($0.id) }
        guard !candidates.isEmpty else { return nil }
        let storeKey = BrandLogo.groupKey(for: r.store)

        func score(_ e: Entry) -> Double? {
            var s: Double = 0
            if let p = parsed {
                let date = p.0, hasTime = p.1
                let diff = abs(e.date.timeIntervalSince(date))
                if hasTime {
                    guard diff <= 3 * 3600 else { return nil }
                    s += diff
                } else {
                    guard Calendar.current.isDate(e.date, inSameDayAs: date) else { return nil }
                    s += 3600
                }
            } else {
                // 發票沒日期：只接受最近 60 天內、店名對得上的
                guard e.date > .now.addingTimeInterval(-60 * 86400),
                      !r.store.isEmpty, BrandLogo.groupKey(for: e.title) == storeKey else { return nil }
                s += 86400
            }
            if e.receiptJSON != nil { s += 30 * 86400 }
            if !r.store.isEmpty, BrandLogo.groupKey(for: e.title) == storeKey
                || e.title.localizedCaseInsensitiveContains(BranchMatcher.searchName(r.store)) {
                s -= 1800
            }
            return s
        }
        return candidates.compactMap { e in score(e).map { (e, $0) } }.min { $0.1 < $1.1 }?.0
    }

    private func fill(_ e: Entry, with r: Receipt) async {
        e.receiptJSON = r.json
        if e.title.trimmingCharacters(in: .whitespaces).isEmpty || e.title == "未命名" || PayMethod.isPayMethod(e.title),
           !r.store.isEmpty {
            e.title = r.store
        }
        await BranchMatcher.apply(receipt: r, to: e)
        await BranchMatcher.refineBranchName(e)
    }

    private func add(_ r: Receipt, category: String) -> Entry {
        let cat = Store.categories(income: false).first { $0.name == category }
        let account = Store.account(id: Prefs.defaultAccountID) ?? Store.accounts().first
        let date = Self.parseDate(r.date)?.0 ?? .now
        let e = Entry(title: r.store.isEmpty ? "未命名" : r.store, amount: r.total, kind: .expense, date: date,
                      category: cat, account: account)
        e.receiptJSON = r.json
        context.insert(e)
        try? context.save()
        Task {
            await BranchMatcher.apply(receipt: r, to: e)
            await BranchMatcher.refineBranchName(e)
            try? context.save()
        }
        return e
    }

    /// 「2026/11/6 11:02:00」「115/11/06 11:02」「2026-11-06」→ 日期（以及有沒有時間）
    static func parseDate(_ text: String) -> (Date, Bool)? {
        let t = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        let pattern = #"(\d{2,4})\s*[/\-.年]\s*(\d{1,2})\s*[/\-.月]\s*(\d{1,2})日?(?:\D{0,3}?(\d{1,2}):(\d{2})(?::(\d{2}))?)?"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) else { return nil }
        func int(_ i: Int) -> Int? {
            guard let r = Range(m.range(at: i), in: t) else { return nil }
            return Int(t[r])
        }
        guard var y = int(1), let mo = int(2), let d = int(3) else { return nil }
        if y < 1911 { y += 1911 }   // 民國年
        var c = DateComponents(year: y, month: mo, day: d)
        let hasTime = int(4) != nil
        if hasTime {
            c.hour = int(4)
            c.minute = int(5)
            c.second = int(6) ?? 0
        } else {
            c.hour = 12
        }
        guard let date = Calendar.current.date(from: c) else { return nil }
        return (date, hasTime)
    }
}
