import AVKit
import Core
import UIKit

/// 播放畫面要提供的功能（AVPlayer 與之後的 mpv 各自實作）
@MainActor
protocol PlayerScreen: UIViewController {
    /// 使用者關掉播放畫面
    var onDismiss: (() -> Void)? { get set }
    /// 長按（true 開始、false 放開）
    var onLongPress: ((Bool) -> Void)? { get set }
    /// 點兩下（true 右邊快轉、false 左邊倒轉）
    var onDoubleTap: ((Bool) -> Void)? { get set }
    func showError(_ message: String)
    /// 「下一集」倒數；completion(true) 表示要播
    func showNextUp(title: String, seconds: Int, completion: @escaping (Bool) -> Void)
    /// 外掛字幕（nil 是清掉）
    func showSubtitles(_ track: SubtitleTrack?, style: SubtitleStyle)
    /// 長按加速的提示（nil 是收起來）
    func showSpeedIndicator(_ rate: Float?)
    func showSkipIndicator(forward: Bool, seconds: Int)
}

/// 全螢幕呈現的 AVPlayerViewController：原生關閉鍵、子母畫面、AirPlay、字幕與音軌選單、HDR／杜比視界輸出。
final class DrivePlayerViewController: AVPlayerViewController, PlayerScreen, UIGestureRecognizerDelegate {
    var onDismiss: (() -> Void)?
    var onLongPress: ((Bool) -> Void)?
    var onDoubleTap: ((Bool) -> Void)?
    private var nextUpCard: NextUpCard?
    private let subtitleView = SubtitleOverlayView()
    private let speedPill = PillLabel()
    private let skipPill = PillLabel()
    private var subtitleObserver: Any?
    private var hidePillTask: Task<Void, Never>?
    private lazy var doubleTap: UITapGestureRecognizer = {
        let g = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        g.numberOfTapsRequired = 2
        g.delegate = self
        return g
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        modalPresentationStyle = .fullScreen

        if let overlay = contentOverlayView {
            subtitleView.translatesAutoresizingMaskIntoConstraints = false
            overlay.addSubview(subtitleView)
            NSLayoutConstraint.activate([
                subtitleView.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
                subtitleView.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
                subtitleView.topAnchor.constraint(equalTo: overlay.topAnchor),
                subtitleView.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),
            ])
        }

        for pill in [speedPill, skipPill] {
            pill.translatesAutoresizingMaskIntoConstraints = false
            pill.alpha = 0
            view.addSubview(pill)
        }
        NSLayoutConstraint.activate([
            speedPill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            speedPill.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 56),
            skipPill.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            skipPill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.4
        longPress.delegate = self
        longPress.cancelsTouchesInView = false
        view.addGestureRecognizer(longPress)
        doubleTap.cancelsTouchesInView = false
        view.addGestureRecognizer(doubleTap)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 系統播放器自己的「點兩下縮放」要等我們的快轉手勢失敗才觸發（只在左右兩側搶）
        for g in Self.allGestures(in: view) where g !== doubleTap {
            if let tap = g as? UITapGestureRecognizer, tap.numberOfTapsRequired >= 2 {
                tap.require(toFail: doubleTap)
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil {
            nextUpCard?.cancel()
            removeSubtitleObserver()
            onDismiss?()
        }
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }

    // MARK: - 手勢

    @objc private func handleLongPress(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began: onLongPress?(true)
        case .ended, .cancelled, .failed: onLongPress?(false)
        default: break
        }
    }

    @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
        let x = g.location(in: view).x
        onDoubleTap?(x > view.bounds.midX)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard g === doubleTap else { return true }
        // 中間三分之一留給系統（縮放）
        let x = g.location(in: view).x
        let third = view.bounds.width / 3
        return x < third || x > third * 2
    }

    private static func allGestures(in view: UIView) -> [UIGestureRecognizer] {
        (view.gestureRecognizers ?? []) + view.subviews.flatMap { allGestures(in: $0) }
    }

    // MARK: - 提示

    func showSpeedIndicator(_ rate: Float?) {
        if let rate {
            speedPill.text = "\(rate.formatted(.number.precision(.fractionLength(0...1))))× 快轉中"
            speedPill.symbol = "forward.fill"
        }
        UIView.animate(withDuration: 0.2) { self.speedPill.alpha = rate == nil ? 0 : 1 }
    }

    func showSkipIndicator(forward: Bool, seconds: Int) {
        skipPill.symbol = forward ? "goforward" : "gobackward"
        skipPill.text = "\(seconds) 秒"
        hidePillTask?.cancel()
        UIView.animate(withDuration: 0.15) { self.skipPill.alpha = 1 }
        hidePillTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, let self else { return }
            UIView.animate(withDuration: 0.25) { self.skipPill.alpha = 0 }
        }
    }

    // MARK: - 外掛字幕

    func showSubtitles(_ track: SubtitleTrack?, style: SubtitleStyle) {
        removeSubtitleObserver()
        subtitleView.style = style
        subtitleView.text = nil
        guard let track, let player else { return }
        subtitleObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                self?.subtitleView.text = track.text(at: time.seconds)
            }
        }
    }

    private func removeSubtitleObserver() {
        if let observer = subtitleObserver { player?.removeTimeObserver(observer) }
        subtitleObserver = nil
    }

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

/// 畫在影片上的外掛字幕：底部置中，字體大小跟著畫面高度
private final class SubtitleOverlayView: UIView {
    private let label = UILabel()
    var style = SubtitleStyle.current() { didSet { render() } }
    var text: String? { didSet { if text != oldValue { render() } } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        label.numberOfLines = 0
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.9),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        render()
    }

    private func render() {
        guard let text, !text.isEmpty else {
            label.attributedText = nil
            return
        }
        let size = max(16, min(bounds.width, bounds.height) * 0.055) * style.scale
        var font = UIFont.systemFont(ofSize: size, weight: style.bold ? .bold : .semibold)
        if style.italic, let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.traitItalic)) {
            font = UIFont(descriptor: descriptor, size: size)
        }
        let shadow = NSShadow()
        shadow.shadowColor = style.edgeColor.withAlphaComponent(0.8)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = .zero
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        label.attributedText = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: style.color,
            .strokeColor: style.edgeColor,
            .strokeWidth: -3.0,
            .shadow: shadow,
            .paragraphStyle: paragraph,
        ])
    }
}

/// 播放畫面上的小膠囊提示（「2× 快轉中」「10 秒」）
private final class PillLabel: UIVisualEffectView {
    private let icon = UIImageView()
    private let label = UILabel()

    var text: String? {
        get { label.text }
        set { label.text = newValue }
    }

    var symbol: String? {
        didSet { icon.image = symbol.flatMap { UIImage(systemName: $0) } }
    }

    init() {
        super.init(effect: UIBlurEffect(style: .systemThinMaterialDark))
        isUserInteractionEnabled = false
        layer.cornerRadius = 20
        clipsToBounds = true
        icon.tintColor = .white
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .subheadline, scale: .medium)
        label.font = .preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
        label.textColor = .white
        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.spacing = 6
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        UIFont.systemFont(ofSize: pointSize, weight: weight)
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
