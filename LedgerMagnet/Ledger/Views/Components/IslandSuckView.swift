import SwiftUI
import UIKit

/// 存檔後要飛進動態島的那張卡片內容
struct SavedEntrySummary: Equatable, Identifiable {
    var id = UUID()
    var title: String
    var amountText: String
    var symbol: String
    var color: Color
    var income: Bool
}

/// 記一筆按下打勾後由 App 接手：關掉表單、播放吸進動態島的動畫
struct EntrySavedHandlerKey: EnvironmentKey {
    static let defaultValue: ((SavedEntrySummary) -> Void)? = nil
}

extension EnvironmentValues {
    var entrySavedHandler: ((SavedEntrySummary) -> Void)? {
        get { self[EntrySavedHandlerKey.self] }
        set { self[EntrySavedHandlerKey.self] = newValue }
    }
}

/// 卡片縮小、變成黑色膠囊、吸進動態島，島上短暫展開顯示「已記帳」後收回
struct IslandSuckView: View {
    var summary: SavedEntrySummary
    var onFinish: () -> Void

    private enum Stage { case card, flying, island, expanded, gone }
    @State private var stage: Stage = .card
    @State private var bump = 0
    @State private var faded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 有動態島的機型，上方安全區域大約 54pt 以上
    private var topInset: CGFloat {
        let scene = UIApplication.shared.connectedScenes.first { $0.activationState == .foregroundActive } as? UIWindowScene
        return scene?.keyWindow?.safeAreaInsets.top ?? 0
    }
    private var hasIsland: Bool { topInset >= 51 }

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width, H = geo.size.height
            let islandW: CGFloat = 126, islandH: CGFloat = 37
            let islandY: CGFloat = hasIsland ? 11 + islandH / 2 : 24
            let frame: (w: CGFloat, h: CGFloat, y: CGFloat, r: CGFloat) = {
                switch stage {
                case .card: return (W - 24, min(300, H * 0.38), H * 0.42, 40)
                case .flying: return (islandW * 1.3, islandH * 1.3, islandY + 30, islandH * 0.65)
                case .island: return (islandW, islandH, islandY, islandH / 2)
                // 只比島大一點，不會蓋到兩側的狀態列
                case .expanded: return (islandW + 24, islandH + 6, islandY + 3, (islandH + 6) / 2)
                case .gone: return (islandW, islandH, islandY, islandH / 2)
                }
            }()

            ZStack {
                RoundedRectangle(cornerRadius: frame.r, style: .continuous)
                    .fill(stage == .card ? Color(.secondarySystemGroupedBackground) : Color.black)
                    .shadow(color: .black.opacity(stage == .card ? 0.18 : 0), radius: 24, y: 10)

                // 卡片內容：飛起來時跟著縮小、淡出
                VStack(spacing: 10) {
                    CategoryIcon(symbol: summary.symbol, color: summary.color, size: 56)
                    Text(summary.title).font(.title3.weight(.semibold)).lineLimit(1)
                    Text(summary.amountText)
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                        .foregroundStyle(summary.income ? .green : .primary)
                        .lineLimit(1).minimumScaleFactor(0.5)
                }
                .padding(24)
                .frame(width: W - 24)
                .scaleEffect(stage == .card ? 1 : 0.2)
                .opacity(stage == .card ? 1 : 0)
                .blur(radius: stage == .card ? 0 : 8)

                // 島上展開時：只有一個綠色小勾
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white, .green)
                    .symbolEffect(.bounce, value: bump)
                    .opacity(stage == .expanded ? 1 : 0)
                    .scaleEffect(stage == .expanded ? 1 : 0.4)
            }
            .frame(width: frame.w, height: frame.h)
            .clipShape(RoundedRectangle(cornerRadius: frame.r, style: .continuous))
            .position(x: W / 2, y: frame.y)
            .opacity(stage == .gone && !hasIsland ? 0 : 1)
        }
        .opacity(faded ? 0 : 1)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .task { await run() }
    }

    private func run() async {
        // 減少動態效果：不飛，只淡出，觸覺回饋照樣給
        if reduceMotion {
            Haptics.shared.islandSuck()
            try? await Task.sleep(for: .milliseconds(500))
            withAnimation(.easeOut(duration: 0.2)) { faded = true }
            try? await Task.sleep(for: .milliseconds(200))
            onFinish()
            return
        }
        // 整段震動一次排好，跟動畫的時間點對齊
        Haptics.shared.islandSuck()
        try? await Task.sleep(for: .milliseconds(60))
        // 先往上加速縮小
        withAnimation(.timingCurve(0.5, 0, 0.85, 0.4, duration: 0.32)) { stage = .flying }
        try? await Task.sleep(for: .milliseconds(300))
        // 吸進島裡，帶一點回彈
        withAnimation(.spring(response: 0.28, dampingFraction: 0.62)) { stage = .island }
        try? await Task.sleep(for: .milliseconds(220))
        // 島展開顯示「已記帳」
        bump += 1
        withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) { stage = .expanded }
        try? await Task.sleep(for: .milliseconds(800))
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { stage = .gone }
        try? await Task.sleep(for: .milliseconds(400))
        onFinish()
    }
}
