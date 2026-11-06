import SwiftUI

struct RootView: View {
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            Tab("今天", systemImage: "sparkles", value: Router.Tab.today) {
                TodayView()
            }
            Tab("課堂", systemImage: "captions.bubble", value: Router.Tab.lecture) {
                LectureHomeView()
            }
            Tab("紀錄", systemImage: "calendar", value: Router.Tab.history) {
                HistoryView()
            }
            Tab("設定", systemImage: "gearshape", value: Router.Tab.settings) {
                SettingsView()
            }
        }
        .sensoryFeedback(.selection, trigger: router.tab)
        .sheet(isPresented: $router.showQuickRecap) {
            QuickRecapSheet()
        }
    }
}
