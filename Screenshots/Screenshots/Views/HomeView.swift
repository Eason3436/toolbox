import SwiftUI

/// 首頁：依日期分段的兩欄截圖卡片。
struct HomeView: View {
    @Environment(PhotoSyncService.self) private var library
    @Environment(\.openURL) private var openURL
    @AppStorage("importRange") private var importRange: ImportRange = .all

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("截圖")
                .navigationSubtitle(subtitle)
                .navigationDestination(for: ScreenshotRecord.self) { record in
                    ScreenshotViewer(record: record)
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if library.hasLoaded && library.records.isEmpty {
            ContentUnavailableView {
                Label("沒有截圖", systemImage: "camera.viewfinder")
            } description: {
                Text(importRange == .all ? "相簿裡還沒有截圖。" : "\(importRange.title)內沒有截圖，可以到「設定」放寬匯入範圍。")
            }
        } else {
            ScrollView {
                if library.access == .limited {
                    limitedBanner
                }
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(library.sections) { section in
                        Section {
                            ForEach(section.items) { record in
                                NavigationLink(value: record) {
                                    ScreenshotCard(record: record)
                                }
                                .buttonStyle(.plain)
                            }
                        } header: {
                            Text(DayGrouping.title(for: section.day))
                                .font(.headline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 8)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .refreshable { library.reload(range: importRange) }
        }
    }

    private var subtitle: String {
        library.records.isEmpty ? "" : "共 \(library.records.count.formatted()) 張"
    }

    private var limitedBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("只允許取用部分照片，可能看不到全部截圖。")
                    .font(.subheadline)
                Button("改成完整取用") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .font(.subheadline.bold())
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .glassEffect(in: .rect(cornerRadius: 20))
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }
}

/// 單張截圖卡片：縮圖（保留上半部）＋日期時間。
struct ScreenshotCard: View {
    @Environment(PhotoSyncService.self) private var library
    @Environment(\.displayScale) private var displayScale
    let record: ScreenshotRecord
    @State private var image: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .overlay(alignment: .top) {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Rectangle().fill(.quaternary)
                    }
                }
                .clipShape(.rect(cornerRadius: 18))
                .overlay {
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(.separator, lineWidth: 0.5)
                }
            Text(record.createdAt.formatted(.dateTime.hour().minute()))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
        .contentShape(.rect)
        .task(id: record.id) {
            image = nil
            guard let asset = library.asset(for: record) else { return }
            // 兩欄卡片約 200pt 寬，依螢幕倍率換算成像素。
            let size = CGSize(width: 200 * displayScale, height: 267 * displayScale)
            for await next in library.thumbnails.thumbnail(for: asset, targetSize: size) {
                image = next
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("截圖，\(record.createdAt.formatted(date: .abbreviated, time: .shortened))")
    }
}
