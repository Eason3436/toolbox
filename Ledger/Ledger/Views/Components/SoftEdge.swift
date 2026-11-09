import SwiftUI
import UIKit

/// 頁面頂部的柔和邊緣：往上越來越模糊（模糊半徑隨位置變大），再疊一層淡淡的底色讓標題清楚。
/// 用系統的 variableBlur 濾鏡；拿不到時退回「材質＋漸層遮罩」
struct SoftTopEdge: ViewModifier {
    var extra: CGFloat = 24

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
    func softTopEdge(extra: CGFloat = 24) -> some View { modifier(SoftTopEdge(extra: extra)) }
}

struct SoftEdgeBlur: View {
    var body: some View {
        ZStack {
            if VariableBlurView.isSupported {
                VariableBlurView(maxRadius: 14)
            } else {
                Rectangle().fill(.regularMaterial)
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.45),
                                                 .init(color: .clear, location: 1)],
                                         startPoint: .top, endPoint: .bottom))
            }
            // 底色：上面濃、往下淡出，跟模糊一起漸變
            LinearGradient(stops: [.init(color: Palette.background.opacity(0.6), location: 0),
                                   .init(color: Palette.background.opacity(0.3), location: 0.5),
                                   .init(color: Palette.background.opacity(0), location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
    }
}

/// 從上到下模糊半徑由大變小的模糊
struct VariableBlurView: UIViewRepresentable {
    var maxRadius: CGFloat

    static var isSupported: Bool { NSClassFromString("CAFilter") != nil }

    func makeUIView(context: Context) -> VariableBlurUIView { VariableBlurUIView(maxRadius: maxRadius) }
    func updateUIView(_ uiView: VariableBlurUIView, context: Context) {}
}

final class VariableBlurUIView: UIVisualEffectView {
    init(maxRadius: CGFloat) {
        super.init(effect: UIBlurEffect(style: .regular))
        guard let cls = NSClassFromString("CAFilter") as? NSObject.Type,
              let made = cls.perform(NSSelectorFromString("filterWithType:"), with: "variableBlur")?.takeUnretainedValue(),
              let filter = made as? NSObject,
              let mask = Self.maskImage() else { return }
        filter.setValue(maxRadius, forKey: "inputRadius")
        filter.setValue(mask, forKey: "inputMaskImage")
        filter.setValue(true, forKey: "inputNormalizeEdges")
        // 第一層是背景模糊，換成可變模糊；其他層（色調）拿掉
        subviews.first?.layer.filters = [filter]
        for v in subviews.dropFirst() { v.alpha = 0 }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let window, let backdrop = subviews.first?.layer else { return }
        backdrop.setValue(window.screen.scale, forKey: "scale")
    }

    /// 上面全黑（最模糊）、往下漸漸透明（不模糊）
    private static func maskImage() -> CGImage? {
        let h = 100
        let space = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: nil, width: 1, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return nil }
        for y in 0..<h {
            // y = 0 是圖片底部；越往上越不透明，用平滑曲線
            let t = CGFloat(y) / CGFloat(h - 1)
            let a = t * t * (3 - 2 * t)
            ctx.setFillColor(gray: 0, alpha: a)
            ctx.fill(CGRect(x: 0, y: y, width: 1, height: 1))
        }
        return ctx.makeImage()
    }
}
