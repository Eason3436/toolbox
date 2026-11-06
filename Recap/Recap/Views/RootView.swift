import SwiftUI

struct RootView: View {
    @Environment(Router.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        // 「減少動態效果」開啟時，彈性與位移動畫改成短暫淡入淡出
        .transaction { transaction in
            if reduceMotion, transaction.animation != nil { transaction.animation = .easeInOut(duration: 0.15) }
        }
        .sheet(isPresented: $router.showQuickRecap) {
            QuickRecapSheet()
        }
    }
}
