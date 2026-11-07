import SwiftUI

/// 截圖風格的標題：「帳單 ⌄」放在左上，跟右邊的玻璃按鈕同一行
struct HeaderTitle<MenuContent: View>: ToolbarContent {
    var title: String
    @ViewBuilder var menu: () -> MenuContent

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                menu()
            } label: {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 30, weight: .heavy))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .contentTransition(.interpolate)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .animation(.snappy, value: title)
            }
        }
        .sharedBackgroundVisibility(.hidden)
    }
}

extension View {
    /// 隱藏系統標題（改用 HeaderTitle），但保留返回按鈕文字
    func ledgerNavigation(_ title: String) -> some View {
        self
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(removing: .title)
            .background(Color(.systemGroupedBackground))
    }
}

/// 卡片出現時由下往上淡入
struct AppearEffect: ViewModifier {
    var delay: Double = 0
    @State private var shown = false
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 18)
            .onAppear {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.85).delay(delay)) { shown = true }
            }
    }
}

extension View {
    func appearEffect(delay: Double = 0) -> some View { modifier(AppearEffect(delay: delay)) }

    /// 按壓時縮小一點
    func pressable() -> some View { buttonStyle(PressableStyle()) }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
