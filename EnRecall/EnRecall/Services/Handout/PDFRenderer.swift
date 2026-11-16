import UIKit
import WebKit

/// HTML → A4 PDF（WebKit 排版、自動分頁），每頁底下畫頁尾：左邊範圍與份量、右邊「1 / 7」
@MainActor
final class PDFRenderer: NSObject, WKNavigationDelegate {
    enum RenderError: LocalizedError {
        case loadFailed

        var errorDescription: String? { "PDF 做不出來，再試一次" }
    }

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Void, Error>?

    /// A4：595.2 × 841.8 pt
    static let paper = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)

    static func render(html: String, footer: String) async throws -> Data {
        let renderer = PDFRenderer()
        return try await renderer.make(html: html, footer: footer)
    }

    private func make(html: String, footer: String) async throws -> Data {
        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = true
        let webView = WKWebView(frame: CGRect(origin: .zero, size: Self.paper.size), configuration: configuration)
        webView.navigationDelegate = self
        self.webView = webView
        defer { self.webView = nil }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }

        let pageRenderer = HandoutPageRenderer(footer: footer)
        pageRenderer.addPrintFormatter(webView.viewPrintFormatter(), startingAtPageAt: 0)
        let pages = pageRenderer.numberOfPages
        guard pages > 0 else { throw RenderError.loadFailed }

        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, Self.paper, [kCGPDFContextCreator as String: "EnRecall"])
        pageRenderer.prepare(forDrawingPages: NSRange(location: 0, length: pages))
        for page in 0..<pages {
            UIGraphicsBeginPDFPage()
            pageRenderer.drawPage(at: page, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()
        return data as Data
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: RenderError.loadFailed)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: RenderError.loadFailed)
        continuation = nil
    }
}

/// 紙張大小、邊界、頁尾
private final class HandoutPageRenderer: UIPrintPageRenderer {
    private let footer: String
    /// 左右 28pt（約 10mm）、上 23pt（約 8mm）、下 16pt，再往上 24pt 是頁尾
    private let insets = UIEdgeInsets(top: 23, left: 28, bottom: 16, right: 28)

    init(footer: String) {
        self.footer = footer
        super.init()
        footerHeight = 24
    }

    override var paperRect: CGRect { PDFRenderer.paper }

    override var printableRect: CGRect { PDFRenderer.paper.inset(by: insets) }

    override func drawFooterForPage(at pageIndex: Int, in footerRect: CGRect) {
        let gray = UIColor(white: 0.4, alpha: 1)
        let font = UIFont.monospacedSystemFont(ofSize: 6.5, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: gray]
        let left = PDFRenderer.paper.minX + insets.left
        let right = PDFRenderer.paper.maxX - insets.right
        let lineY = footerRect.minY + 6

        if let context = UIGraphicsGetCurrentContext() {
            context.setStrokeColor(UIColor(white: 0.85, alpha: 1).cgColor)
            context.setLineWidth(0.75)
            context.move(to: CGPoint(x: left, y: lineY))
            context.addLine(to: CGPoint(x: right, y: lineY))
            context.strokePath()
        }
        let textY = lineY + 4
        (footer as NSString).draw(at: CGPoint(x: left, y: textY), withAttributes: attributes)
        let page = "\(pageIndex + 1) / \(numberOfPages)" as NSString
        let width = page.size(withAttributes: attributes).width
        page.draw(at: CGPoint(x: right - width, y: textY), withAttributes: attributes)
    }
}
