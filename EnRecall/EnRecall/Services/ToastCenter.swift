import SwiftUI

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var message: String
    var systemImage: String = "checkmark"
}

/// 頂部玻璃提示。同時只顯示一則，新的會取代舊的
@MainActor
@Observable
final class ToastCenter {
    private(set) var current: Toast?
    private var hideTask: Task<Void, Never>?

    func show(_ message: String, systemImage: String = "checkmark") {
        let toast = Toast(message: message, systemImage: systemImage)
        withAnimation(.spring(duration: 0.35)) { current = toast }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.6))
            guard !Task.isCancelled else { return }
            self?.dismiss(toast.id)
        }
    }

    func dismiss(_ id: UUID? = nil) {
        guard id == nil || current?.id == id else { return }
        withAnimation(.spring(duration: 0.3)) { current = nil }
    }
}
