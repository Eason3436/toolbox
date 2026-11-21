import Core
import SwiftUI

// MARK: - 顯示用的資料

extension MediaItem {
    var posterURL: URL? { TMDB.imageURL(posterPath ?? show?.posterPath, size: .poster) }
    var backdropURL: URL? { TMDB.imageURL(backdropPath ?? show?.backdropPath, size: .backdrop) }
    var stillURL: URL? { TMDB.imageURL(stillPath, size: .still) ?? TMDB.imageURL(backdropPath ?? show?.backdropPath, size: .still) }

    /// 規格標籤：4K｜DV｜HDR10｜Atmos
    var badges: [String] {
        var out: [String] = []
        let tags = Set(fileTags)
        if (height ?? 0) >= 1800 || (width ?? 0) >= 3200 || tags.contains(QualityTag.uhd4K.rawValue) {
            out.append("4K")
        } else if (height ?? 0) >= 1000 || tags.contains(QualityTag.fullHD.rawValue) {
            out.append("HD")
        }
        if isDolbyVision || tags.contains(QualityTag.dolbyVision.rawValue) {
            out.append("DV")
        } else if tags.contains(QualityTag.hdr10Plus.rawValue) {
            out.append("HDR10+")
        } else if tags.contains(QualityTag.hdr10.rawValue) {
            out.append("HDR10")
        } else if isHDR || tags.contains(QualityTag.hdr.rawValue) {
            out.append("HDR")
        }
        if tags.contains(QualityTag.atmos.rawValue) {
            out.append("Atmos")
        } else if let audio = audioFormat, audio == "E-AC3" || audio == "AC3" {
            out.append(audio)
        }
        return out
    }

    /// 劇集：「第 5 集・標題」；電影：片名
    var displayEpisodeTitle: String {
        guard kind == .episode else { return title }
        var s = episode.map { "第 \($0) 集" } ?? fileName
        if let end = episodeEnd { s = "第 \(episode ?? 0)–\(end) 集" }
        if let t = episodeTitle, !t.isEmpty { s += "・" + t }
        return s
    }
}

extension Show {
    var posterURL: URL? { TMDB.imageURL(posterPath, size: .poster) }
    var backdropURL: URL? { TMDB.imageURL(backdropPath, size: .backdrop) }
}

// MARK: - 元件

/// 規格標籤（4K、DV、Atmos）
struct SpecBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary, lineWidth: 1))
            .foregroundStyle(.secondary)
    }
}

/// 海報卡（2:3）
struct PosterCard: View {
    let url: URL?
    let title: String
    var subtitle: String?
    var progress: Double?
    var watched = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteImage(url: url)
                .aspectRatio(2 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if watched {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .tint)
                            .padding(6)
                    }
                }
                .overlay(alignment: .bottom) {
                    if let progress, progress > 0 {
                        ProgressBar(value: progress).padding(6)
                    }
                }
            Text(title)
                .font(.footnote.weight(.medium))
                .lineLimit(1)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// 橫向的背景圖卡（16:9），「繼續觀看」與單集列表用
struct BackdropCard: View {
    let url: URL?
    let title: String
    var subtitle: String?
    var progress: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteImage(url: url)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .bottom) {
                    if let progress, progress > 0 {
                        ProgressBar(value: progress).padding(8)
                    }
                }
                .overlay {
                    Image(systemName: "play.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(.ultraThinMaterial, in: Circle())
                }
            Text(title)
                .font(.footnote.weight(.medium))
                .lineLimit(1)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct ProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3))
                Capsule().fill(.white).frame(width: geo.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: 4)
        .accessibilityLabel("已看 \(Int(value * 100))%")
    }
}

/// 詳細頁的圓形功能按鈕
struct CircleActionButton: View {
    let systemImage: String
    let label: String
    var isOn = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .frame(width: 50, height: 50)
                    .background(isOn ? AnyShapeStyle(.tint.opacity(0.25)) : AnyShapeStyle(.white.opacity(0.12)), in: Circle())
                    .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .contentTransition(.symbolEffect(.replace))
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isOn)
    }
}

/// 主按鈕：有進度時用底色當進度條
struct PlayButton: View {
    let resumeAt: Double?
    let progress: Double
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "play.fill")
                if let resumeAt {
                    Text("自 \(Timecode.string(resumeAt)) 繼續")
                } else {
                    Text("播放")
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .foregroundStyle(.black)
            .background {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(.white.opacity(resumeAt == nil ? 1 : 0.7))
                        if resumeAt != nil {
                            Rectangle().fill(.white).frame(width: geo.size.width * progress)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// 首頁區塊標題
struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.weight(.bold))
            Spacer()
            trailing
        }
        .padding(.horizontal)
    }
}
