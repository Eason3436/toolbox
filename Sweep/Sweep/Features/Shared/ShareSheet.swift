import SwiftUI
import UIKit

/// sheet(item:) 用的網址
struct ShareItem: Identifiable {
    let url: URL
    var id: URL { url }
}

/// 系統分享表
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
