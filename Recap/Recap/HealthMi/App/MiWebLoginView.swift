import SwiftUI
import WebKit

/// 網頁登入 sheet：內嵌小米官方登入頁，登入成功後自動讀取 Cookie 並儲存憑據。
///
/// 密碼、驗證碼都在小米官方頁面內完成，App 不接觸密碼；登入成功後從 WebView
/// 的 Cookie 中提取 `userId` + `passToken`，呼叫 `HMAppModel.saveCredentials`
/// 存入鑰匙串並校驗連線，隨後透過 `onConnected` 通知父檢視。
struct MiWebLoginView: View {
    @Environment(HMAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// 登入成功並儲存憑據後，由父檢視執行的後續動作（如首次使用請求 HealthKit 授權）。
    var onConnected: () async -> Void = {}

    @State private var isWorking = false
    @State private var errorMessage: String?
    /// 重試時 +1，透過 `.id()` 重建 WebView（非持久化會話，重建即重新登入）。
    @State private var loginAttempt = 0

    var body: some View {
        NavigationStack {
            ZStack {
                MiWebLoginViewRepresentable(
                    onCredentials: { userId, passToken in
                        Task { @MainActor in await completeLogin(userId: userId, passToken: passToken) }
                    },
                    onLoadError: { message in
                        errorMessage = message
                    }
                )
                .id(loginAttempt)

                if isWorking {
                    ProgressView("正在驗證登入憑證…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .navigationTitle("小米賬號登入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isWorking)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let errorMessage {
                    HStack(alignment: .top, spacing: 8) {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("重試") {
                            self.errorMessage = nil
                            loginAttempt += 1
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.regularMaterial)
                }
            }
        }
    }

    private func completeLogin(userId: String, passToken: String) async {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await model.saveCredentials(userId: userId, passToken: passToken)
            dismiss()
            await onConnected()
        } catch {
            errorMessage = "儲存並驗證登入憑證失敗：\(error.localizedDescription)"
        }
    }
}

// MARK: - UIKit 橋接

private struct MiWebLoginViewRepresentable: UIViewControllerRepresentable {
    let onCredentials: @MainActor (String, String) -> Void
    let onLoadError: @MainActor (String) -> Void

    func makeUIViewController(context: Context) -> MiWebLoginViewController {
        MiWebLoginViewController(onCredentials: onCredentials, onLoadError: onLoadError)
    }

    func updateUIViewController(_ uiViewController: MiWebLoginViewController, context: Context) {}
}

/// 持有 WKWebView 的容器控制器。
@MainActor
private final class MiWebLoginViewController: UIViewController {
    private let controller: MiWebLoginController

    init(onCredentials: @escaping @MainActor (String, String) -> Void,
         onLoadError: @escaping @MainActor (String) -> Void) {
        let controller = MiWebLoginController()
        controller.onCredentials = onCredentials
        controller.onLoadError = onLoadError
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = controller.webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        controller.start()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        controller.stop()
    }
}

// MARK: - WebView 邏輯

/// 管理登入頁的載入與 Cookie 捕獲。
@MainActor
private final class MiWebLoginController: NSObject, WKNavigationDelegate, WKUIDelegate {
    var onCredentials: (@MainActor (String, String) -> Void)?
    var onLoadError: (@MainActor (String) -> Void)?

    private(set) var didSucceed = false

    let webView: WKWebView
    private var cookieTimer: Timer?

    override init() {
        let configuration = WKWebViewConfiguration()
        // 非持久化會話：登入期間的 Cookie 不寫入 WebView 快取，下次啟動無殘留登入態。
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    /// 開啟小米登入頁並開始輪詢 Cookie。在 `viewDidLoad` 呼叫。
    func start() {
        guard !didSucceed else { return }
        cookieTimer?.invalidate()
        let timer = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkCookies() }
        }
        RunLoop.main.add(timer, forMode: .common)
        cookieTimer = timer
        webView.load(URLRequest(url: MiWebLogin.loginURL))
    }

    func stop() {
        cookieTimer?.invalidate()
        cookieTimer = nil
        webView.stopLoading()
    }

    // MARK: - Cookie 捕獲

    private func checkCookies() {
        guard !didSucceed else { return }
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            Task { @MainActor in
                guard let self, !self.didSucceed,
                      let credentials = MiWebLogin.credentials(from: cookies)
                else { return }
                self.complete(credentials.userId, credentials.passToken)
            }
        }
    }

    private func complete(_ userId: String, _ passToken: String) {
        guard !didSucceed else { return }
        didSucceed = true
        cookieTimer?.invalidate()
        cookieTimer = nil
        onCredentials?(userId, passToken)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 登入會經歷多次重定向，每次完成後都檢查一次 Cookie。
        checkCookies()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        guard !didSucceed else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        onLoadError?(error.localizedDescription)
    }

    // MARK: - WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // `target=_blank` 的彈窗在同一個 WebView 內開啟，避免登入流程被新視窗打斷。
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }
}

