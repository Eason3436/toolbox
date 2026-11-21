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
                        }
                    }
                }
            }
            if !unmatchedShows.isEmpty {
                Section("劇集") {
                    ForEach(unmatchedShows) { show in
                        row(title: show.parsedTitle, detail: "\(show.episodes.count) 集・\(show.episodes.first?.fileName ?? "")") {
                            target = MatchTarget(target: .show(show), id: show.key)
                        } play: {
                            if let first = show.orderedEpisodes.first { services.play(first) }
                        }
                    }
                }
            }
        }
        .overlay {
            if movies.isEmpty && unmatchedShows.isEmpty {
                ContentUnavailableView("全部都辨識了", systemImage: "checkmark.circle")
            }
        }
        .navigationTitle("未辨識")
        .sheet(item: $target) { t in
            ManualMatchView(target: t.target)
        }
    }

    private func row(title: String, detail: String, match: @escaping () -> Void, play: @escaping () -> Void) -> some View {
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
        .accessibilityAction(named: "手動指定", match)
    }
}

private struct MatchTarget: Identifiable {
    let target: ManualMatchView.Target
    let id: String
}
