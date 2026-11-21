import AVKit
import UIKit

/// 播放畫面要提供的功能（AVPlayer 與之後的 mpv 各自實作）
@MainActor
protocol PlayerScreen: UIViewController {
    /// 使用者關掉播放畫面
    var onDismiss: (() -> Void)? { get set }
    func showError(_ message: String)
    /// 「下一集」倒數；completion(true) 表示要播
    func showNextUp(title: String, seconds: Int, completion: @escaping (Bool) -> Void)
}

/// 全螢幕呈現的 AVPlayerViewController：原生關閉鍵、子母畫面、AirPlay、字幕與音軌選單、HDR／杜比視界輸出。
final class DrivePlayerViewController: AVPlayerViewController, PlayerScreen {
    var onDismiss: (() -> Void)?
    private var nextUpCard: NextUpCard?

    override func viewDidLoad() {
        super.viewDidLoad()
        modalPresentationStyle = .fullScreen
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil {
            nextUpCard?.cancel()
            onDismiss?()
        }
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }

    func showError(_ message: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: "無法播放", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "關閉", style: .cancel) { [weak self] _ in
            self?.dismiss(animated: true)
        })
        present(alert, animated: true)
    }

    func showNextUp(title: String, seconds: Int, completion: @escaping (Bool) -> Void) {
        nextUpCard?.cancel()
        let card = NextUpCard(title: title, seconds: seconds) { [weak self] accepted in
            self?.nextUpCard = nil
            completion(accepted)
        }
        nextUpCard = card
        card.install(in: view)
    }
}

/// 右下角的「下一集」卡片，倒數結束自動播放
@MainActor
private final class NextUpCard {
    private let container = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterialDark))
    private let playButton = UIButton(configuration: .filled())
    private var countdown: Task<Void, Never>?
    private var remaining: Int
    private let completion: (Bool) -> Void
    private var done = false

    init(title: String, seconds: Int, completion: @escaping (Bool) -> Void) {
        remaining = seconds
        self.completion = completion

        let caption = UILabel()
        caption.text = "下一集"
        caption.font = .preferredFont(forTextStyle: .caption1)
        caption.textColor = .secondaryLabel
        let name = UILabel()
        name.text = title
        name.font = .preferredFont(forTextStyle: .headline)
        name.textColor = .label
        name.numberOfLines = 2

        var cancelConfig = UIButton.Configuration.gray()
        cancelConfig.title = "取消"
        let cancelButton = UIButton(configuration: cancelConfig)
        cancelButton.addAction(UIAction { [weak self] _ in self?.finish(false) }, for: .primaryActionTriggered)
        playButton.addAction(UIAction { [weak self] _ in self?.finish(true) }, for: .primaryActionTriggered)

        let buttons = UIStackView(arrangedSubviews: [cancelButton, playButton])
        buttons.spacing = 8
        buttons.distribution = .fillEqually
        let stack = UIStackView(arrangedSubviews: [caption, name, buttons])
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.contentView.addSubview(stack)
        container.layer.cornerRadius = 16
        container.clipsToBounds = true
        container.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.contentView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: container.contentView.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: container.contentView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: container.contentView.bottomAnchor, constant: -12),
        ])
        updateTitle()
    }

    func install(in view: UIView) {
        view.addSubview(container)
        NSLayoutConstraint.activate([
            container.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            container.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -80),
            container.widthAnchor.constraint(equalToConstant: 280),
        ])
        container.alpha = 0
        UIView.animate(withDuration: 0.25) { self.container.alpha = 1 }
        countdown = Task { [weak self] in
            while let self, self.remaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                self.remaining -= 1
                self.updateTitle()
            }
            self?.finish(true)
        }
    }

    func cancel() {
        guard !done else { return }
        done = true
        countdown?.cancel()
        container.removeFromSuperview()
    }

    private func updateTitle() {
        playButton.configuration?.title = "立即播放（\(remaining)）"
    }

    private func finish(_ accepted: Bool) {
        guard !done else { return }
        done = true
        countdown?.cancel()
        UIView.animate(withDuration: 0.2, animations: { self.container.alpha = 0 }) { _ in
            self.container.removeFromSuperview()
        }
        completion(accepted)
    }
}
