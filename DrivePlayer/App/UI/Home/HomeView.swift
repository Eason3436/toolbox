import Core
import SwiftData
import SwiftUI

enum Route: Hashable {
    case movie(String)      // fileId
    case show(String)       // Show.key
    case allMovies
    case allShows
    case unmatched
    case allFiles
    case categories(CategoryKind)
    case category(CategoryKind, String)
    case others
}

/// 首頁：推薦輪播、繼續觀看、最近加入、電影、劇集、分類、其他影片、未辨識
struct HomeView: View {
    @Environment(AppServices.self) private var services
    @Query(sort: \MediaItem.addedAt, order: .reverse) private var items: [MediaItem]
    @Query(sort: \Show.addedAt, order: .reverse) private var shows: [Show]
    @Query(sort: \PlaybackState.lastPlayed, order: .reverse) private var states: [PlaybackState]
    @State private var scroll = HeroScroll()
    @State private var carouselTint = CarouselTint()

    private var unmatchedCount: Int {
        items.filter { $0.kind == .movie && $0.matchState == .unmatched }.count + shows.filter { $0.matchState == .unmatched }.count
    }

    /// 繼續觀看：有進度、還沒看完
    private var continueWatching: [(MediaItem, PlaybackState)] {
        let byId = Dictionary(items.map { ($0.fileId, $0) }, uniquingKeysWith: { a, _ in a })
        var seenShows: Set<String> = []
        var out: [(MediaItem, PlaybackState)] = []
        for s in states where s.resumePosition != nil {
            guard let item = byId[s.fileId] else { continue }
            // 同一部劇只放最近看的那一集
            if let key = item.show?.key, !seenShows.insert(key).inserted { continue }
            out.append((item, s))
            if out.count >= 12 { break }
        }
        return out
    }

    var body: some View {
        let library = LibraryEntry.library(items: items, shows: shows)
        let featured = FeaturedPicker.pick(from: library)
        let others = LibraryEntry.others(items: items, shows: shows)
        let movies = library.filter { $0.id.hasPrefix("m-") }
        let showEntries = library.filter { $0.id.hasPrefix("s-") }
        let byTitle: (LibraryEntry, LibraryEntry) -> Bool = { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if !featured.isEmpty {
                    FeaturedCarousel(entries: featured, tint: carouselTint)
                }
                if services.matcher.isRunning {
                    matchingBanner
                }
                if !continueWatching.isEmpty {
                    section("繼續觀看") {
                        ForEach(continueWatching, id: \.0.fileId) { item, state in
                            Button { services.play(item) } label: {
                                BackdropCard(
                                    url: item.kind == .episode ? item.stillURL : item.backdropURL,
                                    title: item.kind == .episode ? (item.show?.title ?? item.title) : item.title,
                                    subtitle: continueSubtitle(item, state),
                                    progress: state.progress
                                )
                                .frame(width: 260)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button { services.play(item, fromBeginning: true) } label: { Label("從頭播放", systemImage: "backward.end") }
                                Button { services.playback.setWatched([item.fileId], watched: true) } label: { Label("標記為已看", systemImage: "checkmark.circle") }
                            }
                        }
                    }
                }
                if !library.isEmpty {
                    section("最近加入") {
                        posterRow(library.sorted { $0.addedAt > $1.addedAt }.prefix(20))
                    }
                }
                if !movies.isEmpty {
                    section("電影", count: movies.count, all: .allMovies) {
                        posterRow(movies.sorted(by: byTitle).prefix(20))
                    }
                }
                if !showEntries.isEmpty {
                    section("劇集", count: showEntries.count, all: .allShows) {
                        posterRow(showEntries.sorted(by: byTitle).prefix(20))
                    }
                }
                ForEach(CategoryKind.allCases, id: \.self) { kind in
                    let groups = CategoryGroup.groups(kind, in: library)
                    if !groups.isEmpty {
                        section(kind.title, count: groups.count, all: .categories(kind)) {
                            ForEach(groups.prefix(12)) { group in
                                NavigationLink(value: Route.category(kind, group.value)) {
                                    CategoryCard(group: group)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                if !others.isEmpty {
                    section("其他影片", count: others.count, all: .others) {
                        ForEach(others.prefix(20)) { entry in
                            NavigationLink(value: entry.route) {
                                PlainVideoCard(entry: entry).frame(width: 200)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if unmatchedCount > 0 {
                    NavigationLink(value: Route.unmatched) {
                        HStack {
                            Label("未辨識", systemImage: "questionmark.folder.fill")
                            Spacer()
                            Text("\(unmatchedCount)").foregroundStyle(.secondary)
                            Image(systemName: "chevron.forward").foregroundStyle(.tertiary)
                        }
                        .padding()
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal)
                }
            }
            .padding(.top, featured.isEmpty ? 16 : 0)
            .padding(.bottom)
        }
        .trackHeroScroll($scroll)
        .background {
            if !featured.isEmpty {
                CarouselBackground(tint: carouselTint, ids: featured.map(\.id))
            }
        }
        .task(id: featured.map(\.id)) {
            // 每一頁海報的主色（下半部，跟首頁底色接起來）
            for entry in featured where carouselTint.colors[entry.id] == nil {
                if let color = await PosterTint.color(for: entry.hero.url) {
                    carouselTint.colors[entry.id] = color
                }
            }
        }
        .overlay {
            if items.isEmpty && services.library.isScanning {
                HomeSkeleton()
            } else if items.isEmpty {
                ContentUnavailableView {
                    Label("尚未加入媒體庫", systemImage: "film.stack")
                } description: {
                    Text(services.auth.state == .signedIn
                         ? "到「媒體庫」加入放電影或劇集的 Google 雲端硬碟資料夾"
                         : "先到「設定」登入 Google，再到「媒體庫」選擇資料夾")
                }
            }
        }
        .ignoresSafeArea(edges: featured.isEmpty ? [] : .top)
        .softScrollEdges()
        .heroTopEdge(scrolled: scroll.scrolled || featured.isEmpty)
        .navigationTitle("DrivePlayer")
        .navigationBarTitleDisplayMode(featured.isEmpty ? .automatic : .inline)
        .toolbar {
            if !featured.isEmpty {
                // 有輪播時不顯示標題，海報直接到頂
                ToolbarItem(placement: .principal) {
                    Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                NavigationLink(value: Route.allFiles) {
                    Image(systemName: "list.bullet")
                }
                .accessibilityLabel("全部影片")
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .refreshable {
            services.library.scanAll()
        }
        .homeDestinations()
    }

    private func posterRow(_ entries: ArraySlice<LibraryEntry>) -> some View {
        ForEach(entries) { entry in
            NavigationLink(value: entry.route) {
                PosterCard(url: entry.posterURL, title: entry.title, subtitle: entry.subtitle, rating: entry.rating)
                    .frame(width: 140)
            }
            .buttonStyle(.plain)
        }
    }

    private var matchingBanner: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("正在從 TMDB 取得資料（\(services.matcher.done)／\(services.matcher.total)）")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    private func continueSubtitle(_ item: MediaItem, _ state: PlaybackState) -> String {
        let remaining = max(0, state.duration - state.position)
        let left = "剩 \(Timecode.duration(remaining))"
        if let label = item.episodeLabel { return "\(label)・\(left)" }
        return left
    }

    private func section<Content: View>(
        _ title: String, count: Int? = nil, all: Route? = nil, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title) {
                if let all, let count {
                    NavigationLink(value: all) {
                        HStack(spacing: 3) {
                            Text("全部 · \(count)")
                            Image(systemName: "chevron.forward").imageScale(.small)
                        }
                        .font(.subheadline)
                    }
                    .accessibilityLabel("全部 \(count) 個")
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    content()
                }
                .padding(.horizontal)
            }
        }
    }
}

extension View {
    /// 首頁堆疊的所有目的地
    func homeDestinations() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .movie(let id): MovieDetailLoader(fileId: id)
            case .show(let key): ShowDetailLoader(key: key)
            case .allMovies: PosterGridView(kind: .movies)
            case .allShows: PosterGridView(kind: .shows)
            case .unmatched: UnmatchedView()
            case .allFiles: LibraryListView()
            case .categories(let kind): CategoryListView(kind: kind)
            case .category(let kind, let value): CategoryItemsView(kind: kind, value: value)
            case .others: OthersView()
            }
        }
    }
}

/// 第一次掃描時的骨架畫面
private struct HomeSkeleton: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ForEach(0..<3, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 10) {
                        Text("最近加入").font(.title3.weight(.bold)).padding(.horizontal)
                        HStack(spacing: 12) {
                            ForEach(0..<4, id: \.self) { _ in
                                PosterCard(url: nil, title: "片名佔位", subtitle: "2025")
                                    .frame(width: 140)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
            .padding(.vertical)
        }
        .scrollDisabled(true)
        .redacted(reason: .placeholder)
        .allowsHitTesting(false)
        .accessibilityLabel("正在掃描媒體庫")
    }
}
