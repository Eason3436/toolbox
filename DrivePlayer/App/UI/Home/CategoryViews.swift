import Core
import SwiftData
import SwiftUI

// MARK: - 分類卡

/// 分類卡：有顏色的底、三張斜放的海報、名稱與數量
struct CategoryCard: View {
    let group: CategoryGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            fan
                .frame(maxWidth: .infinity)
                .frame(height: 118)
                .padding(.top, 14)
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline) {
                Text(group.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(group.entries.count.formatted())
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .frame(width: 230, height: 180)
        .background(CategoryCard.gradient(for: group.value), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(group.name)，\(group.entries.count) 部")
    }

    private var fan: some View {
        let posters = Array(group.entries.prefix(3))
        return ZStack {
            ForEach(0..<3, id: \.self) { i in
                let tilt = Double(i - 1)
                Group {
                    if i < posters.count {
                        RemoteImage(url: posters[i].posterURL)
                    } else {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.1))
                    }
                }
                .frame(width: 74, height: 111)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
                .rotationEffect(.degrees(tilt * 7))
                .offset(x: tilt * 52, y: abs(tilt) * 6)
                .zIndex(Double(3 - i))
            }
        }
    }

    /// 每個分類一個固定的顏色（名字算出來的，不會每次換）
    static func gradient(for value: String) -> LinearGradient {
        let seed = value.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        let hues: [Double] = [0.02, 0.08, 0.55, 0.62, 0.72, 0.78, 0.86, 0.47, 0.12, 0.95]
        let hue = hues[seed % hues.count]
        return LinearGradient(
            colors: [Color(hue: hue, saturation: 0.55, brightness: 0.42), Color(hue: hue, saturation: 0.6, brightness: 0.26)],
            startPoint: .top, endPoint: .bottom
        )
    }
}

// MARK: - 某一種分類的全部（「類型」→ 全部）

struct CategoryListView: View {
    let kind: CategoryKind
    @Query private var items: [MediaItem]
    @Query private var shows: [Show]

    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 12)]

    var body: some View {
        let groups = CategoryGroup.groups(kind, in: LibraryEntry.library(items: items, shows: shows))
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(groups) { group in
                    NavigationLink(value: Route.category(kind, group.value)) {
                        CategoryCard(group: group)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .overlay {
            if groups.isEmpty { ContentUnavailableView("沒有分類", systemImage: "square.grid.2x2") }
        }
        .softScrollEdges()
        .navigationTitle(kind.title)
    }
}

// MARK: - 一個分類裡的片

struct CategoryItemsView: View {
    let kind: CategoryKind
    let value: String
    @Query private var items: [MediaItem]
    @Query private var shows: [Show]
    @Query private var states: [PlaybackState]

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 12, alignment: .top)]

    var body: some View {
        let entries = LibraryEntry.library(items: items, shows: shows)
            .filter { $0.values(kind).contains(value) }
            .sorted { ($0.rating ?? 0) > ($1.rating ?? 0) }
        ScrollView {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(entries) { entry in
                    NavigationLink(value: entry.route) {
                        PosterCard(url: entry.posterURL, title: entry.title, subtitle: entry.subtitle, rating: entry.rating)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .overlay {
            if entries.isEmpty { ContentUnavailableView("沒有內容", systemImage: "film") }
        }
        .softScrollEdges()
        .navigationTitle(LibraryCategory.name(kind, value))
    }
}

// MARK: - 其他影片（不需要配對的）

struct OthersView: View {
    @Query private var items: [MediaItem]
    @Query private var shows: [Show]

    var body: some View {
        let entries = LibraryEntry.others(items: items, shows: shows)
        List {
            ForEach(entries) { entry in
                NavigationLink(value: entry.route) {
                    Label(entry.title, systemImage: entry.id.hasPrefix("s-") ? "tv" : "film")
                }
            }
        }
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView("沒有其他影片", systemImage: "film", description: Text("在影片的「⋯」選「不需要配對」，就會放在這裡。"))
            }
        }
        .softScrollEdges()
        .navigationTitle("其他影片")
    }
}

/// 沒有海報的卡片（不需要配對的影片）
struct PlainVideoCard: View {
    let entry: LibraryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.08))
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    Image(systemName: entry.id.hasPrefix("s-") ? "tv" : "film")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            Text(entry.title)
                .font(.footnote.weight(.medium))
                .lineLimit(1)
            if let subtitle = entry.subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 首頁輪播

/// 首頁最上面的推薦輪播：無字海報 + 片名 logo + 資訊 + 簡介，左右滑、會自己換頁
struct FeaturedCarousel: View {
    let entries: [LibraryEntry]
    @State private var page: String?

    var body: some View {
        let current = page ?? entries.first?.id
        VStack(spacing: 10) {
            TabView(selection: Binding(get: { current ?? "" }, set: { page = $0 })) {
                ForEach(entries) { entry in
                    NavigationLink(value: entry.route) {
                        FeaturedPage(entry: entry)
                    }
                    .buttonStyle(.plain)
                    .tag(entry.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .containerRelativeFrame(.vertical) { height, _ in height * 0.7 }

            if entries.count > 1 {
                HStack(spacing: 7) {
                    ForEach(entries) { entry in
                        Circle()
                            .fill(entry.id == current ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                            .frame(width: 7, height: 7)
                    }
                }
                .accessibilityHidden(true)
            }
        }
        // 停在同一頁 7 秒就換下一頁；手動滑了就重新計時
        .task(id: current) {
            guard entries.count > 1 else { return }
            try? await Task.sleep(for: .seconds(7))
            guard !Task.isCancelled, let current, let i = entries.firstIndex(where: { $0.id == current }) else { return }
            withAnimation(.smooth) { page = entries[(i + 1) % entries.count].id }
        }
    }
}

private struct FeaturedPage: View {
    let entry: LibraryEntry

    var body: some View {
        ZStack(alignment: .bottom) {
            RemoteImage(url: entry.hero.url)
                .mask {
                    LinearGradient(
                        stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.55), .init(color: .clear, location: 1)],
                        startPoint: .top, endPoint: .bottom
                    )
                }

            VStack(spacing: 10) {
                if !entry.hero.hasTitleText {
                    LogoTitle(logoURL: entry.logoURL, title: entry.title, maxHeight: 100)
                }
                InfoLine(rating: entry.rating, date: entry.year.map(String.init), countryCode: entry.countryCode,
                         genres: entry.genres, certification: entry.certification)
                if let overview = entry.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
