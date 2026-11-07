import SwiftUI
import SwiftData

@main
struct LedgerApp: App {
    init() {
        Store.seedIfNeeded()
        LedgerShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(Store.container)
    }
}

enum AppTab: Hashable {
    case accounts, entries, bills, assets, add
}

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: AppTab = .accounts
    @State private var lastTab: AppTab = .accounts
    @State private var showAdd = false

    var body: some View {
        TabView(selection: Binding(
            get: { tab },
            set: { newValue in
                if newValue == .add {
                    showAdd = true
                } else {
                    tab = newValue
                    lastTab = newValue
                }
            }
        )) {
            Tab("帳戶", systemImage: "creditcard.fill", value: AppTab.accounts) {
                AccountsView()
            }
            Tab("記帳", systemImage: "cart.fill", value: AppTab.entries) {
                EntriesView()
            }
            Tab("帳單", systemImage: "calendar.badge.clock", value: AppTab.bills) {
                BillsView()
            }
            Tab("資產", systemImage: "briefcase.fill", value: AppTab.assets) {
                AssetsView()
            }
            // 分頁列右邊獨立的圓形「＋」按鈕
            Tab("新增", systemImage: "plus", value: AppTab.add, role: .search) {
                Color.clear
            }
        }
        .tabBarMinimizeBehavior(.never)
        .sheet(isPresented: $showAdd) {
            addSheet
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                BillService.processAutoPay(context: context)
            }
        }
    }

    @ViewBuilder
    private var addSheet: some View {
        switch tab {
        case .bills:
            BillEditor(bill: nil)
        case .assets:
            AssetEditor(asset: nil)
        default:
            EntryEditor(entry: nil)
        }
    }
}
