import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 「檔案」App 挑選器。用複製模式（asCopy），系統會先把檔案下載並複製到 App 裡，
/// 不需要安全範圍存取，iCloud、第三方雲端和側載安裝都比較穩。
struct DocumentPicker: UIViewControllerRepresentable {
    var types: [UTType] = [.image, .movie, .audio, .pdf, .json, .item]
    var onPick: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = true
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }
    }
}
