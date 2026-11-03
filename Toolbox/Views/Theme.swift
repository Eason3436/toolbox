import SwiftUI

/// 設計規範的色票（Asset Catalog 裡的同名 Color Set，淺色和深色各一）。
extension Color {
    static let tbGround = Color("ground")
    static let tbSurface = Color("surface")
    static let tbInk = Color("ink")
    static let tbInkSecondary = Color("inkSecondary")
    static let tbInkTertiary = Color("inkTertiary")
    static let tbHairline = Color("hairline")
    static let tbAccent = Color("AccentColor")
    static let tbOnAccent = Color("onAccent")
    static let tbAccentSoft = Color("accentSoft")
    static let tbDanger = Color("danger")
    static let tbWarning = Color("warning")
}

extension Font {
    /// 首頁大標題：思源宋體，跟著動態字級縮放。
    static let tbLargeTitle = Font.custom("NotoSerifTC-Medium", size: 34, relativeTo: .largeTitle)
    /// 空狀態、功能包標題。
    static let tbTitle = Font.custom("NotoSerifTC-Medium", size: 28, relativeTo: .title)
}

extension View {
    /// List／Form 換成米白底。
    func tbGroundBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(Color.tbGround)
            .tbSoftEdges()
    }

    /// 捲動內容碰到導覽列、底部按鈕時用柔和的漸進模糊。
    func tbSoftEdges() -> some View {
        scrollEdgeEffectStyle(.soft, for: .all)
    }
}

/// 每個畫面唯一的主要按鈕：膠囊、強調色。
struct PrimaryButton: View {
    let title: String
    var systemImage: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(.glassProminent)
        .tint(.tbAccent)
    }
}

/// 2～4 個短選項的膠囊分段控制。
struct CapsuleSegments: View {
    let options: [ParamOption]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.value) { option in
                let isOn = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(.subheadline.weight(isOn ? .semibold : .regular))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .foregroundStyle(isOn ? Color.tbAccent : Color.tbInk)
                        .background(Capsule().fill(isOn ? Color.tbAccentSoft : Color.clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(4)
        .glassEffect(.regular, in: Capsule())
        .animation(.snappy(duration: 0.2), value: selection)
    }
}

/// 「可以做的事」的一列。
struct ActionRowLabel: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .symbolRenderingMode(.monochrome)
                .font(.title3)
                .foregroundStyle(Color.tbAccent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(Color.tbInk)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(Color.tbInkSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.tbInkTertiary)
        }
        .frame(minHeight: 48)
        .contentShape(Rectangle())
    }
}
