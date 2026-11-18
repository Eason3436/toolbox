import SwiftUI

/// 輸入單字下載密碼：存進 Keychain 後重新讀商店，用 toast 告訴使用者對不對
struct StorePasswordField: View {
    @Environment(StoreModel.self) private var store
    @Environment(ToastCenter.self) private var toasts
    @State private var draft = ""
    @State private var isChecking = false

    var body: some View {
        HStack(spacing: 12) {
            SecureField("下載密碼", text: $draft)
                .textContentType(.password)
                .submitLabel(.done)
                .onSubmit(save)
                .foregroundStyle(Color.er.text)
            if isChecking {
                ProgressView()
            } else if !draft.isEmpty {
                Button("確定", action: save)
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.borderless)
            }
        }
        .animation(.spring(duration: 0.25), value: draft.isEmpty)
        .sensoryFeedback(trigger: store.phase) { _, phase in
            switch phase {
            case .loaded: return .success
            case .needsPassword: return .error
            default: return nil
            }
        }
    }

    private func save() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !isChecking else { return }
        StoreAccess.password = value
        draft = ""
        isChecking = true
        Task {
            await store.load(force: true)
            isChecking = false
            switch store.phase {
            case .loaded: toasts.show("可以下載單字包了")
            case .needsPassword: toasts.show("下載密碼不對", systemImage: "exclamationmark.triangle")
            default: toasts.show("無法連上單字商店", systemImage: "wifi.slash")
            }
        }
    }
}

#Preview("淺色") {
    Form {
        StorePasswordField()
            .listRowBackground(Color.er.surface)
    }
    .scrollContentBackground(.hidden)
    .erPageBackground()
    .previewEnvironment()
}

#Preview("深色") {
    Form {
        StorePasswordField()
            .listRowBackground(Color.er.surface)
    }
    .scrollContentBackground(.hidden)
    .erPageBackground()
    .previewEnvironment()
    .preferredColorScheme(.dark)
}
