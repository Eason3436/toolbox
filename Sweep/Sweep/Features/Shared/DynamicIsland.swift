import SwiftUI
import Observation
import UIKit

/// 動態島的位置。App 在前景時沒辦法真的控制動態島，
/// 所以在同一個位置畫一顆純黑膠囊蓋上去，看起來就像動態島自己在變大。
enum IslandMetrics {
    /// 沒有動態島的機型回傳 nil（改用往上飛出去）
    @MainActor
    static var frame: CGRect? {
        guard let window = keyWindow else { return nil }
        let top = window.safeAreaInsets.top
        // 有動態島的機型上方安全區域是 59 以上；瀏海機型是 47–50
        guard top >= 59 else { return nil }
        let size = CGSize(width: 125, height: 37)
        // iPhone 16 Pro 之後（安全區域 62）動態島稍微往下
        let y: CGFloat = top >= 62 ? 14 : 11
        return CGRect(x: (window.bounds.width - size.width) / 2, y: y, width: size.width, height: size.height)
    }

    @MainActor
    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }
}

/// 假動態島的狀態：往上拖時慢慢變大，刪除時把照片吞進去
@MainActor
@Observable
final class IslandModel {
    /// 0 = 原本大小，1 = 拖到可以刪除的大小，超過 1 是「吞下去」那一下
    private(set) var progress: CGFloat = 0
    private(set) var isShown = false
    /// 吞下去時顯示待刪除的數量
    private(set) var count = 0

    var isAvailable: Bool { IslandMetrics.frame != nil }

    /// 跟著手指，不加動畫
    func track(_ value: CGFloat) {
        guard isAvailable else { return }
        if value > 0 { isShown = true }
        progress = min(max(value, 0), 1)
    }

    /// 沒刪，縮回去
    func release() {
        guard isShown else { return }
        withAnimation(.spring(duration: 0.35, bounce: 0.25)) {
            progress = 0
        } completion: {
            if self.progress == 0 { self.isShown = false }
        }
    }

    /// 照片飛進來之後：鼓一下再縮回原本大小
    func gulp(count: Int) {
        guard isAvailable else { return }
        self.count = count
        isShown = true
        withAnimation(.spring(duration: 0.18, bounce: 0)) {
            progress = 1.3
        } completion: {
            withAnimation(.spring(duration: 0.55, bounce: 0.35)) {
                self.progress = 0
            } completion: {
                if self.progress == 0 { self.isShown = false }
            }
        }
    }
}

/// 蓋在真的動態島上的黑色膠囊
struct IslandOverlay: View {
    @Environment(IslandModel.self) private var island

    /// 最大時多出來的寬、高
    private let growWidth: CGFloat = 70
    private let growHeight: CGFloat = 18

    var body: some View {
        ZStack(alignment: .topLeading) {
            if island.isShown, let base = IslandMetrics.frame {
                let p = island.progress
                let width = base.width + growWidth * p
                let height = base.height + growHeight * p
                // 純黑是為了跟硬體的動態島接在一起，深色淺色模式都一樣
                Capsule(style: .continuous)
                    .fill(Color.black)
                    .frame(width: width, height: height)
                    .overlay {
                        HStack {
                            Image(systemName: "trash.fill")
                                .foregroundStyle(.red)
                            Spacer(minLength: 0)
                            if island.count > 0 && p > 1 {
                                Text(island.count.formatted())
                                    .foregroundStyle(.white)
                                    .contentTransition(.numericText())
                            }
                        }
                        .font(.footnote.weight(.bold))
                        .padding(.horizontal, 14)
                        // 大到可以放東西才出現，避開中間的鏡頭
                        .opacity(Double(min(max((p - 0.45) / 0.45, 0), 1)))
                    }
                    .offset(x: base.midX - width / 2, y: base.minY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
