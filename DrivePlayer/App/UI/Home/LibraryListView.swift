import SwiftData
import SwiftUI

/// 媒體庫裡的所有影片（文字列表）
struct LibraryListView: View {
    @Environment(AppServices.self) private var services
    @Query(sort: \MediaItem.fileName) private var items: [MediaItem]

    private var movies: [MediaItem] { items.filter { $0.kind == .movie } }
    private var episodes: [MediaItem] { items.filter { $0.kind == .episode } }

    var body: some View {
        List {
            if !movies.isEmpty {
                Section("電影（\(movies.count)）") {
                    ForEach(movies) { row($0) }
                }
            }
            if !episodes.isEmpty {
                Section("劇集（\(episodes.count)）") {
                    ForEach(episodes) { row($0) }
                }
            }
        }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView(
                    "尚未加入媒體庫", systemImage: "film.stack",
                    description: Text("到「媒體庫」加入 Google 雲端硬碟的資料夾")
                )
            }
        }
        .softScrollEdges()
        .navigationTitle("全部影片")
    }

    private func row(_ item: MediaItem) -> some View {
        Button {
            services.play(item)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.title).font(.body)
                    if let label = item.episodeLabel {
                        Text(label).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if let year = item.year {
                        Text(String(year)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(item.fileName)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                if !item.fileTags.isEmpty {
                    Text(item.fileTags.joined(separator: " · "))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .tint(.primary)
    }
}
