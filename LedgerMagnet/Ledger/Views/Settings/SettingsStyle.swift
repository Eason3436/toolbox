import SwiftUI

// 設定頁的外觀：深色圓角分組、每列左邊一個外框圓角方塊圖示、分組標題粗體

/// 每列左邊的外框圓角方塊圖示
struct SettingsIcon: View {
    var symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(Color.primary.opacity(0.85))
            .frame(width: 36, height: 36)
            .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            }
            .magnetic(1.2)
    }
}

/// 每列的標題：圖示＋文字。直接畫出來，不靠 LabelStyle——Picker、Toggle、按鈕裡的 Label 不會套用 LabelStyle，
/// 按鈕文字也會被染成主題色
struct SettingsRowLabel: View {
    var title: String
    var symbol: String
    init(_ title: String, _ symbol: String) {
        self.title = title
        self.symbol = symbol
    }

    var body: some View {
        HStack(spacing: 14) {
            SettingsIcon(symbol: symbol)
            Text(title).foregroundStyle(.primary)
        }
        // 分隔線從圖示下方開始，不會穿出卡片
        .alignmentGuide(.listRowSeparatorLeading) { d in d[.leading] }
    }
}

/// 分組標題：粗體、不轉大寫
struct SettingsHeader: View {
    var title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.primary.opacity(0.7))
            .textCase(nil)
            .padding(.leading, 4)
    }
}

extension View {
    /// 套在設定頁的 Form 上
    func settingsStyle() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Palette.background)
            .environment(\.defaultMinListRowHeight, 58)
            .listSectionSpacing(22)
    }

    /// 每一組的底色
    func settingsRow() -> some View {
        listRowBackground(Palette.card)
    }
}

/// 設定最上面的大卡片：標題、說明、右邊一顆玻璃箭頭鈕，背景是淡淡的同心圓
struct SettingsHeroCard: View {
    var title: String
    var subtitle: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.forward")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 66, height: 48)
                    .glassEffect(.regular.interactive(), in: .capsule)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    Palette.card
                    SettingsRings()
                }
                .clipShape(.rect(cornerRadius: 28, style: .continuous))
            }
            .contentShape(.rect(cornerRadius: 28, style: .continuous))
        }
        .buttonStyle(HeroPressStyle())
    }
}

private struct HeroPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: configuration.isPressed)
    }
}

/// 卡片背景的同心圓紋路，圓心偏右，往外越來越淡
private struct SettingsRings: View {
    @Environment(\.layoutDirection) private var direction

    var body: some View {
        Canvas { ctx, size in
            let x = direction == .rightToLeft ? size.width * 0.38 : size.width * 0.62
            let center = CGPoint(x: x, y: size.height * 0.55)
            let count = 34
            for i in 1...count {
                let r = CGFloat(i) * 7
                let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
                let fade = 1 - Double(i) / Double(count)
                ctx.stroke(Path(ellipseIn: rect), with: .color(.primary.opacity(0.09 * fade + 0.02)), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
