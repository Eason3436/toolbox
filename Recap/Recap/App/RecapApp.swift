import SwiftUI

@main
struct RecapApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    private let model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model.store)
                .environment(model.settings)
                .environment(model.queue)
                .environment(model.recorder)
                .environment(model.router)
                .environment(model.quickRecap)
                .onOpenURL { model.handle($0) }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active: model.didBecomeActive()
            case .background: model.didEnterBackground()
            default: break
            }
        }
    }
}
