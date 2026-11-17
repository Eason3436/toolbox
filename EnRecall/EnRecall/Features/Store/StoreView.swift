import SwiftUI
import SwiftData

struct StoreView: View {
    enum StoreTab: String, CaseIterable, Identifiable {
        case featured
        case words
        case phrases

        var id: String { rawValue }

        var title: String {
            switch self {
            case .featured: "為你推薦"
            case .words: "單字"
            case .phrases: "片語"
            }
        }
    }

    @Environment(StoreModel.self) private var store
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.modelContext) private var context
    @Query(sort: \Deck.sortIndex) private var decks: [Deck]

    @State private var section: StoreTab = .featured
    @State private var query = ""
    @State private var openDeck: Deck?

    private var searchResults: [StorePack] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return store.packs.filter {
            $0.title.lowercased().contains(q) || ($0.subtitle ?? "").lowercased().contains(q)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.stack) {
                switch store.phase {
                case .idle, .loading where store.packs.isEmpty:
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)
                case .needsPassword:
                    VStack(spacing: 12) {
                        EmptyLine("輸入下載密碼才能下載單字包")
                        StorePasswordField()
                            .erCard()
                    }
                    .frame(maxWidth: .infinity)
                case .failed:
                    VStack(spacing: 12) {
                        EmptyLine("無法連上單字商店")
                        Button("重試") { Task { await store.load(force: true) } }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                    }
                    .frame(maxWidth: .infinity)
                default:
                    if query.isEmpty {
                        content
                    } else {
                        results
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.page)
            .padding(.bottom, 24)
        }
        .erPageBackground()
        .navigationTitle("單字商店")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "搜尋單字包")
        .refreshable { await store.load(force: true) }
        .task { await store.load() }
        .navigationDestination(item: $openDeck) { deck in
            DeckDetailView(deck: deck)
        }
    }

    @ViewBuilder
    private var content: some View {
        Picker("分類", selection: $section) {
            ForEach(StoreTab.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        let updates = store.updatesAvailable(decks: decks)
        if !updates.isEmpty {
            UpdateBanner(packs: updates) { download(updates) }
        }

        switch section {
        case .featured:
            featured
        case .words:
            packList(store.wordPacks)
        case .phrases:
            packList(store.phrasePacks)
        }
    }

    @ViewBuilder
    private var featured: some View {
        let words = store.wordPacks
        if !words.isEmpty {
            OfficialHeroCard(packs: words, decks: decks) { missing in download(missing) }
        }

        SectionHeader(title: "學測單字")
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(words) { pack in
                    NavigationLink(value: Route.pack(pack)) {
                        PackCard(pack: pack, status: store.status(of: pack, decks: decks)) { primaryAction(pack) }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.Spacing.page)
        }
        .scrollIndicators(.hidden)
        .padding(.horizontal, -Theme.Spacing.page)

        if !store.phrasePacks.isEmpty {
            SectionHeader(title: "片語")
            packRows(store.phrasePacks)
        }
    }

    @ViewBuilder
    private var results: some View {
        let found = searchResults
        if found.isEmpty {
            EmptyLine("沒有符合的單字包")
        } else {
            SectionHeader(title: "\(found.count) 個結果")
            packRows(found)
        }
    }

    @ViewBuilder
    private func packList(_ packs: [StorePack]) -> some View {
        if packs.isEmpty {
            EmptyLine("還沒有單字包")
        } else {
            SectionHeader(title: "\(packs.count) 包")
            packRows(packs)
        }
    }

    private func packRows(_ packs: [StorePack]) -> some View {
        VStack(spacing: 0) {
            ForEach(packs) { pack in
                NavigationLink(value: Route.pack(pack)) {
                    PackRow(pack: pack, status: store.status(of: pack, decks: decks)) { primaryAction(pack) }
                        .padding(Theme.Spacing.row)
                }
                .buttonStyle(.plain)
                if pack.id != packs.last?.id {
                    Divider().overlay(Color.er.outline).padding(.leading, 72)
                }
            }
        }
        .erCard(padding: 0, elevated: true)
    }

    private func primaryAction(_ pack: StorePack) {
        switch store.status(of: pack, decks: decks) {
        case .downloaded:
            openDeck = decks.first { $0.id == pack.id }
        case .downloading:
            break
        case .notDownloaded, .updateAvailable:
            download([pack])
        }
    }

    private func download(_ packs: [StorePack]) {
        Task {
            guard let message = await store.installAll(packs, context: context) else { return }
            toasts.show(message, systemImage: message.contains("失敗") ? "exclamationmark.triangle" : "checkmark")
        }
    }
}

// MARK: - 有新版

private struct UpdateBanner: View {
    let packs: [StorePack]
    let updateAll: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.row) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title2)
                .foregroundStyle(Color.er.info)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(packs.count) 包有新版")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.er.text)
                Text(packs.map(\.title).joined(separator: "、"))
                    .font(.caption)
                    .foregroundStyle(Color.er.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("全部更新", action: updateAll)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
        }
        .padding(Theme.Spacing.card)
        .background(Color.er.infoContainer, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

// MARK: - 官方精選

private struct OfficialHeroCard: View {
    let packs: [StorePack]
    let decks: [Deck]
    let getMissing: ([StorePack]) -> Void

    var body: some View {
        let installed = Set(decks.map(\.id))
        let missing = packs.filter { !installed.contains($0.id) }
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: 14) {
            Text("官方精選")
                .font(.erLabel)
                .tracking(1.1)
                .foregroundStyle(Color.er.heroTextSecondary)
            Text("學測 \(packs.count) 級全套")
                .font(.title2.weight(.bold))
                .foregroundStyle(Color.er.heroText)

            HStack(spacing: 8) {
                ForEach(packs) { pack in
                    let has = installed.contains(pack.id)
                    ZStack {
                        Circle()
                            .stroke(has ? Color.er.heroText : Color.er.heroTile, lineWidth: 3)
                        Text(pack.tileLabel)
                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                            .foregroundStyle(has ? Color.er.heroText : Color.er.heroMuted)
                    }
                    .frame(maxWidth: 44)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .accessibilityElement()
                    .accessibilityLabel(pack.title)
                    .accessibilityValue(has ? "已下載" : "未下載")
                }
            }

            HStack {
                Text("已下載 \(packs.count - missing.count) / \(packs.count)")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(Color.er.heroTextSecondary)
                Spacer()
                if !missing.isEmpty {
                    Button {
                        getMissing(missing)
                    } label: {
                        Text("取得其餘 \(missing.count) 包")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.er.hero)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .tint(Color.er.heroText)
                }
            }
        }
        .padding(Theme.Spacing.cardLarge)
        .background(Color.er.hero, in: shape)
        .overlay(shape.strokeBorder(Color.er.heroOutline, lineWidth: 1))
    }
}

#Preview("淺色") {
    NavigationStack {
        StoreView().appDestinations()
    }
    .previewEnvironment()
}

#Preview("深色") {
    NavigationStack {
        StoreView().appDestinations()
    }
    .previewEnvironment()
    .preferredColorScheme(.dark)
}
