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
}

/// 首頁：繼續觀看、最近加入、電影、劇集、未辨識
struct HomeView: View {
    @Environment(AppServices.self) private var services
    @Query(sort: \MediaItem.addedAt, order: .reverse) private var items: [MediaItem]
    @Query(sort: \Show.addedAt, order: .reverse) private var shows: [Show]
    @Query(sort: \PlaybackState.lastPlayed, order: .reverse) private var states: [PlaybackState]

    private var movies: [MediaItem] { items.filter { $0.kind == .movie && $0.matchState != .unmatched } }
    private var matchedShows: [Show] { shows.filter { $0.matchState != .unmatched } }
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

    /// 最近加入：電影與劇（劇用最新一集的加入時間）
    private var recentlyAdded: [RecentEntry] {
        var entries: [RecentEntry] = movies.prefix(20).map { .movie($0) }
        entries += matchedShows.map { show in .show(show, show.episodes.map(\.addedAt).max() ?? show.addedAt) }
        return Array(entries.sorted { $0.date > $1.date }.prefix(20))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
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
                if !recentlyAdded.isEmpty {
                    section("最近加入") {
                        ForEach(recentlyAdded) { entry in
                            NavigationLink(value: entry.route) {
                                PosterCard(url: entry.posterURL, title: entry.title, subtitle: entry.subtitle)
                                    .frame(width: 120)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !movies.isEmpty {
                    section("電影", count: movies.count, all: .allMovies) {
                        ForEach(movies.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }.prefix(20)) { m in
                            NavigationLink(value: Route.movie(m.fileId)) {
                                PosterCard(url: m.posterURL, title: m.title, subtitle: m.year.map(String.init))
                                    .frame(width: 120)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !matchedShows.isEmpty {
                    section("劇集", count: matchedShows.count, all: .allShows) {
                        ForEach(matchedShows.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }.prefix(20)) { s in
                            NavigationLink(value: Route.show(s.key)) {
                                PosterCard(url: s.posterURL, title: s.title, subtitle: "\(s.episodes.count) 集")
                                    .frame(width: 120)
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
            .padding(.vertical)
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
        .navigationTitle("DrivePlayer")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink(value: Route.allFiles) {
                    Image(systemName: "list.bullet")
                }
                .accessibilityLabel("全部影片")
            }
        }
        .refreshable {
            services.library.scanAll()
        }
        .homeDestinations()
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
                        Text("全部 \(count)").font(.subheadline)
                    }
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

private enum RecentEntry: Identifiable {
    case movie(MediaItem)
    case show(Show, Date)

    var id: String {
        switch self {
        case .movie(let m): "m-" + m.fileId
        case .show(let s, _): "s-" + s.key
        }
    }

    var date: Date {
        switch self {
        case .movie(let m): m.addedAt
        case .show(_, let d): d
        }
    }

    var route: Route {
        switch self {
        case .movie(let m): .movie(m.fileId)
        case .show(let s, _): .show(s.key)
        }
    }

    var posterURL: URL? {
        switch self {
        case .movie(let m): m.posterURL
        case .show(let s, _): s.posterURL
        }
    }

    var title: String {
        switch self {
        case .movie(let m): m.title
        case .show(let s, _): s.title
        }
    }

    var subtitle: String? {
        switch self {
        case .movie(let m): m.year.map(String.init)
        case .show(let s, _): "\(s.episodes.count) 集"
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
                                    .frame(width: 120)
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
