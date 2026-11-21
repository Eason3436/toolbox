import Core
import SwiftUI

/// 手動搜尋 TMDB 並指定
struct ManualMatchView: View {
    enum Target {
        case movie(MediaItem)
        case show(Show)
    }

    let target: Target
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var year = ""
    @State private var movieResults: [TMDBMovieSummary] = []
    @State private var tvResults: [TMDBTVSummary] = []
    @State private var searching = false
    @State private var assigning: Int?
    @State private var error: String?
    @State private var searched = false

    private var isShow: Bool {
        if case .show = target { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField(isShow ? "劇名" : "片名", text: $query)
                        .submitLabel(.search)
                        .onSubmit { Task { await search() } }
                    TextField("年份（可不填）", text: $year)
                        .keyboardType(.numberPad)
                    Button {
                        Task { await search() }
                    } label: {
                        HStack {
                            Text("搜尋 TMDB")
                            if searching { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || searching)
                } footer: {
                    Text(fileHint)
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }

                Section {
                    if isShow {
                        ForEach(tvResults) { r in
                            resultRow(id: r.id, title: r.name, original: r.originalName, year: r.year, overview: r.overview, poster: r.posterPath)
                        }
                    } else {
                        ForEach(movieResults) { r in
                            resultRow(id: r.id, title: r.title, original: r.originalTitle, year: r.year, overview: r.overview, poster: r.posterPath)
                        }
                    }
                }
            }
            .overlay {
                if searched && !searching && movieResults.isEmpty && tvResults.isEmpty && error == nil {
                    ContentUnavailableView.search(text: query)
                }
            }
            .navigationTitle("指定 TMDB")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear(perform: prefill)
        }
    }

    private var fileHint: String {
        switch target {
        case .movie(let item): "檔名：\(item.fileName)"
        case .show(let show): "\(show.episodes.count) 集，例如：\(show.episodes.first?.fileName ?? "")"
        }
    }

    private func resultRow(id: Int, title: String, original: String?, year: Int?, overview: String?, poster: String?) -> some View {
        Button {
            Task { await assign(id) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                RemoteImage(url: TMDB.imageURL(poster, size: .poster))
                    .frame(width: 60, height: 90)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    HStack(spacing: 6) {
                        if let year { Text(String(year)) }
                        if let original, original != title { Text(original) }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if let overview, !overview.isEmpty {
                        Text(overview).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                Spacer(minLength: 0)
                if assigning == id { ProgressView() }
            }
        }
        .tint(.primary)
        .disabled(assigning != nil)
    }

    private func prefill() {
        guard query.isEmpty else { return }
        switch target {
        case .movie(let item):
            query = item.parsedTitle.isEmpty ? item.title : item.parsedTitle
            year = item.parsedYear.map(String.init) ?? ""
        case .show(let show):
            query = show.parsedTitle
            year = show.parsedYear.map(String.init) ?? ""
        }
        Task { await search() }
    }

    private func search() async {
        guard let tmdb = services.matcher.tmdb else {
            error = TMDBError.notConfigured.localizedDescription
            return
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        defer {
            searching = false
            searched = true
        }
        let y = Int(year)
        do {
            if isShow {
                tvResults = try await tmdb.searchTV(q, year: y)
                if tvResults.isEmpty, y != nil { tvResults = try await tmdb.searchTV(q) }
            } else {
                movieResults = try await tmdb.searchMovies(q, year: y)
                if movieResults.isEmpty, y != nil { movieResults = try await tmdb.searchMovies(q) }
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func assign(_ id: Int) async {
        assigning = id
        defer { assigning = nil }
        do {
            switch target {
            case .movie(let item): try await services.matcher.assignMovie(item, tmdbId: id)
            case .show(let show): try await services.matcher.assignShow(show, tmdbId: id)
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
