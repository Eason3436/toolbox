import SwiftUI
import SwiftData

/// 牌組頁只負責管理：哪些牌組在學、每天幾張、順序。開始複習統一在首頁
struct DecksView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Deck.sortIndex) private var decks: [Deck]
    @AppStorage(SettingsKey.dailyNewLimit) private var dailyNewLimit = AppDefaults.dailyNewLimit

    @State private var category: DeckCategory = .word
    /// 點牌組打開的設定面板
    @State private var editing: Deck?
    /// 面板關掉之後要做的事（查看單字、刪除）
    @State private var pendingAction: (DeckSettingsSheet.Action, Deck)?
    @State private var openedDeck: Deck?
    @State private var showOrder = false

    private var filtered: [Deck] { decks.filter { $0.category == category } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.stack) {
                Picker("類型", selection: $category) {
                    ForEach(DeckCategory.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                NewCardAllocationCard(decks: decks, limit: dailyNewLimit)

                HStack(alignment: .firstTextBaseline) {
                    Text("依順序出新卡")
                        .font(.erLabel)
                        .tracking(1.1)
                        .foregroundStyle(Color.er.textTertiary)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    if filtered.count > 1 {
                        Button("編輯順序") { showOrder = true }
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.er.primary)
                            .buttonStyle(.plain)
                    }
                }
                .padding(.top, Theme.Spacing.sectionTop)
                .padding(.horizontal, 2)

                if filtered.isEmpty {
                    EmptyLine("還沒有牌組")
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { offset, deck in
                            if offset > 0 {
                                Divider().overlay(Color.er.outline)
                            }
                            Button {
                                editing = deck
                            } label: {
                                DeckRow(deck: deck)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .erCard(padding: 0, elevated: true)
                }
            }
            .padding(.horizontal, Theme.Spacing.page)
            .padding(.bottom, 24)
            .animation(.spring(duration: 0.3), value: filtered.map(\.id))
        }
        .erPageBackground()
        .navigationTitle("牌組")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: Route.store) {
                    Image(systemName: "bag")
                }
                .accessibilityLabel("單字商店")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("全部學新卡", systemImage: "play") { setMode(.active) }
                    Button("全部只複習", systemImage: "arrow.trianglehead.2.clockwise") { setMode(.reviewOnly) }
                    Button("全部暫停", systemImage: "pause") { setMode(.paused) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("更多")
            }
        }
        .sheet(item: $editing, onDismiss: runPendingAction) { deck in
            DeckSettingsSheet(deck: deck) { action in
                pendingAction = (action, deck)
            }
        }
        .sheet(isPresented: $showOrder) {
            DeckOrderSheet(decks: filtered)
        }
        .navigationDestination(item: $openedDeck) { deck in
            DeckDetailView(deck: deck)
        }
    }

    /// 面板關掉後才動作：刪除時面板不會再讀到已經刪掉的牌組
    private func runPendingAction() {
        guard let pending = pendingAction else { return }
        pendingAction = nil
        let deck = pending.1
        switch pending.0 {
        case .open:
            openedDeck = deck
        case .delete:
            withAnimation(.spring(duration: 0.3)) { context.delete(deck) }
        }
    }

    private func setMode(_ mode: DeckMode) {
        withAnimation(.spring(duration: 0.3)) {
            for deck in filtered {
                deck.setStatus(mode)
            }
        }
    }
}

extension Deck {
    /// 學新卡／只複習／暫停三選一。暫停時記住原本的狀態
    func setStatus(_ status: DeckMode) {
        if status == .paused {
            isPaused = true
        } else {
            mode = status
        }
    }
}

// MARK: - 新卡分配

/// 每日新卡上限、各牌組分到幾張。超過上限只提示，不自動改數字
private struct NewCardAllocationCard: View {
    let decks: [Deck]
    let limit: Int

    var body: some View {
        // 「新卡一次出完」的牌組不佔上限
        let allocated = decks.filter { $0.mode == .active && !$0.newCardsAll }
        let total = allocated.reduce(0) { $0 + $1.dailyNewLimit }
        VStack(alignment: .leading, spacing: 8) {
            Text("新卡分配")
                .font(.subheadline)
                .foregroundStyle(Color.er.textSecondary)
            Text("每日新卡上限 \(limit.formatted()) · 已分配 \(total.formatted())")
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(Color.er.text)
                .contentTransition(.numericText(value: Double(total)))
            if !allocated.isEmpty {
                FlowLayout(spacing: 14) {
                    ForEach(allocated) { deck in
                        Text("\(deck.name)：\(deck.dailyNewLimit.formatted())")
                            .font(.footnote)
                            .monospacedDigit()
                            .foregroundStyle(Color.er.textSecondary)
                    }
                }
            }
            if total > limit {
                Text("已超過每日上限")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.er.danger)
                    .transition(.opacity)
            }
        }
        .erCard(elevated: true)
        .animation(.spring(duration: 0.25), value: total)
    }
}

// MARK: - 牌組列

/// 一列：名稱、已背／總數・每天 N 張、狀態標籤、箭頭，下面一條細進度
private struct DeckRow: View {
    let deck: Deck

    private var isPaused: Bool { deck.mode == .paused }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(deck.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(isPaused ? Color.er.textTertiary : Color.er.text)
                        .lineLimit(1)
                    HStack(spacing: 0) {
                        LearnedCount(deck: deck)
                        if deck.mode == .active {
                            Text(deck.newCardsAll ? " · 新卡一次出完" : " · 每天 \(deck.dailyNewLimit.formatted()) 張")
                        }
                    }
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(isPaused ? Color.er.textTertiary : Color.er.textSecondary)
                }
                Spacer(minLength: 8)
                DeckStatusTag(mode: deck.mode)
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.er.textTertiary)
            }
            LearnedMeter(deck: deck)
                .opacity(isPaused ? 0.5 : 1)
        }
        .padding(.horizontal, Theme.Spacing.cardLarge)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("調整狀態和每天新卡")
    }
}

// 下面兩個要讀牌組裡的每一張卡，拆成自己的 View：
// 調狀態、每天新卡時只重畫列本身，不用把上千張卡再數一遍

private struct LearnedCount: View {
    let deck: Deck

    var body: some View {
        let cards = deck.activeCards
        let learned = cards.filter { !$0.isNew }.count
        Text("\(learned.formatted()) / \(cards.count.formatted())")
    }
}

private struct LearnedMeter: View {
    let deck: Deck

    var body: some View {
        let cards = deck.activeCards
        let learned = cards.filter { !$0.isNew }.count
        LinearMeter(value: cards.isEmpty ? 0 : Double(learned) / Double(cards.count), height: 3)
    }
}

/// 學新卡：強調色淡底；只複習：灰底；暫停：只有外框
struct DeckStatusTag: View {
    let mode: DeckMode

    var body: some View {
        Text(mode.title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(foreground)
            .background {
                switch mode {
                case .active:
                    Capsule().fill(Color.er.primary.opacity(0.12))
                case .reviewOnly:
                    Capsule().fill(Color.er.fill)
                case .paused:
                    Capsule().strokeBorder(Color.er.outlineStrong, lineWidth: 1)
                }
            }
            .fixedSize()
    }

    private var foreground: Color {
        switch mode {
        case .active: Color.er.primary
        case .reviewOnly: Color.er.textSecondary
        case .paused: Color.er.textTertiary
        }
    }
}

// MARK: - 牌組設定面板

/// 點牌組從底部滑出：狀態三選一、每天新卡（只有學新卡時）、查看單字、刪除
struct DeckSettingsSheet: View {
    enum Action {
        case open
        case delete
    }

    @Bindable var deck: Deck
    let onAction: (Action) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    private var status: Binding<DeckMode> {
        Binding {
            deck.mode
        } set: { value in
            withAnimation(.spring(duration: 0.25)) { deck.setStatus(value) }
        }
    }

    private var statusNote: String {
        switch deck.mode {
        case .active: "每天出新卡，也出到期的複習"
        case .reviewOnly: "不出新卡，只出到期的複習"
        case .paused: "這個牌組先不出任何卡"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("狀態", selection: status) {
                        ForEach(DeckMode.statusOrder) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                } footer: {
                    Text(statusNote)
                }
                .listRowBackground(Color.er.surface)

                if deck.mode == .active {
                    Section {
                        if deck.kind == .custom {
                            Toggle("新卡一次出完", isOn: $deck.newCardsAll)
                        }
                        if !deck.newCardsAll {
                            LabeledContent("每天新卡") {
                                RollingCounter(value: $deck.dailyNewLimit, in: 0...100)
                                    .accessibilityLabel("每天新卡")
                            }
                        }
                    }
                    .listRowBackground(Color.er.surface)
                    .transition(.opacity)
                }

                Section {
                    Button {
                        onAction(.open)
                        dismiss()
                    } label: {
                        Label("查看單字", systemImage: "list.bullet")
                    }
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("刪除牌組", systemImage: "trash")
                    }
                }
                .listRowBackground(Color.er.surface)
            }
            .scrollContentBackground(.hidden)
            .erPageBackground()
            .navigationTitle(deck.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .confirmationDialog("刪除「\(deck.name)」？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("刪除牌組與進度", role: .destructive) {
                    onAction(.delete)
                    dismiss()
                }
            } message: {
                Text("這個牌組的卡片和複習進度都會刪掉")
            }
        }
        .presentationDetents([.medium, .large])
        .sensoryFeedback(.selection, trigger: deck.mode)
        .sensoryFeedback(.selection, trigger: deck.newCardsAll)
    }
}

// MARK: - 編輯順序

/// 拖曳排序；順序就是領新卡的順序
private struct DeckOrderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var order: [Deck]

    init(decks: [Deck]) {
        _order = State(initialValue: decks)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(order) { deck in
                        HStack {
                            Text(deck.name)
                                .foregroundStyle(Color.er.text)
                            Spacer(minLength: 8)
                            DeckStatusTag(mode: deck.mode)
                        }
                    }
                    .onMove(perform: move)
                } footer: {
                    Text("新卡依這個順序出：前面的牌組先領")
                }
                .listRowBackground(Color.er.surface)
            }
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .erPageBackground()
            .navigationTitle("編輯順序")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        let slots = order.map(\.sortIndex).sorted()
        order.move(fromOffsets: source, toOffset: destination)
        for (deck, slot) in zip(order, slots) {
            deck.sortIndex = slot
        }
    }
}

#Preview("淺色") {
    NavigationStack {
        DecksView().appDestinations()
    }
    .previewEnvironment()
}

#Preview("深色") {
    NavigationStack {
        DecksView().appDestinations()
    }
    .previewEnvironment()
    .preferredColorScheme(.dark)
}

#Preview("設定面板") {
    let container = PreviewData.container
    let deck = (try? container.mainContext.fetch(FetchDescriptor<Deck>()))?.first
    Color.clear
        .sheet(isPresented: .constant(true)) {
            if let deck {
                DeckSettingsSheet(deck: deck) { _ in }
            }
        }
        .previewEnvironment()
}

#Preview("設定面板 · 深色") {
    let container = PreviewData.container
    let deck = (try? container.mainContext.fetch(FetchDescriptor<Deck>()))?.first
    Color.clear
        .sheet(isPresented: .constant(true)) {
            if let deck {
                DeckSettingsSheet(deck: deck) { _ in }
            }
        }
        .previewEnvironment()
        .preferredColorScheme(.dark)
}
