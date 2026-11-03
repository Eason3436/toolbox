import SwiftUI

/// 截圖縮圖（PhotoKit，先模糊再清晰）。
struct AssetThumbnail: View {
    @Environment(PhotoSyncService.self) private var library
    @Environment(\.displayScale) private var displayScale
    let assetID: String
    /// 以 pt 為單位的目標大小
    var pointSize = CGSize(width: 200, height: 267)
    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .overlay(alignment: .top) {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .clipped()
            .task(id: assetID) {
                image = nil
                guard let asset = library.asset(for: assetID) else { return }
                let size = CGSize(width: pointSize.width * displayScale, height: pointSize.height * displayScale)
                for await next in library.thumbnails.thumbnail(for: asset, targetSize: size) {
                    image = next
                }
            }
    }
}

/// 首頁卡片：縮圖＋AI 標題＋日期。
struct ScreenshotCard: View {
    let item: ScreenshotItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AssetThumbnail(assetID: item.assetID)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 18))
                .overlay {
                    RoundedRectangle(cornerRadius: 18).strokeBorder(.separator, lineWidth: 0.5)
                }
                .overlay(alignment: .bottomLeading) {
                    if let category = item.categoryValue {
                        Label(category.rawValue, systemImage: category.symbol)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .glassEffect(in: .capsule)
                            .padding(8)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                titleView
                Text(item.createdAt.formatted(.dateTime.month().day().hour().minute()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var titleView: some View {
        switch item.status {
        case .done:
            Text(item.title ?? "截圖")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        case .pending:
            Label("等待分析", systemImage: "hourglass")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .failed:
            Label("分析失敗", systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundStyle(.orange)
                .lineLimit(1)
        }
    }
}

/// 搜尋結果列表（命中字反白）。
struct SearchResultsView: View {
    let query: String
    let items: [ScreenshotItem]

    var body: some View {
        let terms = SearchService.terms(from: query)
        let byID = Dictionary(items.map { ($0.assetID, $0) }, uniquingKeysWith: { a, _ in a })
        let hits = SearchService.rank(items.map(\.searchDocument), query: query)
        if hits.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            List(hits, id: \.document.id) { hit in
                if let item = byID[hit.document.id] {
                    NavigationLink(value: ScreenshotRoute(assetID: item.assetID)) {
                        SearchRow(item: item, document: hit.document, terms: terms)
                    }
                }
            }
            .listStyle(.plain)
        }
    }
}

struct SearchRow: View {
    let item: ScreenshotItem
    let document: SearchDocument
    let terms: [String]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AssetThumbnail(assetID: item.assetID, pointSize: CGSize(width: 64, height: 86))
                .frame(width: 64, height: 86)
                .clipShape(.rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text(SearchService.highlighted(document.title.isEmpty ? "截圖" : document.title, terms: terms))
                    .font(.headline)
                    .lineLimit(1)
                if let snippet = SearchService.snippet(in: document.summary, terms: terms)
                    ?? SearchService.snippet(in: document.ocrText, terms: terms) {
                    Text(SearchService.highlighted(snippet, terms: terms))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                } else if !document.summary.isEmpty {
                    Text(document.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 6) {
                    if let category = item.categoryValue {
                        Label(category.rawValue, systemImage: category.symbol)
                    }
                    Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                    if item.isArchived { Label("已封存", systemImage: "archivebox") }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}
