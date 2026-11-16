import SwiftUI

/// 頂部玻璃提示（控制層，所以可以用玻璃）。降低透明度時改用實心底
struct GlassToastView: View {
    let toast: Toast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Label(toast.message, systemImage: toast.systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.er.text)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .modifier(ToastBackground(solid: reduceTransparency))
    }
}

private struct ToastBackground: ViewModifier {
    let solid: Bool

    func body(content: Content) -> some View {
        if solid {
            content
                .background(Color.er.surfaceHigh, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.er.outline, lineWidth: 1))
        } else {
            content.glassEffect(.regular, in: .capsule)
        }
    }
}

/// 放在 RootView 最上層
struct ToastHost: View {
    @Environment(ToastCenter.self) private var toasts

    var body: some View {
        ZStack {
            if let toast = toasts.current {
                GlassToastView(toast: toast)
                    .id(toast.id)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { toasts.dismiss(toast.id) }
                    .onAppear {
                        AccessibilityNotification.Announcement(toast.message).post()
                    }
            }
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity)
    }
}

#Preview("淺色") {
    VStack(spacing: 20) {
        GlassToastView(toast: Toast(message: "從 Claude 匯入 18 個單字", systemImage: "square.and.arrow.down"))
        GlassToastView(toast: Toast(message: "已下載學測 Level 4"))
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .erPageBackground()
}

#Preview("深色") {
    GlassToastView(toast: Toast(message: "從 Claude 匯入 18 個單字", systemImage: "square.and.arrow.down"))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .erPageBackground()
        .preferredColorScheme(.dark)
}
