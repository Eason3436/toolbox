import SwiftUI
import SwiftData

struct DecksView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Deck.sortIndex) private var decks: [Deck]
    @Query private var logs: [ReviewLog]
    @AppStorage(SettingsKey.dailyNewLimit) private var dailyNewLimit = AppDefaults.dailyNewLimit

    @State private var category: DeckCategory = .word
    @State private var session: ReviewSession?
    @State private var showLimitSheet = false
    @State private var pendingDelete: Deck?
    @State private var studyCache = StudySummaryCache()

    private var filtered: [Deck] { decks.filter { $0.category == category } }

    var body: some View {
        let summary = studyCache.summary(decks: decks, logs: logs, globalNewLimit: dailyNewLimit)
        let counts = summary.counts(for: category)
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.stack) {
                Picker("類型", selection: $category) {
                    ForEach(DeckCategory.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                NewCardQuotaCard(summary: summary) {
                    showLimitSheet = true
                }

                SectionHeader(title: "每天出新卡 · \(filtered.filter { $0.mode == .active }.count)", trailing: "依這個順序領新卡")

                if filtered.isEmpty {
                    EmptyLine("還沒有牌組")
                } else {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { offset, deck in
                        DeckCardView(deck: deck, position: offset + 1)
                            .contextMenu {
                                Button("往上移", systemImage: "arrow.up") { move(deck, by: -1) }
                                    .disabled(offset == 0)
                                Button("往下移", systemImage: "arrow.down") { move(deck, by: 1) }
                                    .disabled(offset == filtered.count - 1)
                                Divider()
                                Button("刪除牌組", systemImage: "trash", role: .destructive) {
                                    pendingDelete = deck
                                }
                            }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.page)
            .padding(.bottom, 24)
            .animation(.spring(duration: 0.3), value: filtered.map(\.id))
        }
        .erPageBackground()
        .navigationTitle("牌組")
        .safeAreaInset(edge: .bottom) {
            if counts.total > 0 {
                ReviewBar(count: counts.total) {
                    session = ReviewSession(category: category)
                }
                .padding(.horizontal, Theme.Spacing.page)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: Route.store) {
                    Image(systemName: "bag")
                }
                .accessibilityLabel("單字商店")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("全部出新卡", systemImage: "play") { setMode(.active) }
                    Button("全部只出複習", systemImage: "arrow.trianglehead.2.clockwise") { setMode(.reviewOnly) }
                    Button("全部暫停", systemImage: "pause") { setMode(.paused) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("更多")
            }
        }
        .sheet(isPresented: $showLimitSheet) {
            NewCardLimitSheet()
        }
        .fullScreenCover(item: $session) { session in
            ReviewView(session: session)
        }
        .confirmationDialog(
            "刪除「\(pendingDelete?.name ?? "")」？",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("刪除牌組與進度", role: .destructive) {
                if let deck = pendingDelete {
                    withAnimation(.spring(duration: 0.3)) { context.delete(deck) }
                }
                pendingDelete = nil
            }
        } message: {
            Text("這個牌組的卡片和複習進度都會刪掉")
        }
    }

    /// 在同一類（記憶卡／片語卡）裡上下移動，順序就是領新卡的順序
    private func move(_ deck: Deck, by step: Int) {
        var list = filtered
        guard let from = list.firstIndex(of: deck) else { return }
        let to = from + step
        guard list.indices.contains(to) else { return }
        list.swapAt(from, to)
        let slots = list.map(\.sortIndex).sorted()
        withAnimation(.spring(duration: 0.3)) {
            for (deck, slot) in zip(list, slots) {
                deck.sortIndex = slot
            }
        }
    }

    private func setMode(_ mode: DeckMode) {
        withAnimation(.spring(duration: 0.3)) {
            for deck in filtered {
                if mode == .paused { deck.isPaused = true } else { deck.mode = mode }
            }
        }
    }
}

// MARK: - 今日新卡

private struct NewCardQuotaCard: View {
    let summary: StudySummary
    let adjust: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("今日新卡")
                    .font(.subheadline)
                    .foregroundStyle(Color.er.textSecondary)
                Text("\(summary.newDoneToday) / \(summary.newLimit)")
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(Color.er.text)
                Spacer()
                Chip(text: "到期 \(summary.all.due)")
            }
            LinearMeter(value: summary.newLimit > 0 ? Double(summary.newDoneToday) / Double(summary.newLimit) : 0)
            Button("調整上限與順序", action: adjust)
                .font(.footnote.weight(.semibold))
                .buttonStyle(.borderless)
        }
        .erCard(elevated: true)
    }
}

/// 分頁列上方的浮動玻璃列
private struct ReviewBar: View {
    let count: Int
    let start: () -> Void

    var body: some View {
        HStack {
            Text("\(count) 張待複習")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Color.er.text)
            Spacer()
            Button(action: start) {
                Text("開始")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.er.onPrimary)
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.glassProminent)
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
    }
}

// MARK: - 每日新卡上限

struct NewCardLimitSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.dailyNewLimit) private var dailyNewLimit = AppDefaults.dailyNewLimit

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $dailyNewLimit, in: 0...200, step: 5) {
                        LabeledContent("每日新卡上限") {
                            Text(dailyNewLimit, format: .number).monospacedDigit()
                        }
                    }
                } footer: {
                    Text("全部牌組合計，「新卡一次出完」的牌組不算在內。各牌組自己的上限在牌組卡片上調，順序長按牌組調整")
                }
            }
            .scrollContentBackground(.hidden)
            .erPageBackground()
            .navigationTitle("新卡")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
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
