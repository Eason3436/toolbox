import SwiftUI
import UIKit

/// 點分頁列切換時，頁面像翻頁一樣左右滑動（保留系統原生的分頁列）。
/// 做法：找到 TabView 底下的 UITabBarController，在它的 delegate 外面包一層，只多提供切換動畫，其他呼叫照常轉給原本的 delegate。
@MainActor
enum TabSlide {
    static let proxy = TabDelegateProxy()

    static func install(on tbc: UITabBarController) {
        guard tbc.delegate !== proxy else { return }
        proxy.original = tbc.delegate
        tbc.delegate = proxy
    }
}

final class TabDelegateProxy: NSObject, UITabBarControllerDelegate {
    weak var original: UITabBarControllerDelegate?

    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return original?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let o = original, o.responds(to: aSelector) { return o }
        return super.forwardingTarget(for: aSelector)
    }

    func tabBarController(_ tabBarController: UITabBarController,
                          animationControllerForTransitionFrom fromVC: UIViewController,
                          to toVC: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        let list = tabBarController.viewControllers ?? []
        guard let a = list.firstIndex(of: fromVC), let b = list.firstIndex(of: toVC), a != b else { return nil }
        return TabSlideAnimator(forward: b > a)
    }
}

/// 新的頁面從右邊（或左邊）滑進來，舊的往另一邊滑出去
final class TabSlideAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    let forward: Bool
    init(forward: Bool) { self.forward = forward }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval { 0.42 }

    func animateTransition(using ctx: UIViewControllerContextTransitioning) {
        guard let from = ctx.view(forKey: .from), let to = ctx.view(forKey: .to),
              let toVC = ctx.viewController(forKey: .to) else {
            ctx.completeTransition(true)
            return
        }
        let container = ctx.containerView
        let w = container.bounds.width
        to.frame = ctx.finalFrame(for: toVC)
        container.addSubview(to)
        to.transform = CGAffineTransform(translationX: forward ? w : -w, y: 0)
        UIView.animate(withDuration: transitionDuration(using: ctx), delay: 0,
                       usingSpringWithDamping: 1, initialSpringVelocity: 0, options: [.allowUserInteraction]) {
            from.transform = CGAffineTransform(translationX: self.forward ? -w : w, y: 0)
            to.transform = .identity
        } completion: { _ in
            from.transform = .identity
            ctx.completeTransition(!ctx.transitionWasCancelled)
        }
    }
}

/// 放在每個分頁的背景裡：出現時把滑動動畫裝到分頁控制器上
struct TabSlideHook: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> HookController { HookController() }
    func updateUIViewController(_ vc: HookController, context: Context) { vc.install() }

    final class HookController: UIViewController {
        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
        }
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            install()
        }
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            install()
        }
        func install() {
            var vc: UIViewController? = self
            while let v = vc {
                if let tbc = v as? UITabBarController {
                    TabSlide.install(on: tbc)
                    return
                }
                if let tbc = v.tabBarController {
                    TabSlide.install(on: tbc)
                    return
                }
                vc = v.parent
            }
        }
    }
}
