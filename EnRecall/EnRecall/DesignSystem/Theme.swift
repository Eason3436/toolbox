import SwiftUI

// MARK: - 顏色
//
// 全部取自 Assets 的 Color Set（每組都有淺色／深色），畫面程式碼一律用 Color.er.*，
// 不准出現 hex、Color.white、Color.black。色票來源：設計稿「EnRecall iOS」。

extension Color {
    static let er = ERPalette()
}

struct ERPalette {
    // 頁面與文字
    let background = Color("ERBackground")
    let text = Color("ERText")
    let textSecondary = Color("ERTextSecondary")
    let textTertiary = Color("ERTextTertiary")

    // 內容卡片（實心，不套玻璃）
    let surface = Color("ERSurface")
    let surfaceMuted = Color("ERSurfaceMuted")
    /// 降低透明度時，toast 改用的實心底
    let surfaceHigh = Color("ERSurfaceHigh")
    let fill = Color("ERFill")
    let outline = Color("EROutline")
    let outlineStrong = Color("EROutlineStrong")
    let mid = Color("ERMid")

    // 主要強調（App tint）
    let primary = Color("ERPrimary")
    let onPrimary = Color("EROnPrimary")

    // 首頁「今日複習」、商店「官方精選」那種深色主卡
    let hero = Color("ERHero")
    let heroOutline = Color("ERHeroOutline")
    let heroText = Color("ERHeroText")
    let heroTextSecondary = Color("ERHeroTextSecondary")
    let heroTile = Color("ERHeroTile")
    let heroMuted = Color("ERHeroMuted")

    // 狀態色
    let accent = Color("ERAccent")
    let info = Color("ERInfo")
    let infoContainer = Color("ERInfoContainer")
    let infoTrack = Color("ERInfoTrack")
    let danger = Color("ERDanger")

    // 評分
    let ratingAgain = Color("ERRatingAgain")
    let ratingHard = Color("ERRatingHard")
    let ratingGood = Color("ERRatingGood")
    let ratingEasy = Color("ERRatingEasy")

    let shadow = Color("ERShadow")
    let scrim = Color("ERScrim")

    /// 熱力圖 5 階（少 → 多）
    var heat: [Color] { [fill, outlineStrong, mid, textSecondary, text] }

    /// 熟練度：已熟悉／學習中／新卡
    var mastered: Color { text }
    var learning: Color { mid }
    var fresh: Color { outlineStrong }
}

// MARK: - 尺寸

enum Theme {
    /// 圓角一律 .continuous
    enum Radius {
        static let chip: CGFloat = 6
        static let tile: CGFloat = 10
        static let card: CGFloat = 14
        static let tileLarge: CGFloat = 14
        static let tileHero: CGFloat = 22
        static let rating: CGFloat = 22
        static let flashCard: CGFloat = 28
    }

    enum Spacing {
        /// 頁面左右邊距
        static let page: CGFloat = 20
        /// 區塊之間
        static let stack: CGFloat = 10
        /// 區塊標題上方多出的距離
        static let sectionTop: CGFloat = 14
        static let card: CGFloat = 14
        static let cardLarge: CGFloat = 16
        static let row: CGFloat = 12
    }
}

// MARK: - 字級（全部跟著 Dynamic Type 縮放）

extension Font {
    /// 區塊標題、標籤：等寬小字
    static let erLabel = Font.caption2.monospaced()
    /// 數字、詞性、音標
    static let erMono = Font.footnote.monospaced()
    static let erMonoSmall = Font.caption.monospaced()
}

/// 大數字（例如「52 張到期」的 52）：固定設計尺寸，但會跟著 Dynamic Type 等比例放大
struct ScaledNumberFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight

    init(size: CGFloat, relativeTo style: Font.TextStyle, weight: Font.Weight) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight
    }

    func body(content: Content) -> some View {
        content
            .font(.system(size: size, weight: weight))
            .monospacedDigit()
    }
}

extension View {
    func numberFont(_ size: CGFloat, relativeTo style: Font.TextStyle = .largeTitle, weight: Font.Weight = .bold) -> some View {
        modifier(ScaledNumberFont(size: size, relativeTo: style, weight: weight))
    }
}

// MARK: - 內容卡片

struct ERCardModifier: ViewModifier {
    var padding: CGFloat
    var elevated: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.er.surface, in: shape)
            .overlay(shape.strokeBorder(Color.er.outline, lineWidth: 1))
            // 深色模式的 shadow 色是全透明，靠 surface 分層
            .shadow(color: elevated ? Color.er.shadow : Color.clear, radius: 1, y: 1)
    }
}

extension View {
    /// Android 版／設計稿的白底卡片：圓角 14、1pt 邊框、淺色模式有極淡陰影
    func erCard(padding: CGFloat = Theme.Spacing.card, elevated: Bool = false) -> some View {
        modifier(ERCardModifier(padding: padding, elevated: elevated))
    }

    /// 頁面背景（List／Form 也用這個，要搭配 .scrollContentBackground(.hidden)）
    func erPageBackground() -> some View {
        background(Color.er.background.ignoresSafeArea())
    }
}

// MARK: - 卡片裡的捲動區：上下柔和淡出

/// 卡片裡的 ScrollView 沒有系統列，系統的 soft 邊緣不會出現，用遮罩做同樣的效果。
/// 只有那一側還有內容時才淡出：停在最上面時上緣不淡、捲到底時下緣不淡，不會蓋到字
struct SoftScrollEdges: ViewModifier {
    var axis: Axis = .vertical
    var length: CGFloat = 22

    @State private var edges = Edges()

    private struct Edges: Equatable {
        var leading = false
        var trailing = false
    }

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Edges.self) { geometry in
                let vertical = axis == .vertical
                let offset = vertical ? geometry.contentOffset.y : geometry.contentOffset.x
                let insetStart = vertical ? geometry.contentInsets.top : geometry.contentInsets.leading
                let insetEnd = vertical ? geometry.contentInsets.bottom : geometry.contentInsets.trailing
                let visible = vertical ? geometry.containerSize.height : geometry.containerSize.width
                let total = vertical ? geometry.contentSize.height : geometry.contentSize.width
                return Edges(leading: offset + insetStart > 1, trailing: offset + visible < total + insetEnd - 1)
            } action: { _, value in
                withAnimation(.easeOut(duration: 0.15)) { edges = value }
            }
            .mask { mask }
    }

    @ViewBuilder
    private var mask: some View {
        let start = LinearGradient(
            colors: [Color.er.text.opacity(edges.leading ? 0 : 1), Color.er.text],
            startPoint: axis == .vertical ? .top : .leading,
            endPoint: axis == .vertical ? .bottom : .trailing
        )
        let end = LinearGradient(
            colors: [Color.er.text, Color.er.text.opacity(edges.trailing ? 0 : 1)],
            startPoint: axis == .vertical ? .top : .leading,
            endPoint: axis == .vertical ? .bottom : .trailing
        )
        if axis == .vertical {
            VStack(spacing: 0) {
                start.frame(height: length)
                Rectangle()
                end.frame(height: length)
            }
        } else {
            HStack(spacing: 0) {
                start.frame(width: length)
                Rectangle()
                end.frame(width: length)
            }
        }
    }
}

extension View {
    /// 用在卡片裡的 ScrollView
    func softScrollEdges(_ axis: Axis = .vertical, length: CGFloat = 22) -> some View {
        modifier(SoftScrollEdges(axis: axis, length: length))
    }
}
