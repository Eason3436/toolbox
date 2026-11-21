import SwiftUI

/// 畫面上方的狀態提示：斷網、Google 登入失效
struct StatusBanner: View {
    @Environment(AppServices.self) private var services

    private var message: (text: String, icon: String)? {
        if !services.network.isOnline {
            return ("沒有網路連線，暫時無法瀏覽與播放", "wifi.slash")
        }
        if services.auth.sessionExpired {
            return ("Google 登入已失效，請到「設定」重新登入", "person.crop.circle.badge.exclamationmark")
        }
        return nil
    }

    var body: some View {
        if let message {
            Label(message.text, systemImage: message.icon)
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.orange.gradient, in: Capsule())
                .foregroundStyle(.black)
                .padding(.top, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityAddTraits(.isStaticText)
        }
    }
}

/// 載入中的骨架列
struct SkeletonRows: View {
    var count = 6

    var body: some View {
        List {
            ForEach(0..<count, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 6) {
                    Text("影片檔名佔位文字 2160p")
                    Text("12.3 GB・3840×2160").font(.caption)
                }
                .redacted(reason: .placeholder)
            }
        }
        .allowsHitTesting(false)
        .accessibilityLabel("讀取中")
    }
}
