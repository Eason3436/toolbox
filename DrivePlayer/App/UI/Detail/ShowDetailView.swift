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

/// 劇集詳細頁：整張海報、片名 logo、海報主色的底，季別切換 + 集數列表
struct ShowDetailView: View {
    @Environment(AppServices.self) private var services
    @Bindable var show: Show
    @Query private var states: [PlaybackState]
    @State private var season: Int?
    @State private var matching = false
    @State private var editingIntro = false
    @State private var tint: Color

    init(show: Show) {
        self.show = show
        _tint = State(initialValue: PosterTint.cached(show.posterURL) ?? Color(white: 0.12))
    }

    private var posterURL: URL? { TMDB.imageURL(show.posterPath, size: .posterLarge) ?? show.posterURL }

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
        let next = nextUp
        ScrollView {
            VStack(spacing: 22) {
                DetailHero(posterURL: posterURL, logoURL: TMDB.imageURL(show.logoPath, size: .logo), title: show.title) {
                    VStack(spacing: 8) {
                        InfoLine(rating: show.rating, date: show.releaseDate ?? show.year.map(String.init),
                                 countryCode: show.countryCode, genres: show.genres, certification: show.certification)
                        Text(subline)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if let next {
                            let spec = MediaSpec(next)
                            if !spec.isEmpty { FormatBadges(spec: spec).padding(.top, 2) }
                        }
                    }
                }

                VStack(spacing: 16) {
                    if let next {
                        PlayCapsule(resumeAt: stateById[next.fileId]?.resumePosition, caption: next.episodeLabel.map { "\($0)・\(next.episodeTitle ?? next.fileName)" }) {
                            services.play(next)
                        }
                    }

                    HStack(spacing: 28) {
                        IconAction(systemImage: show.isFavorite ? "heart.fill" : "heart", label: "收藏", isOn: show.isFavorite) {
                            show.isFavorite.toggle()
                        }
                        IconAction(systemImage: show.isWatchlisted ? "text.badge.checkmark" : "text.badge.plus", label: "待看", isOn: show.isWatchlisted) {
                            show.isWatchlisted.toggle()
                        }
                        IconAction(systemImage: allWatched ? "checkmark.circle.fill" : "checkmark.circle", label: allWatched ? "已看完" : "全部標記為已看", isOn: allWatched) {
                            services.playback.setWatched(show.episodes.map(\.fileId), watched: !allWatched)
                        }
                        IconAction(systemImage: "arrow.counterclockwise", label: "從第一集播放") {
                            if let first = show.orderedEpisodes.first { services.play(first, fromBeginning: true) }
                        }
                    }

                    if let overview = show.overview, !overview.isEmpty {
                        ExpandableText(text: overview)
                    }
                }
                .padding(.horizontal)

                VStack(spacing: 14) {
                    seasonPicker
                    episodeList
                }

                if !show.cast.isEmpty {
                    CastRow(cast: show.cast)
                }
                if !show.genres.isEmpty {
                    GenreChips(genres: show.genres)
                }
                RelatedRow(genres: show.genres, excludeShowKey: show.key)
                    .padding(.bottom, 30)
            }
        }
        .scrollIndicators(.hidden)
        .detailPageStyle(tint: tint, posterURL: posterURL)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { editingIntro = true } label: { Label("片頭片尾", systemImage: "forward.end") }
                    Button { matching = true } label: { Label("手動指定 TMDB", systemImage: "magnifyingglass") }
                    if let any = show.episodes.first {
                        Button { services.matcher.rematch(any) } label: { Label("重新自動比對", systemImage: "arrow.triangle.2.circlepath") }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("更多")
            }
        }
        .sheet(isPresented: $matching) {
            ManualMatchView(target: .show(show))
        }
        .sheet(isPresented: $editingIntro) {
            IntroOutroSheet(show: show)
                .presentationDetents([.medium])
        }
        .task(id: next?.fileId) {
            if let next { await services.probeSpecs(next) }
        }
        .task(id: posterURL) {
            if let color = await PosterTint.color(for: posterURL) { tint = color }
        }
    }

    /// 「2 季 · 24 集 · 每集 45 分鐘」
    private var subline: String {
        var parts: [String] = []
        let seasons = show.seasonNumbers.filter { $0 != 0 }.count
        if seasons > 0 { parts.append("\(seasons) 季") }
        parts.append("\(show.episodes.count) 集")
        if let minutes = show.episodeRuntime, let runtime = DetailFormat.runtime(Double(minutes * 60)) {
            parts.append("每集 " + runtime)
        }
        return parts.joined(separator: " · ")
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
            .appFeedback(.selection, trigger: season)
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
                EpisodeRow(item: ep, state: s[ep.fileId]) { services.play(ep) }
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

}

/// 每部劇的片頭、片尾長度（自動跳過用）
struct IntroOutroSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var show: Show

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $show.introSeconds, in: 0...600, step: 5) {
                        LabeledContent("片頭結束於", value: label(show.introSeconds))
                    }
                    Stepper(value: $show.outroSeconds, in: 0...900, step: 5) {
                        LabeledContent("片尾長度", value: label(show.outroSeconds))
                    }
                } footer: {
                    Text("「設定 → 播放」打開「自動跳過片頭片尾」時：每集從片頭結束的地方開始播，剩下片尾長度時就當成看完、倒數播下一集。設成 0 就不跳。")
                }
            }
            .navigationTitle("片頭片尾")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func label(_ seconds: Double) -> String {
        seconds <= 0 ? "不跳過" : Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))
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
