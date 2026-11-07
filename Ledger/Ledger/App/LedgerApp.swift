import SwiftUI
import SwiftData
import LocalAuthentication

@main
struct LedgerApp: App {
    init() {
        Store.seedIfNeeded()
        CategoryStyle.migrateIfNeeded()
        LedgerShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(Store.container)
    }
}

enum AppTab: String, CaseIterable, Hashable {
    case accounts, entries, analysis, bills, assets

    var symbol: String {
        switch self {
        case .accounts: "house.fill"
        case .entries: "list.bullet.rectangle.portrait.fill"
        case .analysis: "chart.pie.fill"
        case .bills: "calendar.badge.clock"
        case .assets: "briefcase.fill"
        }
    }

    var label: String {
        switch self {
        case .accounts: "首頁"
        case .entries: "明細"
        case .analysis: "分析"
        case .bills: "規劃"
        case .assets: "資產"
        }
    }
}

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("lockEnabled") private var lockEnabled = false
    @State private var tab: AppTab = AppTab(rawValue: UserDefaults.standard.string(forKey: HomeLayout.startTabKey) ?? "") ?? .accounts
    @State private var showAdd = false
    @State private var locked = UserDefaults.standard.bool(forKey: "lockEnabled")
    @State private var openResult: String?
    @State private var shortcutResult: String?

    var body: some View {
        // 系統原生 Liquid Glass 分頁列（按住可以左右拖曳切換）；新增是浮在分頁列右上方的小按鈕
        TabView(selection: $tab) {
            ForEach(AppTab.allCases, id: \.self) { t in
                Tab(t.label, systemImage: t.symbol, value: t) {
                    page(t)
                }
            }
        }
        .environment(\.openAddEntry, { start in
            addStart = start
            showAdd = true
        })
        .overlay(alignment: .bottomTrailing) {
            AddFloatingButton { addStart = .normal; showAdd = true }
                .padding(.trailing, 20)
                .padding(.bottom, 64)
                .ignoresSafeArea(.keyboard)
        }
        // 系統字級調很大時，卡片裡的字也不會跟著無限放大
        .dynamicTypeSize(...DynamicTypeSize.large)
        .sensoryFeedback(.selection, trigger: tab)
        .sheet(isPresented: $showAdd) {
            // 一般的整頁卡片滑上／滑下：往下拉時整張卡片跟著手指走，不會縮成小方塊、內容也不會被裁掉
            addSheet
                .environment(\.entrySavedHandler, { summary in
                    // 表單直接消失（不滑下去），換成卡片吸進動態島的動畫
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) { showAdd = false }
                    savedSummary = summary
                })
                .dynamicTypeSize(...DynamicTypeSize.large)
                // 底色交給系統的卡片形狀畫（四角圓角），往下拉時底部不會露出直角
                .presentationBackground(Color(.systemGroupedBackground))
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(38)
                .presentationBackgroundInteraction(.disabled)
        }
        .overlay {
            if let s = savedSummary {
                IslandSuckView(summary: s) { savedSummary = nil }
                    .id(s.id)
            }
        }
        .overlay {
            if locked { LockView { locked = false } .transition(.opacity) }
        }
        .animation(.easeInOut(duration: 0.25), value: locked)
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active:
                BillService.processAutoPay(context: context)
                // 裝在 LiveContainer 時，捷徑動作會把記帳請求放進收件匣
                Task {
                    let msgs = await LiveContainerInbox.process()
                    if !msgs.isEmpty { shortcutResult = msgs.joined(separator: "\n") }
                }
            case .background:
                if lockEnabled { locked = true }
            default:
                break
            }
        }
        .onOpenURL { url in
            openResult = FileImport.handle(url)
        }
        .alert("匯入", isPresented: Binding(get: { openResult != nil }, set: { if !$0 { openResult = nil } })) {
            Button("好") { openResult = nil }
        } message: {
            Text(openResult ?? "")
        }
        .alert("捷徑記帳", isPresented: Binding(get: { shortcutResult != nil }, set: { if !$0 { shortcutResult = nil } })) {
            Button("好") { shortcutResult = nil }
        } message: {
            Text(shortcutResult ?? "")
        }
    }

    @ViewBuilder
    private func page(_ t: AppTab) -> some View {
        switch t {
        case .accounts: AccountsView()
        case .entries: LedgerListView()
        case .analysis: NavigationStack { SpendingInsightView() }
        case .bills: BillsView()
        case .assets: AssetsView()
        }
    }

    @State private var savedSummary: SavedEntrySummary?
    @State private var addStart: AddStart = .normal

    @ViewBuilder
    private var addSheet: some View {
        if addStart != .normal {
            EntryEditor(entry: nil, start: addStart)
        } else {
            switch tab {
            case .bills: BillEditor(bill: nil)
            case .assets: AssetEditor(asset: nil)
            default: EntryEditor(entry: nil)
            }
        }
    }
}

/// Face ID 鎖定畫面
struct LockView: View {
    var onUnlock: () -> Void
    @State private var error: String?

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "lock.fill").font(.system(size: 44)).foregroundStyle(.secondary)
                Text("記帳已鎖定").font(.title2.weight(.semibold))
                Button {
                    authenticate()
                } label: {
                    Label("用 Face ID 解鎖", systemImage: "faceid")
                        .padding(.horizontal, 10).padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                if let error { Text(error).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .onAppear(perform: authenticate)
    }

    private func authenticate() {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            onUnlock()
            return
        }
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "解鎖記帳") { ok, e in
            DispatchQueue.main.async {
                if ok { onUnlock() } else { error = e?.localizedDescription }
            }
        }
    }
}


/// 分頁列右上方的小玻璃 ＋
struct AddFloatingButton: View {
    var action: () -> Void
    @State private var bounce = 0

    var body: some View {
        Button {
            bounce += 1
            action()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .semibold))
                .symbolEffect(.bounce, value: bounce)
                .foregroundStyle(.primary)
                .frame(width: 52, height: 52)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .sensoryFeedback(.impact(weight: .medium), trigger: bounce)
        .accessibilityLabel("新增")
    }
}
