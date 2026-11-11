import SwiftUI
import UIKit
import DistortionWavesKit

/// 按下鍵盤上的「記下」後，從那顆鍵往上掃過整張表單的彩色波浪（DistortionWavesKit，MIT）。
/// 表單裡有 TextField、導覽列這些 UIKit 元件，沒辦法直接過 shader，所以先拍一張表單的快照當「前一頁」。
struct SaveWaveRequest: Identifiable {
    let id = UUID()
    /// 按下當下的表單畫面
    var snapshot: UIImage
    /// 「記下」鍵的位置（螢幕座標）
    var source: CGRect
    /// 手指按的位置（螢幕座標）
    var touch: CGPoint
    var summary: SavedEntrySummary
    var detail: String
    var editing: Bool
}

enum SaveWave {
    /// 拍最上層那張卡片（記一筆表單）的畫面
    @MainActor
    static func snapshotTopSheet() -> UIImage? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
              let window = scene.keyWindow,
              var vc = window.rootViewController else { return nil }
        while let p = vc.presentedViewController, !p.isBeingDismissed { vc = p }
        guard let view = vc.view, view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat(for: view.traitCollection)
        return UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: false)
        }
    }

    /// 垂直型：從底部的寬按鈕往上；圓角跟記一筆卡片一樣（RootView 的 presentationCornerRadius）
    static let style: DistortionWaveStyle = {
        var s = DistortionWaveStyle(type: .vertical)
        s.cornerRadius = 38
        return s
    }()
}

/// 蓋在記一筆表單上：快照 → 波浪 → 已記帳收據，結束後呼叫 onDone 關掉表單
struct SaveWaveOverlay: View {
    let request: SaveWaveRequest
    var onDone: () -> Void

    @State private var revealed = false
    @State private var origin: CGPoint?

    var body: some View {
        let o = origin ?? .zero
        ZStack {
            // 波浪進行中兩邊都不接受點擊，這層擋住底下的表單
            Color.black.opacity(0.001)
                .contentShape(.rect)
                .onTapGesture {}
            DistortionWave(
                isRevealed: revealed,
                source: request.source.offsetBy(dx: -o.x, dy: -o.y),
                focus: CGPoint(x: request.touch.x - o.x, y: request.touch.y - o.y),
                style: SaveWave.style,
                onFinish: {
                    Task {
                        try? await Task.sleep(for: .milliseconds(650))
                        onDone()
                    }
                }
            ) {
                Image(uiImage: request.snapshot)
                    .resizable()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Palette.background)
            } revealed: {
                SavedReceiptScreen(summary: request.summary, detail: request.detail, editing: request.editing)
            }
        }
        .ignoresSafeArea()
        .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { newOrigin in
            let first = origin == nil
            origin = newOrigin
            // 量到自己的位置後才送出波浪，起點才會對準按鈕
            if first {
                DispatchQueue.main.async { revealed = true }
            }
        }
        .sensoryFeedback(.success, trigger: revealed)
    }
}

/// 波浪後面的畫面：純 SwiftUI、不透明底色（材質和 UIKit 元件過不了 shader）
struct SavedReceiptScreen: View {
    var summary: SavedEntrySummary
    var detail: String
    var editing: Bool

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white, .green)
            Text(editing ? "已更新" : "已記帳")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                CategoryIcon(symbol: summary.symbol, color: summary.color, size: 60)
                Text(summary.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(summary.amountText)
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .foregroundStyle(summary.income ? .green : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 28)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
            .background(Palette.card, in: .rect(cornerRadius: 28, style: .continuous))
            .padding(.horizontal, 24)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background)
    }
}
