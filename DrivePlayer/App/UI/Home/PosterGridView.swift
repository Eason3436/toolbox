import SwiftData
import SwiftUI

/// 電影或劇集的海報牆
struct PosterGridView: View {
    enum Kind { case movies, shows }
    let kind: Kind

    @Query(sort: \MediaItem.title) private var items: [MediaItem]
    @Query(sort: \Show.title) private var shows: [Show]
    @Query private var states: [PlaybackState]
    @State private var sort: Sort = .title
    @State private var filter: Filter = .all

    enum Sort: String, CaseIterable, Identifiable {
        case title = "片名"
        case added = "加入時間"
        case year = "年份"
        case rating = "評分"
        var id: Self { self }
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all = "全部"
        case favorites = "收藏"
        case watchlist = "待看"
        case unwatched = "未看"
        var id: Self { self }
    }

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 12, alignment: .top)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 18) {
                switch kind {
                case .movies:
                    ForEach(movieList) { m in
                        NavigationLink(value: Route.movie(m.fileId)) {
                            PosterCard(url: m.posterURL, title: m.title, subtitle: m.year.map(String.init), watched: watchedIds.contains(m.fileId), rating: m.rating)
                        }
                        .buttonStyle(.plain)
                    }
                case .shows:
                    ForEach(showList) { s in
                        NavigationLink(value: Route.show(s.key)) {
                            PosterCard(url: s.posterURL, title: s.title, subtitle: "\(s.episodes.count) 集",
                                       watched: !s.episodes.isEmpty && s.episodes.allSatisfy { watchedIds.contains($0.fileId) }, rating: s.rating)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding()
        }
        .overlay {
            if (kind == .movies ? movieList.isEmpty : showList.isEmpty) {
                ContentUnavailableView(filter == .all ? "沒有內容" : "沒有符合的項目", systemImage: kind == .movies ? "film" : "tv")
            }
        }
        .softScrollEdges()
        .navigationTitle(kind == .movies ? "電影" : "劇集")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("篩選", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("排序", selection: $sort) {
                        ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("排序與篩選")
            }
        }
    }

    private var watchedIds: Set<String> {
        Set(states.filter(\.watched).map(\.fileId))
    }

    private var movieList: [MediaItem] {
        let watched = watchedIds
        var list = items.filter { $0.kind == .movie && $0.matchState.isInLibrary }
        switch filter {
        case .all: break
        case .favorites: list = list.filter(\.isFavorite)
        case .watchlist: list = list.filter(\.isWatchlisted)
        case .unwatched: list = list.filter { !watched.contains($0.fileId) }
        }
        switch sort {
        case .title: list.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .added: list.sort { $0.addedAt > $1.addedAt }
        case .year: list.sort { ($0.year ?? 0) > ($1.year ?? 0) }
        case .rating: list.sort { ($0.rating ?? 0) > ($1.rating ?? 0) }
        }
        return list
    }

    private var showList: [Show] {
        let watched = watchedIds
        var list = shows.filter { $0.matchState.isInLibrary }
        switch filter {
        case .all: break
        case .favorites: list = list.filter(\.isFavorite)
        case .watchlist: list = list.filter(\.isWatchlisted)
        case .unwatched: list = list.filter { $0.episodes.contains { !watched.contains($0.fileId) } }
        }
        switch sort {
        case .title: list.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .added: list.sort { $0.addedAt > $1.addedAt }
        case .year: list.sort { ($0.year ?? 0) > ($1.year ?? 0) }
        case .rating: list.sort { ($0.rating ?? 0) > ($1.rating ?? 0) }
        }
        return list
    }
}
