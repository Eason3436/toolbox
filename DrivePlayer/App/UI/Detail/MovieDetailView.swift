import Core
import SwiftData
import SwiftUI

struct MovieDetailLoader: View {
    @Query private var items: [MediaItem]

    init(fileId: String) {
        _items = Query(filter: #Predicate<MediaItem> { $0.fileId == fileId })
    }

    var body: some View {
        if let item = items.first {
            MovieDetailView(item: item)
        } else {
            ContentUnavailableView("找不到這部影片", systemImage: "film", description: Text("可能已經從雲端硬碟移除，重新掃描媒體庫試試看。"))
        }
    }
}

/// 電影詳細頁：整張海報、片名 logo、海報主色的底
struct MovieDetailView: View {
    @Environment(AppServices.self) private var services
    @Bindable var item: MediaItem
    @Query private var states: [PlaybackState]
    @State private var matching = false
    @State private var tint: Color
    @State private var scroll = HeroScroll()

    init(item: MediaItem) {
        self.item = item
        let id = item.fileId
        _states = Query(filter: #Predicate<PlaybackState> { $0.fileId == id })
        _tint = State(initialValue: PosterTint.cached(item.heroPoster.url) ?? Color(white: 0.12))
    }

    private var state: PlaybackState? { states.first }
    private var watched: Bool { state?.watched ?? false }
    private var posterURL: URL? { item.heroPoster.url }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                DetailHero(poster: item.heroPoster, logoURL: TMDB.imageURL(item.logoPath, size: .logo), title: item.title, pull: scroll.pull) {
                    VStack(spacing: 8) {
                        InfoLine(rating: item.rating, date: item.releaseDate ?? item.year.map(String.init),
                                 countryCode: item.countryCode, genres: item.genres, certification: item.certification)
                        if !subline.isEmpty {
                            Text(subline)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        let spec = MediaSpec(item)
                        if !spec.isEmpty { FormatBadges(spec: spec).padding(.top, 2) }
                        AudioTrackMenu(tracks: item.audioTracks, selected: item.resolvedAudioTrack,
                                       isAutomatic: item.audioTrackChoice == nil) { item.audioTrackChoice = $0 }
                            .padding(.top, 2)
                        CodecWarning(item: item)
                    }
                }

                VStack(spacing: 16) {
                    PlayCapsule(resumeAt: state?.resumePosition) { services.play(item) }

                    HStack(spacing: 28) {
                        IconAction(systemImage: item.isFavorite ? "heart.fill" : "heart", label: "收藏", isOn: item.isFavorite) {
                            item.isFavorite.toggle()
                        }
                        IconAction(systemImage: item.isWatchlisted ? "text.badge.checkmark" : "text.badge.plus", label: "待看", isOn: item.isWatchlisted) {
                            item.isWatchlisted.toggle()
                        }
                        IconAction(systemImage: watched ? "checkmark.circle.fill" : "checkmark.circle", label: watched ? "已看" : "標記為已看", isOn: watched) {
                            services.playback.setWatched([item.fileId], watched: !watched)
                        }
                        IconAction(systemImage: "arrow.counterclockwise", label: "從頭播放") {
                            services.play(item, fromBeginning: true)
                        }
                    }

                    if let overview = item.overview, !overview.isEmpty {
                        ExpandableText(text: overview)
                    }
                }
                .padding(.horizontal)

                if !item.cast.isEmpty {
                    CastRow(cast: item.cast)
                }
                if !item.genres.isEmpty {
                    GenreChips(genres: item.genres)
                }
                RelatedRow(genres: item.genres, excludeFileId: item.fileId)
                FileLocationCard(item: item)
                    .padding(.bottom, 30)
            }
        }
        .scrollIndicators(.hidden)
        .detailPageStyle(tint: tint, posterURL: posterURL, scroll: $scroll)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { matching = true } label: { Label("手動指定 TMDB", systemImage: "magnifyingglass") }
                    Button { services.matcher.rematch(item) } label: { Label("重新自動比對", systemImage: "arrow.triangle.2.circlepath") }
                    if item.matchState != .ignored {
                        Button(role: .destructive) { services.matcher.ignore(item) } label: {
                            Label("不需要配對", systemImage: "nosign")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("更多")
            }
        }
        .sheet(isPresented: $matching) {
            ManualMatchView(target: .movie(item))
        }
        .task(id: item.fileId) {
            await services.probeSpecs(item)
        }
        .task(id: posterURL) {
            if let color = await PosterTint.color(for: posterURL) { tint = color }
        }
    }

    /// 「1 小時 49 分鐘 · 16.35 GB」（畫質已經在下面的規格 logo）
    private var subline: String {
        var parts: [String] = []
        if let runtime = DetailFormat.runtime(item.duration) { parts.append(runtime) }
        if item.size > 0 { parts.append(item.size.formatted(.byteCount(style: .file))) }
        return parts.joined(separator: " · ")
    }
}
