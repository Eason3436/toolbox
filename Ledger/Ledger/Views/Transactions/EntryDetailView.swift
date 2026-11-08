import SwiftUI
import MapKit
import SwiftData
import PhotosUI

/// 交易詳情：先看內容，按「編輯」才改；可以匯入發票照片
struct EntryDetailView: View {
    @Bindable var entry: Entry
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Prefs.hideAmountsKey) private var hidden = false

    @State private var editing = false
    @State private var photo: PhotosPickerItem?
    @State private var analyzing = false
    @State private var receiptError: String?
    @State private var headerPlay = 0
    @State private var categoryNote: String?
    @State private var showRaw = false
    @State private var confirmDelete = false
    @State private var confirmRemoveReceipt = false

    private var receipt: Receipt? { Receipt.from(entry.receiptJSON) }

    /// 訂閱或帳單產生的記帳
    private var isSubscription: Bool {
        entry.bill != nil || entry.source == .bill || (entry.category?.fullName.contains("訂閱") ?? false)
    }

    /// 平台（App Store、Google Play…）：帳單上的，或備註裡「平台：…」那一行
    private var platform: String? {
        if let p = entry.bill?.platform, !p.isEmpty { return p }
        for line in entry.note.components(separatedBy: .newlines) where line.hasPrefix("平台：") {
            let p = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
            if !p.isEmpty { return p }
        }
        return nil
    }

    private var noteWithoutPlatform: String {
        entry.note.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("平台：") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var currency: String { entry.account?.currency ?? Prefs.mainCurrency }

    var body: some View {
        NavigationStack {
            ScrollView {
                if entry.isDeleted || entry.modelContext == nil {
                    EmptyView()
                } else {
                    VStack(spacing: 16) {
                        header.appearEffect()
                        receiptSection.appearEffect(delay: 0.05)
                        infoCard.appearEffect(delay: 0.1)
                        if entry.kind != .transfer && !entry.title.trimmingCharacters(in: .whitespaces).isEmpty {
                            placeSection.appearEffect(delay: 0.15)
                        }
                        if let raw = entry.rawText, !raw.isEmpty { rawCard(raw) }
                        Button("刪除這筆", role: .destructive) { confirmDelete = true }
                            .padding(.top, 6)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 30)
                }
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .background(Palette.background)
            .navigationTitle("交易詳情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("編輯", systemImage: "pencil") { editing = true }
                        .buttonStyle(.glassProminent)
                }
            }
            .sheet(isPresented: $editing, onDismiss: {
                if entry.isDeleted || entry.modelContext == nil { dismiss() }
            }) {
                EntryEditor(entry: entry)
            }
            .confirmationDialog("確定刪除這筆？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("刪除", role: .destructive) {
                    context.delete(entry)
                    try? context.save()
                    dismiss()
                }
            }
            .confirmationDialog("移除發票內容？", isPresented: $confirmRemoveReceipt, titleVisibility: .visible) {
                Button("移除", role: .destructive) {
                    withAnimation(.snappy) { entry.receiptJSON = nil }
                    try? context.save()
                }
            }
            .task(id: entry.id) {
                // 有位置但分店只寫品牌名（例如「全家」），自己找出是哪一家
                guard entry.kind == .expense, entry.latitude != nil,
                      BranchMatcher.isBrandOnly(entry.branch, merchant: entry.title) else { return }
                await BranchMatcher.refineBranchName(entry)
                try? context.save()
            }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                Task { await importReceipt(item) }
            }
        }
    }

    // MARK: 頂部

    private var header: some View {
        VStack(spacing: 12) {
            Group {
                if entry.kind == .transfer {
                    CategoryIcon(symbol: "arrow.left.arrow.right", color: .blue, size: 72)
                } else if isSubscription, let logo = BrandLogo.subscriptionLogoName(name: entry.title, platform: platform ?? "") {
                    // 訂閱：用服務或平台的 logo
                    MerchantLogo(name: logo, size: 72)
                } else if let c = entry.category {
                    c.icon(size: 72, trigger: headerPlay)
                        .task { try? await Task.sleep(for: .milliseconds(350)); headerPlay += 1 }
                } else {
                    CategoryIcon(symbol: "questionmark", color: .gray, size: 72)
                }
            }
            Text(entry.title).font(.title2.weight(.bold)).multilineTextAlignment(.center)
            MoneyText(value: entry.kind == .transfer ? entry.amount : entry.signedAmount, currency: currency,
                      hidden: hidden, signed: entry.kind != .transfer,
                      font: .system(size: 46, weight: .bold, design: .rounded))
                .foregroundStyle(entry.kind == .income ? .green : .primary)
            HStack(spacing: 8) {
                if let pm = entry.payMethod { PayBadge(method: pm) }
                SourceBadge(source: entry.source)
                if entry.excludeFromBudget {
                    Text("不計入預算").font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color(.tertiarySystemFill), in: .capsule)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var infoCard: some View {
        VStack(spacing: 14) {
            if entry.kind == .transfer {
                row("轉出", entry.account?.name ?? "—")
                row("轉入", entry.toAccount?.name ?? "—")
            } else {
                row("分類", entry.category?.fullName ?? "未分類")
                row("帳戶", entry.account?.name ?? "未指定帳戶")
                if let b = entry.branch { row("分店", b) }
            }
            row("時間", entry.date.formatted(.dateTime.year().month().day().weekday().hour().minute()))
            if let g = entry.goal { row("儲蓄目標", g.name) }
            if let b = entry.bill { row("帳單", b.name) }
            if let platform {
                HStack(alignment: .center) {
                    Text("平台").foregroundStyle(.secondary)
                    Spacer()
                    MerchantLogo(name: platform, size: 22)
                    Text(platform).fontWeight(.medium)
                }
            }
            if !noteWithoutPlatform.isEmpty {
                Divider()
                Text(noteWithoutPlatform).frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(.secondary)
            }
            if let categoryNote {
                Label(categoryNote, systemImage: "info.circle")
                    .font(.footnote).foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .cardStyle()
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium).multilineTextAlignment(.trailing)
        }
    }

    // MARK: 地點與統計

    /// 有實體地點（或發票、捷徑附上位置）才找地圖；回饋、利息這類只顯示統計
    @ViewBuilder
    private var placeSection: some View {
        let hasReceiptStore = receipt?.store.isEmpty == false
        let coordinate: CLLocationCoordinate2D? = entry.latitude.flatMap { lat in
            entry.longitude.map { CLLocationCoordinate2D(latitude: lat, longitude: $0) }
        }
        let showMap = !isSubscription && (hasReceiptStore || coordinate != nil
            || PlaceCheck.hasPlace(title: entry.title, kind: entry.kind, categoryName: entry.category?.fullName))
        let income = entry.kind == .income
        if showMap {
            MerchantMapCard(merchant: hasReceiptStore ? receipt!.store : entry.title,
                            address: receipt?.address, coordinate: coordinate, branch: entry.branch) { compact in
                MerchantSummaryCard(merchant: entry.title, currency: currency, hidden: hidden,
                                    income: income, compact: compact)
            }
        } else {
            MerchantSummaryCard(merchant: entry.title, currency: currency, hidden: hidden, income: income)
        }
    }

    // MARK: 發票

    @ViewBuilder
    private var receiptSection: some View {
        VStack(spacing: 12) {
            if let receipt {
                ReceiptPaperView(receipt: receipt, entryAmount: entry.amount)
                    .frame(maxWidth: 290)
                    .frame(maxWidth: .infinity)
                    .contextMenu {
                        Button("移除發票", systemImage: "trash", role: .destructive) { confirmRemoveReceipt = true }
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let receiptError {
                Label(receiptError, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
            }
        }
        .animation(.snappy, value: entry.receiptJSON)
    }

    private func importReceipt(_ item: PhotosPickerItem) async {
        analyzing = true
        receiptError = nil
        defer { analyzing = false; photo = nil }
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            receiptError = "讀不到這張照片"
            return
        }
        do {
            let (r, catName) = try await ReceiptService.analyze(imageData: data, income: entry.kind == .income)
            withAnimation(.snappy) { entry.receiptJSON = r.json }
            // 依發票品項改分類
            if entry.kind != .transfer,
               let c = Store.categories(income: entry.kind == .income).first(where: { $0.name == catName }),
               c.id != entry.category?.id {
                let old = entry.category?.name ?? "未分類"
                entry.category = c
                categoryNote = "依發票品項把分類從「\(old)」改成「\(c.name)」，按編輯可以改回來"
            }
            if entry.title.isEmpty || entry.title == "未命名", !r.store.isEmpty { entry.title = r.store }
            try? context.save()
            await BranchMatcher.apply(receipt: r, to: entry)
            try? context.save()
        } catch {
            receiptError = error.localizedDescription
        }
    }

    private func rawCard(_ raw: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy) { showRaw.toggle() }
            } label: {
                HStack {
                    Label("原始通知", systemImage: "bell.badge").font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.down").rotationEffect(.degrees(showRaw ? 180 : 0))
                }
                .foregroundStyle(.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if showRaw {
                Text(raw).font(.footnote).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .cardStyle(padding: 16)
    }
}

// MARK: - 小標記

struct PayBadge: View {
    var method: String
    var compact = false

    var body: some View {
        HStack(spacing: 3) {
            if method == "Apple Pay" {
                Image(systemName: "applelogo")
                Text("Pay")
            } else {
                Text(method)
            }
        }
        .font(compact ? .caption2.weight(.bold) : .caption.weight(.bold))
        .foregroundStyle(method == "LINE Pay" ? Color.white : Color.primary)
        .padding(.horizontal, compact ? 5 : 8)
        .padding(.vertical, compact ? 1 : 4)
        .background(background, in: .capsule)
        .overlay(Capsule().strokeBorder(Color.primary.opacity(method == "Apple Pay" ? 0.4 : 0), lineWidth: 1))
        .accessibilityLabel("以 \(method) 付款")
    }

    private var background: Color {
        switch method {
        case "LINE Pay": Color(hex: "#06C755")
        case "Apple Pay": Color(.systemBackground)
        default: Color(.tertiarySystemFill)
        }
    }
}

struct SourceBadge: View {
    var source: EntrySource
    var body: some View {
        let (text, symbol): (String, String) = switch source {
        case .manual: ("手動記帳", "hand.point.up.left")
        case .shortcut: ("捷徑自動記帳", "bolt.fill")
        case .cashew: ("Cashew 匯入", "square.and.arrow.down")
        case .bill: ("帳單", "bolt.fill")
        }
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color(.tertiarySystemFill), in: .capsule)
    }
}

// MARK: - 擬物發票

struct ReceiptPaperView: View {
    var receipt: Receipt
    var entryAmount: Double

    var body: some View {
        VStack(spacing: 10) {
            Text("電子發票證明聯").font(.caption.weight(.bold)).kerning(2).foregroundStyle(.black.opacity(0.55))
            HStack(spacing: 8) {
                // 連鎖店的 logo，放在店名左邊
                MerchantLogo(name: receipt.store, size: 26)
                Text(receipt.store.isEmpty ? "發票" : receipt.store)
                    .font(.title3.weight(.bold)).multilineTextAlignment(.center)
            }
            if !receipt.invoiceNumber.isEmpty {
                Text(formattedNumber)
                    .font(.system(size: 26, weight: .heavy, design: .monospaced))
            }
            if !receipt.date.isEmpty {
                Text(receipt.date).font(.footnote.monospaced()).foregroundStyle(.black.opacity(0.6))
            }
            DashedLine()
            VStack(spacing: 8) {
                ForEach(Array(receipt.items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.name).multilineTextAlignment(.leading)
                        Spacer(minLength: 8)
                        if item.quantity != 1 {
                            Text("x\(item.quantity.formatted(.number.precision(.fractionLength(0...2))))")
                                .foregroundStyle(.black.opacity(0.5))
                        }
                        Text(item.price.formatted(.number.precision(.fractionLength(0...2))))
                            .frame(minWidth: 44, alignment: .trailing)
                    }
                    .font(.subheadline.monospacedDigit())
                }
            }
            DashedLine()
            HStack {
                Text("共 \(receipt.items.count) 項").font(.subheadline)
                Spacer()
                Text("合計 \(receipt.total.formatted(.number.precision(.fractionLength(0...2))))")
                    .font(.headline.monospacedDigit())
            }
            if abs(receipt.total - entryAmount) > 0.5, receipt.total > 0 {
                Label("發票金額和這筆記帳（\(entryAmount.formatted(.number.precision(.fractionLength(0...2))))）不一樣",
                      systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
            // 假條碼
            HStack(spacing: 1.5) {
                ForEach(0..<46, id: \.self) { i in
                    Rectangle().frame(width: [1, 2, 1, 3, 1, 2][i % 6] * 1.0)
                }
            }
            .frame(height: 34)
            .foregroundStyle(.black.opacity(0.8))
            .padding(.top, 4)
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 22)
        .padding(.top, 22)
        .padding(.bottom, 30)
        .frame(maxWidth: .infinity)
        .background {
            ReceiptShape()
                .fill(Color(hex: "#FFFDF7"))
                .shadow(color: .black.opacity(0.15), radius: 10, y: 6)
        }
        .padding(.horizontal, 12)
        .environment(\.colorScheme, .light)
        .accessibilityElement(children: .combine)
    }

    private var formattedNumber: String {
        let n = receipt.invoiceNumber.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        guard n.count == 10 else { return receipt.invoiceNumber }
        return "\(n.prefix(2))-\(n.suffix(8))"
    }
}

/// 上下鋸齒邊的紙張
struct ReceiptShape: Shape {
    var tooth: CGFloat = 8
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let count = max(Int(rect.width / (tooth * 2)), 1)
        let w = rect.width / CGFloat(count)
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + tooth))
        for i in 0..<count {
            let x = rect.minX + CGFloat(i) * w
            p.addLine(to: CGPoint(x: x + w / 2, y: rect.minY))
            p.addLine(to: CGPoint(x: x + w, y: rect.minY + tooth))
        }
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - tooth))
        for i in 0..<count {
            let x = rect.maxX - CGFloat(i) * w
            p.addLine(to: CGPoint(x: x - w / 2, y: rect.maxY))
            p.addLine(to: CGPoint(x: x - w, y: rect.maxY - tooth))
        }
        p.closeSubpath()
        return p
    }
}

struct DashedLine: View {
    var body: some View {
        Line()
            .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            .foregroundStyle(.black.opacity(0.3))
            .frame(height: 1)
    }
    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.minX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return p
        }
    }
}
