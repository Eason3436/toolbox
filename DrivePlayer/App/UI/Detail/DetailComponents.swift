import Core
import SwiftUI

/// 背景大圖延伸到頂部，往下漸層成黑色；片名與資訊列疊在下緣
struct DetailHeader: View {
    let backdrop: URL?
    let poster: URL?
    let title: String
    let info: [String]
    let badges: [String]
    let genres: [String]

    var body: some View {
        ZStack(alignment: .bottom) {
            RemoteImage(url: backdrop ?? poster)
                .frame(height: 440)
                .frame(maxWidth: .infinity)
                .clipped()
                .overlay {
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.35), location: 0),
                            .init(color: .clear, location: 0.25),
                            .init(color: .black.opacity(0.6), location: 0.65),
                            .init(color: .black, location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                }
            VStack(spacing: 10) {
                Text(title)
                    .font(.largeTitle.weight(.bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.6)
                    .shadow(radius: 8)
                infoLine
                if !genres.isEmpty {
                    Text(genres.map { GenreNames.name($0) }.joined(separator: "・"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
        }
    }

    private var infoLine: some View {
        HStack(spacing: 8) {
            if !info.isEmpty {
                Text(info.joined(separator: "｜"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(badges, id: \.self) { SpecBadge(text: $0) }
        }
    }
}

/// 可以展開的簡介
struct ExpandableText: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(.callout)
                .lineLimit(expanded ? nil : 4)
                .foregroundStyle(.primary.opacity(0.9))
            if text.count > 90 {
                Button(expanded ? "收合" : "更多") {
                    withAnimation(.snappy) { expanded.toggle() }
                }
                .font(.footnote.weight(.semibold))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 演員橫向列表
struct CastRow: View {
    let cast: [TMDBCastMember]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("演員").font(.headline).padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(cast) { member in
                        VStack(spacing: 6) {
                            RemoteImage(url: TMDB.imageURL(member.profilePath, size: .profile))
                                .frame(width: 72, height: 72)
                                .clipShape(Circle())
                            Text(member.name)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            if let character = member.character, !character.isEmpty {
                                Text(character)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .frame(width: 84)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

/// TMDB 評分
struct RatingView: View {
    let rating: Double

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "star.fill").foregroundStyle(.yellow)
            Text(rating.formatted(.number.precision(.fractionLength(1))))
                .font(.subheadline.weight(.semibold).monospacedDigit())
            Text("TMDB").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("TMDB 評分 \(rating.formatted(.number.precision(.fractionLength(1))))")
    }
}

/// 檔案資訊
struct FileInfoSection: View {
    let item: MediaItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("檔案").font(.headline)
            Group {
                Text(item.fileName)
                HStack(spacing: 10) {
                    Text(item.size.formatted(.byteCount(style: .file)))
                    if let w = item.width, let h = item.height { Text("\(w)×\(h)") }
                    if let audio = item.audioFormat { Text(audio) }
                    if item.isDolbyVision { Text("杜比視界") } else if item.isHDR { Text("HDR") }
                }
                if !item.parentFolders.isEmpty {
                    Text(item.parentFolders.reversed().joined(separator: "／"))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
    }
}

extension View {
    /// 詳細頁共用：黑底、背景圖延伸到狀態列下面
    func detailPageStyle() -> some View {
        background(Color.black)
            .ignoresSafeArea(edges: .top)
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
    }
}
