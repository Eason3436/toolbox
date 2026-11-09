import SwiftUI
import UIKit

/// App 的主要色：預設幾組配色，也可以自己挑
enum Theme {
    static let key = "themeAccent"

    struct Option: Identifiable {
        var id: String
        var name: String
        var light: String
        var dark: String
        var color: Color { Theme.dynamic(light: light, dark: dark) }
    }

    /// 淺色模式用比較深的色，深色模式用比較亮的色，兩邊都清楚
    static let options: [Option] = [
        Option(id: "rose", name: "玫瑰", light: "#5E223C", dark: "#E8788F"),
        Option(id: "coral", name: "珊瑚", light: "#B4452F", dark: "#FF8A6B"),
        Option(id: "amber", name: "琥珀", light: "#A15C07", dark: "#F5B74E"),
        Option(id: "olive", name: "橄欖", light: "#4F6B2A", dark: "#A8C97A"),
        Option(id: "mint", name: "薄荷", light: "#0F7A5C", dark: "#5FD3A8"),
        Option(id: "teal", name: "湖水", light: "#0E6F7A", dark: "#5CC8D6"),
        Option(id: "sky", name: "天空", light: "#1F5FAD", dark: "#79B0F2"),
        Option(id: "indigo", name: "靛藍", light: "#3D3FA8", dark: "#9A9CF5"),
        Option(id: "lavender", name: "薰衣草", light: "#6A3FA0", dark: "#C3A3F0"),
        Option(id: "plum", name: "梅子", light: "#7A2557", dark: "#E68AC0"),
        Option(id: "sand", name: "奶茶", light: "#7A5A3A", dark: "#D9B48F"),
        Option(id: "graphite", name: "石墨", light: "#3A3A3C", dark: "#D1D1D6"),
    ]

    /// 存的值：預設配色的 id，或「#RRGGBB」自訂色
    static func color(for raw: String) -> Color {
        if raw.hasPrefix("#") { return Color(hex: raw) }
        return (options.first { $0.id == raw } ?? options[0]).color
    }

    /// 這個色碼是不是跟目前存的值（預設配色或自訂色）幾乎一樣
    static func isSame(_ hex: String, as raw: String) -> Bool {
        if raw.hasPrefix("#") { return close(hex, raw) }
        guard let o = options.first(where: { $0.id == raw }) else { return false }
        return close(hex, o.light) || close(hex, o.dark)
    }

    private static func close(_ a: String, _ b: String) -> Bool {
        guard let x = rgb(a), let y = rgb(b) else { return false }
        return abs(x.0 - y.0) <= 6 && abs(x.1 - y.1) <= 6 && abs(x.2 - y.2) <= 6
    }

    private static func rgb(_ hex: String) -> (Int, Int, Int)? {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard h.count == 6, let v = Int(h, radix: 16) else { return nil }
        return ((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF)
    }

    static func dynamic(light: String, dark: String) -> Color {
        let l = UIColor(Color(hex: light)), d = UIColor(Color(hex: dark))
        return Color(UIColor { $0.userInterfaceStyle == .dark ? d : l })
    }

    static func hex(_ c: Color) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(c).getRed(&r, green: &g, blue: &b, alpha: &a)
        let v = (Int(max(0, min(1, r)) * 255) << 16) | (Int(max(0, min(1, g)) * 255) << 8) | Int(max(0, min(1, b)) * 255)
        return String(format: "#%06X", v)
    }
}

/// 設定頁的「主要色」選擇器
struct ThemePicker: View {
    @AppStorage(Theme.key) private var raw = "rose"

    /// ColorPicker 在選取改變時會把目前的顏色寫回來；如果只是把剛選的預設色寫回來
    /// 就忽略，不然會變成「自訂色」，勾勾和外框就不見了
    private var custom: Binding<Color> {
        Binding(get: { Theme.color(for: raw) }, set: { new in
            let hex = Theme.hex(new)
            if Theme.isSame(hex, as: raw) { return }
            raw = hex
        })
    }

    private var isCustom: Bool { raw.hasPrefix("#") }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 不用 Lazy 版本：放在 Form 裡偶爾不會重畫，勾勾會停在舊的顏色
            Grid(horizontalSpacing: 10, verticalSpacing: 14) {
                ForEach(0..<2, id: \.self) { row in
                    GridRow {
                        ForEach(Theme.options[(row * 6)..<(row * 6 + 6)]) { o in
                            swatch(o).frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            HStack {
                Text("自訂顏色")
                if isCustom {
                    Image(systemName: "checkmark").font(.footnote.weight(.bold)).foregroundStyle(Color.accentColor)
                }
                Spacer()
                ColorPicker("自訂顏色", selection: custom, supportsOpacity: false)
                    .labelsHidden()
            }
        }
        .padding(.vertical, 6)
    }

    private func swatch(_ o: Theme.Option) -> some View {
        let picked: Bool = raw == o.id
        return Button {
            withAnimation(.snappy) { raw = o.id }
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    Circle().fill(o.color).frame(width: 36, height: 36)
                    if picked {
                        Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                    }
                }
                .overlay(Circle().strokeBorder(Color.primary.opacity(picked ? 0.6 : 0), lineWidth: 2).padding(-4))
                Text(o.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: picked)
    }
}

/// 中性色：背景、卡片都不用純黑／純白，深色模式另外調整，不是直接反轉
enum Palette {
    /// 頁面底色
    static let background = Theme.dynamic(light: "#F2F2F5", dark: "#0F0F11")
    /// 卡片
    static let card = Theme.dynamic(light: "#FCFCFD", dark: "#1C1C1F")
    /// 卡片裡再一層（按鈕、輸入框）
    static let raised = Theme.dynamic(light: "#ECECF0", dark: "#2A2A2E")
    /// 深色卡片上的主要按鈕：接近白，但不是純白
    static let onDarkButton = Color(hex: "#F2F2F4")
    static let onDarkButtonText = Color(hex: "#1C1C1E")
    /// 一般圖示用的中性灰（不再每一列一個顏色）
    static let icon = Theme.dynamic(light: "#6B6B73", dark: "#A1A1A8")
}
