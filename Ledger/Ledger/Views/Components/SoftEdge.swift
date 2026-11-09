import SwiftUI

/// 頁面頂部的柔和邊緣：標題列底下是模糊＋底色，往下慢慢淡掉，沒有硬邊。
/// 只用 SwiftUI 的材質和漸層遮罩（之前用私有的可變模糊濾鏡，在部分系統版本會變成一整塊硬邊）
struct SoftTopEdge: ViewModifier {
    var extra: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .scrollEdgeEffectHidden(true, for: .top)
            .overlay(alignment: .top) {
                GeometryReader { g in
                    SoftEdgeBlur()
                        .frame(height: g.safeAreaInsets.top + extra)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .ignoresSafeArea(edges: .top)
                }
                .allowsHitTesting(false)
            }
    }
}

extension View {
    func softTopEdge(extra: CGFloat = 16) -> some View { modifier(SoftTopEdge(extra: extra)) }
}

struct SoftEdgeBlur: View {
    var body: some View {
        ZStack {
            // 兩層材質，遮罩長度不同，疊起來上面比較糊、往下越來越清楚
            Rectangle().fill(.ultraThinMaterial)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.55),
                                             .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
            Rectangle().fill(.ultraThinMaterial)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.3),
                                             .init(color: .clear, location: 0.75)],
                                     startPoint: .top, endPoint: .bottom))
            // 底色：上面濃、往下淡出，讓標題清楚
            LinearGradient(stops: [.init(color: Palette.background.opacity(0.75), location: 0),
                                   .init(color: Palette.background.opacity(0.45), location: 0.5),
                                   .init(color: Palette.background.opacity(0), location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
    }
}
