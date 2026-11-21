import SwiftUI

@main
struct DrivePlayerApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            Tab("首頁", systemImage: "house.fill") {
                NavigationStack {
                    ContentUnavailableView("尚未加入媒體庫", systemImage: "film.stack", description: Text("到「設定」登入 Google 並選擇資料夾"))
                        .navigationTitle("DrivePlayer")
                }
            }
            Tab("設定", systemImage: "gearshape.fill") {
                NavigationStack {
                    List {
                        LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-")
                    }
                    .navigationTitle("設定")
                }
            }
        }
    }
}
