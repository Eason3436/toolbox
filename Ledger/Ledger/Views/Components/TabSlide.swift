import SwiftUI

/// 點分頁列切換時，新的頁面從左或右滑進來（保留系統原生的分頁列）。
/// 分頁每次出現都會觸發 onAppear，用關鍵影格先把頁面放到旁邊，再用彈簧滑回原位。
struct TabSlideIn: ViewModifier {
    /// 新分頁在舊分頁右邊時為 true（從右邊滑進來）
    var forward: Bool
    /// 第一次出現（App 剛打開）不要滑
    var enabled: Bool
    @State private var trigger = 0

    func body(content: Content) -> some View {
        content
            .keyframeAnimator(initialValue: SlideValue(), trigger: trigger) { view, v in
                view
                    .offset(x: v.x)
                    .opacity(v.opacity)
            } keyframes: { _ in
                let start: CGFloat = forward ? 140 : -140
                KeyframeTrack(\.x) {
                    LinearKeyframe(start, duration: 0)
                    SpringKeyframe(0, duration: 0.42, spring: .smooth(duration: 0.42))
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(0.4, duration: 0)
                    LinearKeyframe(1, duration: 0.22)
                }
            }
            .onAppear {
                if enabled { trigger += 1 }
            }
    }

    struct SlideValue {
        var x: CGFloat = 0
        var opacity: Double = 1
    }
}

extension View {
    func tabSlideIn(forward: Bool, enabled: Bool) -> some View {
        modifier(TabSlideIn(forward: forward, enabled: enabled))
    }
}
