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
    case accounts, entries, calendar, bills, assets

    var symbol: String {
        switch self {
        case .accounts: "creditcard.fill"
        case .entries: "cart.fill"
        case .calendar: "square.grid.3x3.fill"
        case .bills: "calendar.badge.clock"
        case .assets: "briefcase.fill"
        }
    }

    var label: String {
        switch self {
        case .accounts: "帳戶"
        case .entries: "記帳"
        case .calendar: "日曆"
        case .bills: "帳單"
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
    @Namespace private var addNS

    var body: some View {
        TabView(selection: $tab) {
            ForEach(AppTab.allCases, id: \.self) { t in
                Tab(t.label, systemImage: t.symbol, value: t) {
                    page(t)
                        .toolbarVisibility(.hidden, for: .tabBar)
                        // 預留下方玻璃分頁列的高度，捲到底時卡片和按鈕不會被蓋住
                        .safeAreaPadding(.bottom, 70)
                }
            }
        }
        // 系統字級調很大時，卡片裡的字也不會跟著無限放大
        .dynamicTypeSize(...DynamicTypeSize.large)
        .overlay(alignment: .bottom) {
            ZStack(alignment: .bottom) {
                // 分頁列後面的淡出漸層：捲動時字和卡片在這裡慢慢淡掉，不會跟玻璃列疊在一起
                LinearGradient(stops: [
                    .init(color: Color(.systemGroupedBackground).opacity(0), location: 0),
                    .init(color: Color(.systemGroupedBackground).opacity(0.85), location: 0.45),
                    .init(color: Color(.systemGroupedBackground), location: 1),
                ], startPoint: .top, endPoint: .bottom)
                .frame(height: 120)
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)

                GlassTabBar(tab: $tab, addNS: addNS) { showAdd = true }
            }
            .ignoresSafeArea(.keyboard)
        }
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
        case .entries: EntriesView()
        case .calendar: CalendarView()
        case .bills: BillsView()
        case .assets: AssetsView()
        }
    }

    @State private var savedSummary: SavedEntrySummary?

    @ViewBuilder
    private var addSheet: some View {
        switch tab {
        case .bills: BillEditor(bill: nil)
        case .assets: AssetEditor(asset: nil)
        default: EntryEditor(entry: nil)
        }
    }
}

/// 自訂玻璃分頁列：左邊分頁膠囊，右邊獨立的圓形 ＋
struct GlassTabBar: View {
    @Binding var tab: AppTab
    var addNS: Namespace.ID
    var onAdd: () -> Void
    @Namespace private var ns
    @State private var addBounce = 0

    var body: some View {
        GlassEffectContainer(spacing: 14) {
            HStack(spacing: 14) {
                TabStrip(tab: $tab)
                .padding(5)
                .glassEffect(.regular, in: .capsule)

                Button {
                    addBounce += 1
                    onAdd()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 26, weight: .medium))
                        .symbolEffect(.bounce, value: addBounce)
                        .foregroundStyle(.primary)
                        .frame(width: 64, height: 64)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .matchedTransitionSource(id: "add", in: addNS)
                .accessibilityLabel("新增")
            }
        }
        .padding(.horizontal, 18)
        // 往下移，靠近底部的橫條
        .padding(.bottom, -14)
        .sensoryFeedback(.selection, trigger: tab)
        .sensoryFeedback(.impact(weight: .medium), trigger: addBounce)
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


/// 分頁膠囊：點一下切換；按住會浮起一顆液態玻璃透鏡，可以左右拖到想去的分頁再放手
struct TabStrip: View {
    @Binding var tab: AppTab

    @State private var width: CGFloat = 0
    @State private var dragX: CGFloat?
    @State private var pressed = false

    private let tabs = AppTab.allCases
    private var seg: CGFloat { max(width / CGFloat(tabs.count), 1) }

    private func index(at x: CGFloat) -> Int {
        min(max(Int(x / seg), 0), tabs.count - 1)
    }
    private var currentIndex: Int { tabs.firstIndex(of: tab) ?? 0 }
    private var hoverIndex: Int { dragX.map(index(at:)) ?? currentIndex }
    private var lensCenter: CGFloat {
        if let x = dragX { return min(max(x, seg / 2), width - seg / 2) }
        return seg * (CGFloat(currentIndex) + 0.5)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // 選取塊／透鏡
            ZStack {
                Capsule().fill(Color.primary.opacity(0.08))
                    .opacity(pressed ? 0 : 1)
                Capsule().fill(Color.white.opacity(0.001))
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .overlay(Capsule().strokeBorder(.white.opacity(0.55), lineWidth: 0.8))
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                    .opacity(pressed ? 1 : 0)
            }
            .frame(width: seg, height: 54)
            .scaleEffect(pressed ? CGSize(width: 1.22, height: 1.16) : CGSize(width: 1, height: 1))
            .offset(x: lensCenter - seg / 2)

            HStack(spacing: 0) {
                ForEach(Array(tabs.enumerated()), id: \.element) { i, t in
                    Image(systemName: t.symbol)
                        .font(.system(size: 21, weight: .semibold))
                        .symbolEffect(.bounce.down, value: tab == t)
                        .foregroundStyle(hoverIndex == i ? Color.accentColor : Color.primary)
                        .scaleEffect(pressed && hoverIndex == i ? 1.18 : 1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .accessibilityElement()
                        .accessibilityLabel(t.label)
                        .accessibilityAddTraits(tab == t ? [.isButton, .isSelected] : .isButton)
                        .accessibilityAction { tab = t }
                }
            }
        }
        .frame(height: 54)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .contentShape(.capsule)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if !pressed {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.65)) { pressed = true }
                    }
                    withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.82)) {
                        dragX = g.location.x
                    }
                }
                .onEnded { g in
                    let i = index(at: g.location.x)
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.7)) {
                        tab = tabs[i]
                        dragX = nil
                        pressed = false
                    }
                }
        )
        .sensoryFeedback(.selection, trigger: hoverIndex)
    }
}
