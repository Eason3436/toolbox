import Core
import CoreImage
import SwiftData
import SwiftUI
import UIKit

// MARK: - 海報主色

/// 從海報取一個顏色當詳細頁的底色：取下半部的平均色，壓低亮度與彩度，讓白字看得清楚
@MainActor
enum PosterTint {
    private static var cache: [URL: Color] = [:]

    static func cached(_ url: URL?) -> Color? {
        url.flatMap { cache[$0] }
    }

    static func color(for url: URL?) async -> Color? {
        guard let url else { return nil }
        if let c = cache[url] { return c }
        guard let image = await ImageCache.shared.image(for: url) else { return nil }
        let rgb = await Task.detached(priority: .userInitiated) { averageColor(image) }.value
        guard let rgb else { return nil }
        let color = Color(uiColor: adjusted(rgb))
        cache[url] = color
        return color
    }

    nonisolated private static func averageColor(_ image: UIImage) -> (CGFloat, CGFloat, CGFloat)? {
        guard let cg = image.cgImage else { return nil }
        let input = CIImage(cgImage: cg)
        let extent = input.extent
        // 下半部：跟資訊文字疊在一起的地方
        let region = CIVector(x: extent.minX, y: extent.minY, z: extent.width, w: extent.height * 0.5)
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: input, kCIInputExtentKey: region]),
              let output = filter.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        context.render(output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return (CGFloat(pixel[0]) / 255, CGFloat(pixel[1]) / 255, CGFloat(pixel[2]) / 255)
    }

    nonisolated private static func adjusted(_ rgb: (CGFloat, CGFloat, CGFloat)) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return UIColor(hue: h, saturation: min(s, 0.45), brightness: min(max(b, 0.26), 0.42), alpha: 1)
    }
}

// MARK: - 背景

/// 詳細頁底色：海報主色，上面疊一層很模糊的海報
struct DetailBackground: View {
    let tint: Color
    let posterURL: URL?

    var body: some View {
        ZStack {
            tint
            RemoteImage(url: posterURL)
                .blur(radius: 60)
                .opacity(0.35)
            LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }
}

// MARK: - 標題區

/// 片名 logo；沒有 logo 或載入失敗就用文字
struct LogoTitle: View {
    let logoURL: URL?
    let title: String
    var maxHeight: CGFloat = 120
    @State private var image: UIImage?
    @State private var failed = false

    init(logoURL: URL?, title: String, maxHeight: CGFloat = 120) {
        self.logoURL = logoURL
        self.title = title
        self.maxHeight = maxHeight
        _image = State(initialValue: logoURL.flatMap { ImageCache.shared.cached($0) })
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 280, maxHeight: maxHeight)
                    .shadow(color: .black.opacity(0.45), radius: 10)
                    .accessibilityLabel(title)
                    .transition(.opacity)
            } else if failed || logoURL == nil {
                Text(title)
                    .font(.largeTitle.weight(.bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.6)
                    .shadow(color: .black.opacity(0.5), radius: 8)
            } else {
                Color.clear.frame(height: min(100, maxHeight))
            }
        }
        .task(id: logoURL) {
            guard let logoURL, image == nil else { return }
            let loaded = await ImageCache.shared.image(for: logoURL)
            withAnimation(.easeOut(duration: 0.2)) {
                image = loaded
                failed = loaded == nil
            }
        }
    }
}

/// 大海報（整個寬度）往下淡出，片名 logo 與資訊疊在下緣。
/// 用沒有字的海報時 logo 疊在海報上；只有一般海報（上面本來就有片名）時 logo 放在海報下面，不會重疊。
/// `pull` 是頂端往下拉超出的距離：海報跟著放大，不會露出空白
struct DetailHero<Info: View>: View {
    let poster: HeroPoster
    let logoURL: URL?
    let title: String
    var pull: CGFloat = 0
    @ViewBuilder var info: Info

    var body: some View {
        if poster.url == nil {
            VStack(spacing: 12) {
                LogoTitle(logoURL: logoURL, title: title)
                info
            }
            .padding(.horizontal)
            .padding(.top, 120)
        } else if poster.hasTitleText {
            VStack(spacing: 12) {
                posterImage(solidUntil: 0.72)
                VStack(spacing: 12) {
                    LogoTitle(logoURL: logoURL, title: title, maxHeight: 90)
                    info
                }
                .padding(.horizontal)
                .padding(.top, -36)
            }
        } else {
            ZStack(alignment: .bottom) {
                posterImage(solidUntil: 0.55)
                VStack(spacing: 12) {
                    LogoTitle(logoURL: logoURL, title: title)
                    info
                }
                .padding(.horizontal)
            }
        }
    }

    private func posterImage(solidUntil: CGFloat) -> some View {
        let pull = self.pull
        return RemoteImage(url: poster.url)
            .aspectRatio(2 / 3, contentMode: .fit)
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: solidUntil),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            }
            .visualEffect { content, proxy in
                // 往下拉：以底部為基準放大，頂端剛好貼著螢幕上緣
                let h = max(proxy.size.height, 1)
                return content.scaleEffect(pull > 0 ? (h + pull) / h : 1, anchor: .bottom)
            }
    }
}

/// 詳細頁、首頁的捲動狀態：往下拉超出多少、是不是已經往上捲了
struct HeroScroll: Equatable {
    var pull: CGFloat = 0
    var scrolled = false
}

extension View {
    /// 追蹤捲動位置（給大海報放大、頂端柔和邊緣用）
    func trackHeroScroll(_ state: Binding<HeroScroll>) -> some View {
        onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentOffset.y + geo.contentInsets.top
        } action: { _, y in
            let next = HeroScroll(pull: max(0, -y), scrolled: y > 24)
            if next != state.wrappedValue { state.wrappedValue = next }
        }
    }

    /// 海報在最上面時，頂端不要柔和邊緣（不然海報上緣會被淡掉）；往上捲之後才出現
    @ViewBuilder
    func heroTopEdge(scrolled: Bool) -> some View {
        if #available(iOS 26.0, *) {
            scrollEdgeEffectHidden(!scrolled, for: .top)
        } else {
            self
        }
    }
}

/// 「★7.2｜2025/4/18｜日本｜動畫,動作｜12+」
struct InfoLine: View {
    var rating: Double?
    var date: String?
    var countryCode: String?
    var genres: [String]
    var certification: String?

    var body: some View {
        let parts = segments
        HStack(spacing: 6) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 { Text("｜").foregroundStyle(.secondary) }
                part
            }
            if let certification, !certification.isEmpty {
                if !parts.isEmpty { Text("｜").foregroundStyle(.secondary) }
                Text(certification)
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 4)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.primary, lineWidth: 1))
            }
        }
        .font(.footnote.weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    private var segments: [Text] {
        var out: [Text] = []
        if let rating, rating > 0 {
            out.append(Text(Image(systemName: "star.fill")).foregroundStyle(.yellow) + Text(rating.formatted(.number.precision(.fractionLength(1)))))
        }
        if let date = DetailFormat.date(date) { out.append(Text(date)) }
        if let countryCode { out.append(Text(CountryNames.name(countryCode))) }
        if !genres.isEmpty { out.append(Text(genres.prefix(4).map { GenreNames.name($0) }.joined(separator: ","))) }
        return out
    }
}

enum DetailFormat {
    /// 「2025-04-18」→ 依語系的日期（2025/4/18）
    static func date(_ s: String?) -> String? {
        guard let s, s.count >= 10 else { return nil }
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        guard let date = f.date(from: String(s.prefix(10))) else { return nil }
        return date.formatted(date: .numeric, time: .omitted)
    }

    /// 「1 小時 49 分鐘」
    static func runtime(_ seconds: Double) -> String? {
        guard seconds > 0 else { return nil }
        return Duration.seconds(seconds.rounded()).formatted(.units(allowed: [.hours, .minutes], width: .wide))
    }
}

// MARK: - 規格 logo

/// 影片規格：畫質、動態範圍、音訊
struct MediaSpec: Equatable {
    var resolution: String?
    var dynamicRange: String?
    var isDolbyVision = false
    var isAtmos = false
    var audioCodec: String?
    var channels: Int?

    init(_ item: MediaItem) {
        let tags = Set(item.fileTags)
        let h = item.height ?? 0, w = item.width ?? 0
        if h >= 1800 || w >= 3200 || tags.contains(QualityTag.uhd4K.rawValue) {
            resolution = "4K"
        } else if h >= 1000 || w >= 1900 || tags.contains(QualityTag.fullHD.rawValue) {
            resolution = "1080p"
        } else if h >= 700 || tags.contains(QualityTag.hd.rawValue) {
            resolution = "720p"
        } else if h > 0 {
            resolution = "\(h)p"
        }
        isDolbyVision = item.isDolbyVision || tags.contains(QualityTag.dolbyVision.rawValue)
        if tags.contains(QualityTag.hdr10Plus.rawValue) {
            dynamicRange = "HDR10+"
        } else if let format = item.hdrFormat {
            dynamicRange = format
        } else if tags.contains(QualityTag.hdr10.rawValue) {
            dynamicRange = "HDR10"
        } else if item.isHDR || tags.contains(QualityTag.hdr.rawValue) {
            dynamicRange = "HDR"
        }
        // 杜比視界 Profile 8 的檔案也會被讀成 HDR10；兩個都標
        if isDolbyVision, dynamicRange == "HDR" { dynamicRange = nil }
        isAtmos = item.isAtmos || tags.contains(QualityTag.atmos.rawValue)
        audioCodec = item.audioFormat
        channels = item.audioChannels
    }

    var isEmpty: Bool {
        resolution == nil && dynamicRange == nil && !isDolbyVision && !isAtmos && audioCodec == nil && channels == nil
    }
}

/// 一排規格 logo：4K、杜比視界、HDR10、杜比全景聲、5.1
struct FormatBadges: View {
    let spec: MediaSpec

    var body: some View {
        HStack(spacing: 8) {
            if let resolution = spec.resolution {
                FormatBadge(filled: resolution == "4K") { Text(resolution).font(.system(size: 12, weight: .heavy)) }
            }
            if spec.isDolbyVision { DolbyBadge(word: "VISION") }
            if let range = spec.dynamicRange {
                FormatBadge { Text(range).font(.system(size: 12, weight: .heavy)) }
            }
            if spec.isAtmos {
                DolbyBadge(word: "ATMOS")
            } else if let codec = spec.audioCodec, codec == "E-AC3" || codec == "AC3" {
                DolbyBadge(word: "AUDIO")
            }
            if let channels = spec.channels, channels > 2, let name = DolbyAudioConfig.layoutName(channels: channels) {
                FormatBadge {
                    HStack(spacing: 3) {
                        Image(systemName: "speaker.wave.2.fill").font(.system(size: 9, weight: .bold))
                        Text(name).font(.system(size: 12, weight: .heavy))
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts: [String] = []
        if let r = spec.resolution { parts.append(r) }
        if spec.isDolbyVision { parts.append("杜比視界") }
        if let d = spec.dynamicRange { parts.append(d) }
        if spec.isAtmos { parts.append("杜比全景聲") }
        if let c = spec.channels, let n = DolbyAudioConfig.layoutName(channels: c) { parts.append(n) }
        return parts.joined(separator: "、")
    }
}

/// 外框的規格標籤
struct FormatBadge<Content: View>: View {
    var filled = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 6)
            .frame(height: 22)
            .foregroundStyle(filled ? AnyShapeStyle(.black) : AnyShapeStyle(.primary))
            .background {
                if filled {
                    RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.white)
                } else {
                    RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.primary, lineWidth: 1.2)
                }
            }
    }
}

/// 「DOLBY／VISION」兩行字的杜比標籤
struct DolbyBadge: View {
    let word: String

    var body: some View {
        FormatBadge {
            HStack(spacing: 4) {
                DolbyMark().frame(width: 15, height: 10)
                VStack(alignment: .leading, spacing: -1) {
                    Text("DOLBY").font(.system(size: 7, weight: .heavy)).tracking(1.2)
                    Text(word).font(.system(size: 9, weight: .heavy)).tracking(0.6)
                }
            }
        }
    }
}

/// 兩個平邊相對的半圓（杜比的雙 D 意象）
struct DolbyMark: View {
    var body: some View {
        GeometryReader { geo in
            let r = geo.size.height / 2
            HStack(spacing: 1) {
                UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: r, bottomTrailingRadius: 0, topTrailingRadius: 0)
                UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: r, topTrailingRadius: r)
            }
        }
    }
}

/// 系統播放器解不了的編碼：先講清楚，播放時才不會以為壞掉
struct CodecWarning: View {
    let item: MediaItem

    var body: some View {
        if let text {
            Label {
                Text(text)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var text: String? {
        switch (item.unsupportedVideo, item.unsupportedAudio) {
        case let (video?, audio?):
            "影片（\(video)）和音訊（\(audio)）的格式 iPhone 內建播放器都不支援，這個檔案播不了。"
        case let (video?, nil):
            "影片格式（\(video)）iPhone 內建播放器不支援，播放時只有聲音。"
        case let (nil, audio?):
            "音訊格式（\(audio)）iPhone 內建播放器不支援，播放時沒有聲音。"
        case (nil, nil):
            nil
        }
    }
}

// MARK: - 播放與動作

/// 淺色膠囊播放鍵：「播放」或「繼續播放／上次播放到：00:12:34」
struct PlayCapsule: View {
    let resumeAt: Double?
    var caption: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "play.fill").font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(resumeAt == nil ? "播放" : "繼續播放").font(.headline)
                    if let resumeAt {
                        Text("上次播放到：\(Timecode.string(resumeAt))").font(.caption.weight(.medium))
                    } else if let caption {
                        Text(caption).font(.caption.weight(.medium)).lineLimit(1)
                    }
                }
            }
            .foregroundStyle(.black)
            .frame(maxWidth: 320)
            .frame(height: 56)
            .background(.white.opacity(0.88), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// 一排沒有外框的圖示鍵（收藏、待看、已看、從頭播放）
struct IconAction: View {
    let systemImage: String
    let label: String
    var isOn = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .regular))
                .frame(width: 56, height: 44)
                .contentShape(Rectangle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .appFeedback(.selection, trigger: isOn)
    }
}

/// 簡介：三行，點一下展開
struct ExpandableText: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        Text(text)
            .font(.subheadline)
            .lineLimit(expanded ? nil : 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.snappy) { expanded.toggle() }
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(expanded ? "收合" : "展開全文")
    }
}

// MARK: - 演員、類型、相似

/// 演員表（導演在最前面）
struct CastRow: View {
    let cast: [TMDBCastMember]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("演員表").font(.title3.weight(.bold)).padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(Array(cast.enumerated()), id: \.offset) { _, member in
                        VStack(spacing: 6) {
                            RemoteImage(url: TMDB.imageURL(member.profilePath, size: .profile))
                                .frame(width: 88, height: 88)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            Text(member.name)
                                .font(.caption.weight(.semibold))
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                            if let character = member.character, !character.isEmpty {
                                Text(character)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .frame(width: 96)
                    }
                }
                .padding(.horizontal)
            }
            .softScrollEdges()
        }
    }
}

/// 類型膠囊
struct GenreChips: View {
    let genres: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("類型").font(.title3.weight(.bold)).padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(genres, id: \.self) { genre in
                        Text(GenreNames.name(genre))
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(.white.opacity(0.14), in: Capsule())
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

/// 媒體庫裡同類型的其他電影與劇集
struct RelatedRow: View {
    let genres: [String]
    let excludeFileId: String?
    let excludeShowKey: String?

    @Query private var items: [MediaItem]
    @Query private var shows: [Show]

    init(genres: [String], excludeFileId: String? = nil, excludeShowKey: String? = nil) {
        self.genres = genres
        self.excludeFileId = excludeFileId
        self.excludeShowKey = excludeShowKey
        let movie = MediaKind.movie.rawValue
        _items = Query(filter: #Predicate<MediaItem> { $0.kindRaw == movie })
    }

    private struct Entry: Identifiable {
        let id: String
        let route: Route
        let poster: URL?
        let title: String
        let subtitle: String?
        let rating: Double?
        let overlap: Int
    }

    private var entries: [Entry] {
        let wanted = Set(genres.map { GenreNames.name($0) })
        guard !wanted.isEmpty else { return [] }
        func overlap(_ g: [String]) -> Int { Set(g.map { GenreNames.name($0) }).intersection(wanted).count }
        var out: [Entry] = []
        for m in items where m.fileId != excludeFileId && m.matchState.isInLibrary {
            let n = overlap(m.genres)
            if n > 0 {
                out.append(Entry(id: "m" + m.fileId, route: .movie(m.fileId), poster: m.posterURL, title: m.title,
                                 subtitle: DetailFormat.date(m.releaseDate) ?? m.year.map(String.init), rating: m.rating, overlap: n))
            }
        }
        for s in shows where s.key != excludeShowKey && s.matchState.isInLibrary {
            let n = overlap(s.genres)
            if n > 0 {
                out.append(Entry(id: "s" + s.key, route: .show(s.key), poster: s.posterURL, title: s.title,
                                 subtitle: s.year.map(String.init), rating: s.rating, overlap: n))
            }
        }
        return Array(out.sorted { ($0.overlap, $0.rating ?? 0) > ($1.overlap, $1.rating ?? 0) }.prefix(15))
    }

    var body: some View {
        let list = entries
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("相似內容").font(.title3.weight(.bold)).padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(list) { entry in
                            NavigationLink(value: entry.route) {
                                PosterCard(url: entry.poster, title: entry.title, subtitle: entry.subtitle, rating: entry.rating)
                                    .frame(width: 128)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }
}

/// 檔案位置：「/Movie/動物方城市 2/檔名.mp4」「我的 Google Drive - Movie」
struct FileLocationCard: View {
    let item: MediaItem

    var body: some View {
        VStack(spacing: 6) {
            Text("/" + (item.parentFolders.reversed() + [item.fileName]).joined(separator: "/"))
                .font(.caption.weight(.medium))
                .multilineTextAlignment(.center)
            Text("我的 Google Drive" + (item.parentFolders.last.map { " - " + $0 } ?? ""))
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Text(item.size.formatted(.byteCount(style: .file)))
                if let w = item.width, let h = item.height { Text("\(w)×\(h)") }
                if let audio = item.audioFormat { Text(audio) }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal)
        .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal)
    }
}

extension View {
    /// 詳細頁共用：海報主色當底、背景圖延伸到狀態列下面
    func detailPageStyle(tint: Color, posterURL: URL?, scroll: Binding<HeroScroll>) -> some View {
        trackHeroScroll(scroll)
            .background(DetailBackground(tint: tint, posterURL: posterURL))
            .ignoresSafeArea(edges: .top)
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .softScrollEdges()
            .heroTopEdge(scrolled: scroll.wrappedValue.scrolled)
            .animation(.easeInOut(duration: 0.35), value: tint)
    }
}
