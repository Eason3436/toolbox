import SwiftUI
import Photos

enum AppTab: Hashable {
    case photos
    case videos
    case stats
}

struct RootView: View {
    @Environment(DeletionQueue.self) private var queue
    @State private var tab: AppTab = .photos
    @State private var status = PhotoLibrary.authorizationStatus()

    var body: some View {
        Group {
            switch status {
            case .authorized, .limited:
                tabs
            case .notDetermined:
                Color.clear
                    .task { status = await PhotoLibrary.requestAccess() }
            default:
                AccessDeniedView()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // 從「設定」改完權限回來，重新讀一次
            status = PhotoLibrary.authorizationStatus()
        }
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            Tab("照片", systemImage: "photo.on.rectangle", value: AppTab.photos) {
                NavigationStack {
                    PhotosView(isLimited: status == .limited)
                }
            }
            Tab("影片", systemImage: "play.rectangle", value: AppTab.videos) {
                VideosView(isActive: tab == .videos)
            }
            Tab("統計", systemImage: "chart.bar", value: AppTab.stats) {
                NavigationStack {
                    StatsView()
                }
            }
        }
        .overlay(alignment: .top) {
            ResultBanner()
        }
    }
}

/// 沒有相簿權限時的畫面
private struct AccessDeniedView: View {
    var body: some View {
        ContentUnavailableView {
            Label("需要相簿權限", systemImage: "photo.badge.exclamationmark")
        } description: {
            Text("到「設定」把照片權限改成「完整取用」，才能整理相簿。")
        } actions: {
            Button("打開設定") { AppLinks.openSettings() }
                .buttonStyle(.borderedProminent)
        }
    }
}

/// 刪除完成後在上方短暫顯示結果
private struct ResultBanner: View {
    @Environment(DeletionQueue.self) private var queue

    var body: some View {
        if let message = queue.banner {
            Label(message.text, systemImage: message.systemImage)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: message.id) {
                    try? await Task.sleep(for: .seconds(2.5))
                    withAnimation(.snappy) { queue.banner = nil }
                }
                .accessibilityAddTraits(.isStaticText)
        }
    }
}

enum AppLinks {
    @MainActor
    static func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

#Preview("淺色") {
    RootView()
        .environment(DeletionQueue())
        .modelContainer(PreviewData.container)
}

#Preview("深色") {
    RootView()
        .environment(DeletionQueue())
        .modelContainer(PreviewData.container)
        .preferredColorScheme(.dark)
}
