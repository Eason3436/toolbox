import Core
import SwiftData
import SwiftUI

struct ShowDetailLoader: View {
    @Query private var shows: [Show]

    init(key: String) {
        _shows = Query(filter: #Predicate<Show> { $0.key == key })
    }

    var body: some View {
        if let show = shows.first {
            ShowDetailView(show: show)
        } else {
            ContentUnavailableView("找不到這部劇", systemImage: "tv")
        }
    }
}

/// 劇集詳細頁：季別切換 + 集數列表
struct ShowDetailView: View {
    @Environment(AppServices.self) private var services
    @AppStorage(AppServices.Keys.askBeforeResume) private var askBeforeResume = false
    @Bindable var show: Show
    @Query private var states: [PlaybackState]
    @State private var season: Int?
    @State private var matching = false
    @State private var resumeCandidate: MediaItem?

    init(show: Show) {
        self.show = show
    }

    private var stateById: [String: PlaybackState] {
        Dictionary(states.map { ($0.fileId, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private var selectedSeason: Int { season ?? nextUp?.season ?? show.seasonNumbers.first ?? 1 }
    private var allWatched: Bool {
        let s = stateById
        return !show.episodes.isEmpty && show.episodes.allSatisfy { s[$0.fileId]?.watched == true }
    }

    /// 下一集：最近看到一半的，否則第一個還沒看的
    private var nextUp: MediaItem? {
        let s = stateById
        let ordered = show.orderedEpisodes
        if let inProgress = ordered
            .filter({ s[$0.fileId]?.resumePosition != nil })
            .max(by: { (s[$0.fileId]?.lastPlayed ?? .distantPast) < (s[$1.fileId]?.lastPlayed ?? .distantPast) }) {
            return inProgress
        }
        // 最後看完的那一集的下一集
        if let lastWatched = ordered.lastIndex(where: { s[$0.fileId]?.watched == true }), lastWatched + 1 < ordered.count {
            return ordered[lastWatched + 1]
        }
        return ordered.first { s[$0.fileId]?.watched != true } ?? ordered.first
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                DetailHeader(
                    backdrop: show.backdropURL, poster: show.posterURL, title: show.title,
                    info: info, badges: badges, genres: show.genres
                )

                VStack(spacing: 18) {
                    if let next = nextUp {
                        let st = stateById[next.fileId]
                        VStack(spacing: 6) {
                            PlayButton(resumeAt: st?.resumePosition, progress: st?.progress ?? 0) { play(next) }
                            Text(next.episodeLabel.map { "\($0)・\(next.episodeTitle ?? next.fileName)" } ?? next.fileName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    HStack(spacing: 0) {
                        CircleActionButton(systemImage: allWatched ? "checkmark.circle.fill" : "checkmark.circle", label: allWatched ? "已看" : "未看", isOn: allWatched) {
                            services.playback.setWatched(show.episodes.map(\.fileId), watched: !allWatched)
                        }
                        .frame(maxWidth: .infinity)
                        CircleActionButton(systemImage: show.isFavorite ? "heart.fill" : "heart", label: "收藏", isOn: show.isFavorite) {
                            show.isFavorite.toggle()
                        }
                        .frame(maxWidth: .infinity)
                        CircleActionButton(systemImage: show.isWatchlisted ? "bookmark.fill" : "bookmark", label: "待看", isOn: show.isWatchlisted) {
                            show.isWatchlisted.toggle()
                        }
                        .frame(maxWidth: .infinity)
                        CircleActionButton(systemImage: "backward.end.fill", label: "從頭播放") {
                            if let first = show.orderedEpisodes.first { services.play(first, fromBeginning: true) }
                        }
                        .frame(maxWidth: .infinity)
                    }

                    if let overview = show.overview, !overview.isEmpty {
                        ExpandableText(text: overview)
                    }
                    if let rating = show.rating, rating > 0 {
                        RatingView(rating: rating)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal)

                seasonPicker
                episodeList

                if !show.cast.isEmpty {
                    CastRow(cast: show.cast)
                        .padding(.bottom, 30)
                }
            }
        }
        .detailPageStyle()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { matching = true } label: { Label("手動指定 TMDB", systemImage: "magnifyingglass") }
                    if let any = show.episodes.first {
                        Button { services.matcher.rematch(any) } label: { Label("重新自動比對", systemImage: "arrow.triangle.2.circlepath") }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("更多")
            }
        }
        .sheet(isPresented: $matching) {
            ManualMatchView(target: .show(show))
        }
        .confirmationDialog("要從哪裡開始？", isPresented: Binding(get: { resumeCandidate != nil }, set: { if !$0 { resumeCandidate = nil } }), titleVisibility: .visible) {
            if let item = resumeCandidate, let t = stateById[item.fileId]?.resumePosition {
                Button("從 \(Timecode.string(t)) 繼續") { services.play(item) }
                Button("從頭播放") { services.play(item, fromBeginning: true) }
            }
        }
    }

    // MARK: - 季與集

    @ViewBuilder
    private var seasonPicker: some View {
        let seasons = show.seasonNumbers
        if seasons.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(seasons, id: \.self) { n in
                        Button {
                            withAnimation(.snappy) { season = n }
                        } label: {
                            Text(n == 0 ? "特別篇" : "第 \(n) 季")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(n == selectedSeason ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.12)), in: Capsule())
                                .foregroundStyle(n == selectedSeason ? .black : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
            .sensoryFeedback(.selection, trigger: season)
        } else if let only = seasons.first {
            Text(only == 0 ? "特別篇" : "第 \(only) 季")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
        }
    }

    private var episodeList: some View {
        let s = stateById
        return LazyVStack(spacing: 16) {
            ForEach(show.episodes(inSeason: selectedSeason)) { ep in
                EpisodeRow(item: ep, state: s[ep.fileId]) { play(ep) }
                    .contextMenu {
                        let watched = s[ep.fileId]?.watched ?? false
                        Button {
                            services.playback.setWatched([ep.fileId], watched: !watched)
                        } label: {
                            Label(watched ? "標記為未看" : "標記為已看", systemImage: watched ? "circle" : "checkmark.circle")
                        }
                        Button { services.play(ep, fromBeginning: true) } label: {
                            Label("從頭播放", systemImage: "backward.end")
                        }
                    }
            }
        }
        .padding(.horizontal)
    }

    private func play(_ item: MediaItem) {
        if askBeforeResume, stateById[item.fileId]?.resumePosition != nil {
            resumeCandidate = item
        } else {
            services.play(item)
        }
    }

    private var info: [String] {
        var out: [String] = []
        if let y = show.year { out.append(String(y)) }
        let seasons = show.seasonNumbers.filter { $0 != 0 }.count
        if seasons > 0 { out.append("\(seasons) 季") }
        out.append("\(show.episodes.count) 集")
        if let c = show.certification, !c.isEmpty { out.append(c) }
        return out
    }

    /// 所有集數共同的規格（全部都是 4K 才標 4K）
    private var badges: [String] {
        let all = show.episodes.map { Set($0.badges) }
        guard var common = all.first else { return [] }
        for b in all.dropFirst() { common.formIntersection(b) }
        let order = ["4K", "HD", "DV", "HDR10+", "HDR10", "HDR", "Atmos", "E-AC3", "AC3"]
        return order.filter(common.contains)
    }
}

/// 一集：縮圖、標題、時長、簡介、進度
struct EpisodeRow: View {
    let item: MediaItem
    let state: PlaybackState?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    RemoteImage(url: item.stillURL)
                        .frame(width: 150, height: 84)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(alignment: .bottom) {
                            if let progress = state?.progress, progress > 0, state?.watched != true {
                                ProgressBar(value: progress).padding(6)
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            if state?.watched == true {
                                Image(systemName: "checkmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .tint)
                                    .padding(5)
                            }
                        }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.displayEpisodeTitle)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                        HStack(spacing: 6) {
                            if item.duration > 0 {
                                Text(Timecode.duration(item.duration))
                            }
                            if let resume = state?.resumePosition, item.duration > 0 {
                                Text("・剩 \(Timecode.duration(item.duration - resume))")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                if let overview = item.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
