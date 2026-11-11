import SwiftUI

// MARK: - 卡片底

struct CardBackground: ViewModifier {
    var padding: CGFloat = 20
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 28, style: .continuous))
    }
}

extension View {
    func cardStyle(padding: CGFloat = 20) -> some View { modifier(CardBackground(padding: padding)) }
}

// MARK: - 狀態小膠囊（已付 100%、已繳）

struct Pill: View {
    var text: String
    var tint: Color = .green
    var filled: Bool = false

    var body: some View {
        Text(text)
            .font(.callout.weight(.medium))
            .monospacedDigit()
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .foregroundStyle(filled ? .white : tint)
            .background(filled ? tint : tint.opacity(0.15), in: .capsule)
    }
}

/// 深色卡片上的黑色膠囊
struct DarkPill: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.callout.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.black.opacity(0.55), in: .capsule)
    }
}

// MARK: - 分類圖示

struct CategoryIcon: View {
    var symbol: String
    var emoji: String? = nil
    var color: Color
    var size: CGFloat = 40
    var onDark: Bool = false
    /// 數值改變時圖示播放一次動畫
    var trigger: Int = 0

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(onDark ? color.opacity(0.28) : color.opacity(0.16))
            if let emoji, !emoji.isEmpty {
                Text(emoji).font(.system(size: size * 0.5))
            } else {
                LedgerIcon(symbol: symbol, size: size * 0.5, color: color, weight: 2.2, trigger: trigger)
            }
        }
        .frame(width: size, height: size)
    }
}

extension Category {
    func icon(size: CGFloat = 44, onDark: Bool = false, trigger: Int = 0) -> CategoryIcon {
        CategoryIcon(symbol: symbol, emoji: emoji, color: color, size: size, onDark: onDark, trigger: trigger)
    }
}

// MARK: - 選項膠囊（編輯畫面）

struct Chip: View {
    var title: String
    var symbol: String? = nil
    var symbolColor: Color? = nil
    var selected: Bool = false
    var tint: Color = .accentColor
    var showsChevron: Bool = false
    /// 開關型膠囊：選取時圖示換成打勾（寬度不變，旁邊的膠囊不會被擠動）
    var removable: Bool = false

    private var shownSymbol: String? {
        guard let symbol else { return nil }
        return removable && selected ? "checkmark.circle.fill" : symbol
    }

    var body: some View {
        HStack(spacing: 8) {
            if let shownSymbol {
                if !removable, LedgerIcon.pulso(for: shownSymbol) != nil {
                    LedgerIcon(symbol: shownSymbol, size: 17, color: symbolColor ?? (selected ? tint : Color.primary),
                               trigger: selected ? 1 : 0)
                } else {
                    Image(systemName: shownSymbol)
                        .foregroundStyle(removable && selected ? tint : (symbolColor ?? (selected ? tint : .primary)))
                        .contentTransition(.symbolEffect(.replace.downUp))
                        .symbolEffect(.bounce, value: selected)
                }
            }
            Text(title).lineLimit(1)
            if showsChevron {
                Image(systemName: "chevron.down").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.primary)
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
        .background {
            // 底色和外框畫在同一個形狀上，切換時一起漸變，不會有殘影
            Capsule()
                .fill(selected ? tint.opacity(0.18) : Color(.secondarySystemGroupedBackground))
                .overlay(Capsule().strokeBorder(tint.opacity(selected ? 1 : 0), lineWidth: 2))
        }
        .contentShape(.capsule)
        .animation(Motion.chip, value: selected)
        .onChange(of: selected) {
            // 線條圖示自己會跟著動畫震；其他（emoji、SF Symbol）彈一下
            if !usesPulso { Haptics.shared.symbolBounce(size: 17) }
        }
    }

    private var usesPulso: Bool {
        guard let shownSymbol, !removable else { return false }
        return LedgerIcon.pulso(for: shownSymbol) != nil
    }
}

enum Motion {
    /// 膠囊、分類切換用的彈簧
    static let chip: Animation = .spring(response: 0.38, dampingFraction: 0.78)
    /// 版面展開／收合
    static let layout: Animation = .spring(response: 0.45, dampingFraction: 0.86)
}

/// 膠囊按下去會縮一下再彈回來
struct ChipPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .brightness(configuration.isPressed ? -0.03 : 0)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// 虛線「＋ 付款卡片」
struct DashedChip: View {
    var title: String
    var body: some View {
        Label(title, systemImage: "plus")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 15)
            .padding(.vertical, 9)
            .overlay {
                Capsule().strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])).foregroundStyle(.tertiary)
            }
            .contentShape(.capsule)
    }
}

// MARK: - 篩選膠囊（全部／金融／現金）

struct FilterChip: View {
    var title: String
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.medium))
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .foregroundStyle(selected ? Color(.systemBackground) : .primary)
                .background(selected ? Color.primary : Color(.secondarySystemGroupedBackground), in: .capsule)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 自動換行排版

struct FlowLayout: Layout {
    var spacing: CGFloat = 10
    var leading: Bool = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(rows.count - 1, 0)) * spacing
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x: CGFloat = leading ? bounds.minX : bounds.minX + (bounds.width - row.width) / 2
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let extra = current.indices.isEmpty ? size.width : size.width + spacing
            if current.width + extra > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
                current.indices = [i]
                current.width = size.width
                current.height = size.height
            } else {
                current.indices.append(i)
                current.width += extra
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - 摘要卡片的列

struct SummaryRow: View {
    var title: String
    var value: String = ""
    var amount: Double? = nil
    var currency: String = Prefs.mainCurrency
    var hidden: Bool = false

    init(title: String, value: String) {
        self.title = title
        self.value = value
    }

    /// 金額版：數字會滾動
    init(title: String, amount: Double, currency: String = Prefs.mainCurrency, hidden: Bool = false) {
        self.title = title
        self.amount = amount
        self.currency = currency
        self.hidden = hidden
    }

    var body: some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            if let amount {
                MoneyText(value: amount, currency: currency, hidden: hidden, font: .body.weight(.semibold), haptics: false)
            } else {
                Text(value).font(.body.weight(.semibold)).monospacedDigit()
            }
        }
        .font(.subheadline)
    }
}

/// 隱藏金額的眼睛按鈕
struct EyeButton: View {
    @Binding var hidden: Bool
    var body: some View {
        Button {
            withAnimation(.snappy) { hidden.toggle() }
        } label: {
            Image(systemName: hidden ? "eye.slash" : "eye")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 52, height: 52)
                .background(Color(.tertiarySystemFill), in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hidden ? "顯示金額" : "隱藏金額")
    }
}

// MARK: - 月份切換（玻璃膠囊）

struct MonthStepper: View {
    @Binding var month: Date

    var body: some View {
        HStack(spacing: 4) {
            Button { withAnimation(.snappy) { month = DateText.addMonths(month, -1) } } label: {
                Image(systemName: "chevron.backward").frame(width: 32, height: 40).contentShape(.rect)
            }
            // 放在 List 列裡時，三個按鈕要各自點得到（不然整列只觸發一個）
            .buttonStyle(.borderless)
            Menu {
                Button("本月") { withAnimation(.snappy) { month = .now } }
                ForEach(1..<13) { i in
                    let d = DateText.addMonths(.now, -i)
                    Button(DateText.monthTitle(d)) { withAnimation(.snappy) { month = d } }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(DateText.monthTitle(month)).font(.headline).monospacedDigit()
                    Image(systemName: "chevron.down").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
            }
            .buttonStyle(.borderless)
            Button { withAnimation(.snappy) { month = DateText.addMonths(month, 1) } } label: {
                Image(systemName: "chevron.forward").frame(width: 32, height: 40).contentShape(.rect)
            }
            .buttonStyle(.borderless)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

// MARK: - 空狀態

struct EmptyHint: View {
    var symbol: String
    var title: String
    var message: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 40)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - 深色漸層卡片底（帳單、帳戶）

struct GradientCardBackground: View {
    var color: Color
    var body: some View {
        RoundedRectangle(cornerRadius: 30, style: .continuous)
            .fill(
                LinearGradient(colors: [color.mix(with: .white, by: 0.12), color, color.mix(with: .black, by: 0.45)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .shadow(color: .black.opacity(0.18), radius: 18, y: 10)
    }
}
