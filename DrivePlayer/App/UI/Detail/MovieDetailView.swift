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

/// 電影詳細頁
struct MovieDetailView: View {
    @Environment(AppServices.self) private var services
    @AppStorage(AppServices.Keys.askBeforeResume) private var askBeforeResume = false
    @Bindable var item: MediaItem
    @Query private var states: [PlaybackState]
    @State private var matching = false
    @State private var askResume = false

    init(item: MediaItem) {
        self.item = item
        let id = item.fileId
        _states = Query(filter: #Predicate<PlaybackState> { $0.fileId == id })
    }

    private var state: PlaybackState? { states.first }
    private var watched: Bool { state?.watched ?? false }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                DetailHeader(
                    backdrop: item.backdropURL, poster: item.posterURL, title: item.title,
                    info: info, badges: item.badges, genres: item.genres
                )

                VStack(spacing: 18) {
                    PlayButton(resumeAt: state?.resumePosition, progress: state?.progress ?? 0) {
                        if askBeforeResume, state?.resumePosition != nil {
                            askResume = true
                        } else {
                            services.play(item)
                        }
                    }
                    .confirmationDialog("要從哪裡開始？", isPresented: $askResume, titleVisibility: .visible) {
                        if let t = state?.resumePosition {
                            Button("從 \(Timecode.string(t)) 繼續") { services.play(item) }
                        }
                        Button("從頭播放") { services.play(item, fromBeginning: true) }
                    }

                    HStack(spacing: 0) {
                        CircleActionButton(systemImage: watched ? "checkmark.circle.fill" : "checkmark.circle", label: watched ? "已看" : "未看", isOn: watched) {
                            services.playback.setWatched([item.fileId], watched: !watched)
                        }
                        .frame(maxWidth: .infinity)
                        CircleActionButton(systemImage: item.isFavorite ? "heart.fill" : "heart", label: "收藏", isOn: item.isFavorite) {
                            item.isFavorite.toggle()
                        }
                        .frame(maxWidth: .infinity)
                        CircleActionButton(systemImage: item.isWatchlisted ? "bookmark.fill" : "bookmark", label: "待看", isOn: item.isWatchlisted) {
                            item.isWatchlisted.toggle()
                        }
                        .frame(maxWidth: .infinity)
                        CircleActionButton(systemImage: "backward.end.fill", label: "從頭播放") {
                            services.play(item, fromBeginning: true)
                        }
                        .frame(maxWidth: .infinity)
                    }

                    if let overview = item.overview, !overview.isEmpty {
                        ExpandableText(text: overview)
                    }
                    if let rating = item.rating, rating > 0 {
                        RatingView(rating: rating)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal)

                if !item.cast.isEmpty {
                    CastRow(cast: item.cast)
                }
                FileInfoSection(item: item)
                    .padding(.bottom, 30)
            }
        }
        .detailPageStyle()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { matching = true } label: { Label("手動指定 TMDB", systemImage: "magnifyingglass") }
                    Button { services.matcher.rematch(item) } label: { Label("重新自動比對", systemImage: "arrow.triangle.2.circlepath") }
                } label: {
                    Image(systemName: "ellipsis.circle")
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
    }

    private var info: [String] {
        var out: [String] = []
        if item.duration > 0 { out.append(Timecode.duration(item.duration)) }
        if let y = item.year { out.append(String(y)) }
        if let c = item.certification, !c.isEmpty { out.append(c) }
        return out
    }
}
