import SwiftUI

// MARK: - 被磁鐵吸的元素

/// 磁鐵靠近時，元素往磁鐵的方向被吸過去；拿開就彈回原位
struct MagneticEffect: ViewModifier {
    var force: Double = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let field = MagnetField.shared
        let on: Bool = field.enabled && !reduceMotion
        let magnet: CGPoint? = on ? field.point : nil
        let pull: Double = on ? field.pull : 0
        let k: Double = force * field.force
        content
            .animation(.interactiveSpring(response: 0.32, dampingFraction: 0.52)) { view in
                view.visualEffect { v, proxy in
                    let frame: CGRect = proxy.frame(in: .global)
                    let s: Double = MagnetMath.scale(frame: frame, magnet: magnet, pull: pull, force: k)
                    return v
                        .scaleEffect(s)
                        .offset(MagnetMath.offset(frame: frame, magnet: magnet, pull: pull, force: k))
                }
            }
    }
}

extension View {
    /// 讓這個元素會被磁鐵吸
    func magnetic(_ force: Double = 1) -> some View { modifier(MagneticEffect(force: force)) }
}

// MARK: - 磁鐵位置的光暈（最上層，不擋點擊）

struct MagnetGlow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let field = MagnetField.shared
        GeometryReader { proxy in
            let size: CGSize = proxy.size
            ZStack {
                if field.enabled, let p = field.point {
                    let r: Double = 90 + 120 * field.pull
                    Circle()
                        .fill(RadialGradient(colors: [Color.accentColor.opacity(0.45 * field.presence), .clear],
                                             center: .center, startRadius: 0, endRadius: r))
                        .frame(width: r * 2, height: r * 2)
                        .position(p)
                        .blendMode(.plusLighter)
                        .animation(reduceMotion ? nil : .interactiveSpring(response: 0.3, dampingFraction: 0.8), value: p)
                }
            }
            .frame(width: size.width, height: size.height)
            .onAppear { field.screenSize = size }
            .onChange(of: size) { _, s in field.screenSize = s }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        // 磁鐵吸住、放開時輕輕震一下
        .sensoryFeedback(trigger: field.presence > 0.5) { _, now in
            now ? .impact(weight: .light, intensity: 0.7) : .impact(flexibility: .soft, intensity: 0.4)
        }
    }
}

// MARK: - 開啟／關閉感測器

/// 套在最外層：App 在前景時才讀磁力計
struct MagnetLifecycle: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .overlay { MagnetGlow() }
            .onChange(of: scenePhase, initial: true) { _, phase in
                if phase == .active { MagnetField.shared.start() } else { MagnetField.shared.stop() }
            }
    }
}
