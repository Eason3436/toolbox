import SwiftUI
import os

/// 全 App 共用的 Logger。
let appLog = Logger(subsystem: "com.eason3436.screenshots", category: "app")

@main
struct ScreenshotsApp: App {
    @State private var library = PhotoSyncService()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
        }
    }
}
