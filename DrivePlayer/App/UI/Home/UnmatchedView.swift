import SwiftData
import SwiftUI

/// 未辨識：TMDB 比對不到的電影與劇集，可以手動指定
struct UnmatchedView: View {
    @Environment(AppServices.self) private var services
    @Query(sort: \MediaItem.fileName) private var items: [MediaItem]
    @Query(sort: \Show.parsedTitle) private var shows: [Show]
    @State private var target: MatchTarget?

    private var movies: [MediaItem] { items.filter { $0.kind == .movie && $0.matchState == .unmatched } }
    private var unmatchedShows: [Show] { shows.filter { $0.matchState == .unmatched } }

    var body: some View {
        List {
            if !movies.isEmpty {
                Section("電影") {
                    ForEach(movies) { item in
                        row(title: item.parsedTitle.isEmpty ? item.fileName : item.parsedTitle, detail: item.fileName) {
                            target = MatchTarget(target: .movie(item), id: item.fileId)
                        } play: {
                            services.play(item)
                        } ignore: {
                            services.matcher.ignore(item)
                        }
                    }
                }
            }
            if !unmatchedShows.isEmpty {
                Section {
                    ForEach(unmatchedShows) { show in
                        row(title: show.parsedTitle, detail: "\(show.episodes.count) 集・\(show.episodes.first?.fileName ?? "")") {
                            target = MatchTarget(target: .show(show), id: show.key)
                        } play: {
                            if let first = show.orderedEpisodes.first { services.play(first) }
                        } ignore: {
                            services.matcher.ignore(show)
                        }
                    }
                } header: {
                    Text("劇集")
                }
            }
            if !movies.isEmpty || !unmatchedShows.isEmpty {
                Section {} footer: {
                    Text("點一下手動搜尋 TMDB。自己拍的影片、不在 TMDB 上的，往左滑選「不需要配對」，會用檔名當標題，放到首頁的「其他影片」。")
                }
            }
        }
        .overlay {
            if movies.isEmpty && unmatchedShows.isEmpty {
                ContentUnavailableView("全部都辨識了", systemImage: "checkmark.circle")
            }
        }
        .softScrollEdges()
        .navigationTitle("未辨識")
        .sheet(item: $target) { t in
            ManualMatchView(target: t.target)
        }
    }

    private func row(title: String, detail: String, match: @escaping () -> Void, play: @escaping () -> Void, ignore: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button(action: play) {
                Image(systemName: "play.circle.fill").font(.title2)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("播放")
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: match)
        .swipeActions(edge: .trailing) {
            Button(action: ignore) { Label("不需要配對", systemImage: "nosign") }
                .tint(.gray)
        }
        .contextMenu {
            Button(action: match) { Label("手動指定 TMDB", systemImage: "magnifyingglass") }
            Button(action: ignore) { Label("不需要配對", systemImage: "nosign") }
        }
        .accessibilityAction(named: "手動指定", match)
        .accessibilityAction(named: "不需要配對", ignore)
    }
}

private struct MatchTarget: Identifiable {
    let target: ManualMatchView.Target
    let id: String
}
