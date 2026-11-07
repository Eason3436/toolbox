import SwiftUI
import SwiftData

/// 編輯畫面上方：大大的金額＋名稱
struct AmountHeader: View {
    @Binding var amountText: String
    @Binding var title: String
    var titlePrompt: String = "名稱"
    @FocusState private var focus: Field?
    enum Field { case amount, title }

    var body: some View {
        VStack(spacing: 6) {
            TextField("0", text: $amountText)
                .font(.system(size: 64, weight: .bold, design: .rounded))
                .monospacedDigit()
                .multilineTextAlignment(.center)
                .keyboardType(.decimalPad)
                .focused($focus, equals: .amount)
                .minimumScaleFactor(0.4)
            TextField(titlePrompt, text: $title)
                .font(.title2)
                .multilineTextAlignment(.center)
                .focused($focus, equals: .title)
                .submitLabel(.done)
        }
        .padding(.top, 8)
    }
}

/// 分類膠囊（顯示常用分類＋「全部」）
struct CategoryChips: View {
    var income: Bool
    @Binding var selected: Category?
    var tint: Color = .orange

    @Query(sort: \Category.order) private var categories: [Category]
    @State private var showAll = false

    private var pool: [Category] { categories.filter { $0.isIncome == income && !$0.isSub } }

    private var shown: [Category] {
        var list = Array(pool.prefix(6))
        if let s = selected?.main, !list.contains(where: { $0.id == s.id }) {
            list.insert(s, at: 0)
            if list.count > 6 { list.removeLast() }
        }
        return list
    }

    var body: some View {
        VStack(spacing: 12) {
        FlowLayout(spacing: 10) {
            ForEach(shown) { c in
                Button {
                    withAnimation(.snappy) { selected = (selected?.main.id == c.id) ? nil : c }
                } label: {
                    Chip(title: c.emoji.map { "\($0) \(c.name)" } ?? c.name, symbol: c.emoji == nil ? c.symbol : nil, symbolColor: c.color,
                         selected: selected?.main.id == c.id, tint: c.color)
                }
                .buttonStyle(.plain)
            }
            Button { showAll = true } label: {
                Chip(title: "全部", symbol: "square.grid.2x2")
                    .overlay(Capsule().strokeBorder(Color(.separator), lineWidth: 1.5))
            }
            .buttonStyle(.plain)
        }
        // 子分類
        if let main = selected?.main, !main.sortedChildren.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(main.sortedChildren) { sub in
                        Button {
                            withAnimation(.snappy) { selected = selected?.id == sub.id ? main : sub }
                        } label: {
                            Text(sub.emoji.map { "\($0) \(sub.name)" } ?? sub.name)
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .foregroundStyle(selected?.id == sub.id ? Color.white : Color.primary)
                                .background(selected?.id == sub.id ? main.color : Color(.secondarySystemGroupedBackground), in: .capsule)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 4)
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
        }
        .sheet(isPresented: $showAll) {
            CategoryPickerSheet(income: income, selected: $selected)
                .presentationDetents([.medium, .large])
        }
    }
}

struct CategoryPickerSheet: View {
    var income: Bool
    @Binding var selected: Category?
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Category.order) private var categories: [Category]
    @State private var showManage = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 18) {
                    ForEach(categories.filter { $0.isIncome == income && !$0.isSub }.flatMap { [$0] + $0.sortedChildren }) { c in
                        Button {
                            selected = c
                            dismiss()
                        } label: {
                            VStack(spacing: 6) {
                                c.icon(size: c.isSub ? 44 : 56)
                                    .overlay {
                                        if selected?.id == c.id {
                                            RoundedRectangle(cornerRadius: 17, style: .continuous).strokeBorder(c.color, lineWidth: 2.5)
                                        }
                                    }
                                Text(c.name).font(.footnote).lineLimit(1).foregroundStyle(c.isSub ? .secondary : .primary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .navigationTitle(income ? "收入分類" : "支出分類")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("管理", systemImage: "slider.horizontal.3") { showManage = true }
                }
            }
            .sheet(isPresented: $showManage) { NavigationStack { CategoryManagerView() } }
        }
    }
}

/// 帳戶選擇膠囊
struct AccountMenuChip: View {
    @Binding var account: Account?
    var placeholder: String = "付款卡片"
    @Query(sort: \Account.order) private var accounts: [Account]

    var body: some View {
        Menu {
            ForEach(accounts.filter { !$0.archived }) { a in
                Button {
                    account = a
                } label: {
                    Label(a.name, systemImage: account?.id == a.id ? "checkmark" : a.kind.symbol)
                }
            }
            if account != nil {
                Divider()
                Button("不指定", systemImage: "xmark") { account = nil }
            }
        } label: {
            if let account {
                Chip(title: account.name, symbol: account.kind.symbol, symbolColor: account.color, showsChevron: true)
            } else {
                DashedChip(title: placeholder)
            }
        }
        .buttonStyle(.plain)
    }
}

/// 可展開的備註
struct NoteChip: View {
    @Binding var note: String
    @State private var editing = false

    var body: some View {
        Group {
            if editing || !note.isEmpty {
                TextField("備註", text: $note, axis: .vertical)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
            } else {
                Button { editing = true } label: { DashedChip(title: "備註") }
                    .buttonStyle(.plain)
            }
        }
    }
}
