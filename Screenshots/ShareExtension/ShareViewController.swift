import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 分享延伸功能：只把圖片寫進 App Group 收件匣，分析由主 App 執行。
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareStatusView(model: model) { [weak self] in
            self?.finish()
        })
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.view.backgroundColor = .clear
        view.addSubview(host.view)
        host.didMove(toParent: self)
        Task { await receive() }
    }

    private func receive() async {
        guard SharedInbox.isAvailable else {
            model.state = .failed("無法存取 App 共用資料夾（App Group）。請確認安裝時的簽署包含 App Group。")
            return
        }
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
        var saved = 0
        for provider in providers {
            if let loaded = await Self.loadImage(from: provider) {
                do {
                    try SharedInbox.add(imageData: loaded.0, fileExtension: loaded.1)
                    saved += 1
                } catch {
                    model.state = .failed("儲存失敗：\(error.localizedDescription)")
                    return
                }
            }
        }
        if saved == 0 {
            model.state = .failed("沒有可以收錄的圖片。")
        } else {
            model.state = .done(saved)
            try? await Task.sleep(for: .seconds(1.2))
            finish()
        }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// 讀取圖片資料，回傳資料與副檔名。
    private static func loadImage(from provider: NSItemProvider) async -> (Data, String)? {
        let type = provider.registeredContentTypes.first { $0.conforms(to: .image) } ?? .image
        let ext = type.preferredFilenameExtension ?? "png"
        return await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(for: type) { data, _ in
                continuation.resume(returning: data.map { ($0, ext) })
            }
        }
    }
}

@MainActor
@Observable
final class ShareModel {
    enum State: Equatable {
        case working
        case done(Int)
        case failed(String)
    }

    var state: State = .working
}

struct ShareStatusView: View {
    let model: ShareModel
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            switch model.state {
            case .working:
                ProgressView()
                Text("正在送進 Screenshots…")
            case .done(let count):
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.green)
                Text("已收錄 \(count) 張，打開 Screenshots 後會開始分析。")
                    .multilineTextAlignment(.center)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.orange)
                Text(message).multilineTextAlignment(.center)
                Button("關閉", action: onClose)
                    .buttonStyle(.glassProminent)
            }
        }
        .font(.headline)
        .padding(28)
        .frame(maxWidth: 320)
        .glassEffect(in: .rect(cornerRadius: 28))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
