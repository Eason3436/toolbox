import Foundation
import UIKit
import WebKit

/// 用畫面外的 WKWebView 排版文件，再輸出 PDF、圖片或文字。
/// Word、Excel、PowerPoint、Pages、Keynote 也能直接載入（由系統負責顯示）。
@MainActor
final class WebRenderer: NSObject, WKNavigationDelegate {
    enum Paper: String {
        case a4, letter
        var size: CGSize { self == .a4 ? CGSize(width: 595.2, height: 841.8) : CGSize(width: 612, height: 792) }
    }

    private let webView: WKWebView
    private var continuation: CheckedContinuation<Void, Error>?

    init(width: CGFloat = 794) {
        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = true
        webView = WKWebView(frame: CGRect(x: -30000, y: 0, width: width, height: 1100), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.isOpaque = true
        webView.backgroundColor = .white
        // 掛在視窗上（但在畫面外），排版和截圖才可靠。
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first
        window?.addSubview(webView)
    }

    func close() {
        webView.stopLoading()
        webView.removeFromSuperview()
    }

    // MARK: 載入

    func load(html: String, baseURL: URL?) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            continuation = c
            webView.loadHTMLString(html, baseURL: baseURL)
        }
        try await settle(seconds: 0.4)
    }

    func load(file: URL, settleSeconds: Double = 0.6) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            continuation = c
            webView.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
        }
        try await settle(seconds: settleSeconds)
    }

    private func settle(seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        _ = try? await webView.evaluateJavaScript("document.fonts ? 'ok' : 'ok'")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        resume(nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        resume(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        resume(error)
    }

    /// 文件裡的連結一律不跟著跳。
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.navigationType == .linkActivated ? .cancel : .allow)
    }

    private func resume(_ error: Error?) {
        guard let c = continuation else { return }
        continuation = nil
        if let error { c.resume(throwing: error) } else { c.resume() }
    }

    // MARK: 輸出

    /// 分頁輸出 PDF。margin 單位是 pt。
    func pdf(paper: Paper, margin: CGFloat) -> Data {
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(webView.viewPrintFormatter(), startingAtPageAt: 0)
        let paperRect = CGRect(origin: .zero, size: paper.size)
        let printable = paperRect.insetBy(dx: margin, dy: margin)
        renderer.setValue(NSValue(cgRect: paperRect), forKey: "paperRect")
        renderer.setValue(NSValue(cgRect: printable), forKey: "printableRect")
        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, paperRect, nil)
        let count = renderer.numberOfPages
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: count))
        for index in 0..<count {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: index, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()
        return data as Data
    }

    func text() async throws -> String {
        let value = try await webView.evaluateJavaScript("(document.body ? document.body.innerText : '') + ''")
        return (value as? String) ?? ""
    }

    func markdown() async throws -> String {
        let value = try await webView.evaluateJavaScript(Self.markdownScript)
        return (value as? String) ?? ""
    }

    func html() async throws -> String {
        let value = try await webView.evaluateJavaScript("document.documentElement.outerHTML + ''")
        return (value as? String) ?? ""
    }

    /// 整頁長截圖。pixelWidth 是輸出圖片的寬度（像素）。
    func snapshot(pixelWidth: CGFloat) async throws -> UIImage {
        let value = try await webView.evaluateJavaScript(
            "String(Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0))")
        let height = Double((value as? String) ?? "") ?? 1100
        let capped = CGFloat(Swift.min(Swift.max(height, 200), 12_000))
        webView.frame.size.height = capped
        try await Task.sleep(nanoseconds: 300_000_000)
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: 0, y: 0, width: webView.frame.width, height: capped)
        configuration.afterScreenUpdates = true
        let scale = webView.window?.screen.scale ?? 3
        configuration.snapshotWidth = NSNumber(value: Double(pixelWidth / scale))
        return try await webView.takeSnapshot(configuration: configuration)
    }

    /// 把畫面上的 DOM 轉成 Markdown。
    static let markdownScript = #"""
    (function () {
      function clean(t) { return t.replace(/[ \t\r\n ]+/g, ' '); }
      function isBlock(el) {
        var d = getComputedStyle(el).display;
        return d === 'block' || d === 'flex' || d === 'grid' || d === 'list-item' || d === 'table';
      }
      function kids(n) { var s = ''; for (var i = 0; i < n.childNodes.length; i++) s += node(n.childNodes[i]); return s; }
      function wrap(mark, n) { var x = kids(n).trim(); return x ? mark + x + mark : ''; }
      function list(n, depth) {
        var out = '', index = 1, ordered = n.tagName.toLowerCase() === 'ol';
        for (var i = 0; i < n.children.length; i++) {
          var li = n.children[i];
          if (li.tagName.toLowerCase() !== 'li') continue;
          var text = '', nested = '';
          for (var j = 0; j < li.childNodes.length; j++) {
            var c = li.childNodes[j];
            if (c.nodeType === 1 && (c.tagName.toLowerCase() === 'ul' || c.tagName.toLowerCase() === 'ol')) nested += list(c, depth + 1);
            else text += node(c);
          }
          out += '  '.repeat(depth) + (ordered ? (index++) + '. ' : '- ') + text.replace(/\s*\n+\s*/g, ' ').trim() + '\n' + nested;
        }
        return out;
      }
      function table(t) {
        var rows = t.querySelectorAll('tr'), lines = [], width = 0;
        for (var i = 0; i < rows.length; i++) {
          var cells = rows[i].querySelectorAll('th,td'), line = [];
          for (var j = 0; j < cells.length; j++) line.push(clean(cells[j].innerText).trim().replace(/\|/g, '\\|'));
          width = Math.max(width, line.length);
          lines.push(line);
        }
        if (!lines.length) return '';
        var out = '';
        for (var k = 0; k < lines.length; k++) {
          while (lines[k].length < width) lines[k].push('');
          out += '| ' + lines[k].join(' | ') + ' |\n';
          if (k === 0) out += '|' + Array(width).fill(' --- ').join('|') + '|\n';
        }
        return out;
      }
      function node(n) {
        if (n.nodeType === 3) return clean(n.textContent);
        if (n.nodeType !== 1) return '';
        var t = n.tagName.toLowerCase();
        if (['script', 'style', 'head', 'noscript', 'template', 'svg', 'button', 'input', 'select'].indexOf(t) >= 0) return '';
        var st = getComputedStyle(n);
        if (st.display === 'none' || st.visibility === 'hidden') return '';
        switch (t) {
          case 'h1': case 'h2': case 'h3': case 'h4': case 'h5': case 'h6':
            var h = kids(n).trim(); return h ? '\n\n' + '#'.repeat(+t[1]) + ' ' + h + '\n\n' : '';
          case 'p': return '\n\n' + kids(n).trim() + '\n\n';
          case 'br': return '  \n';
          case 'hr': return '\n\n---\n\n';
          case 'strong': case 'b': return wrap('**', n);
          case 'em': case 'i': return wrap('*', n);
          case 'del': case 's': case 'strike': return wrap('~~', n);
          case 'code': return '`' + n.textContent + '`';
          case 'pre': return '\n\n```\n' + n.innerText.replace(/\n+$/, '') + '\n```\n\n';
          case 'a':
            var label = kids(n).trim(), href = n.getAttribute('href') || '';
            return href && label && href.indexOf('javascript:') !== 0 && href.charAt(0) !== '#' ? '[' + label + '](' + href + ')' : label;
          case 'img':
            var src = n.getAttribute('src') || '';
            return src.indexOf('data:') === 0 ? '' : '![' + (n.getAttribute('alt') || '') + '](' + src + ')';
          case 'ul': case 'ol': return '\n\n' + list(n, 0) + '\n';
          case 'blockquote':
            return '\n\n' + kids(n).trim().split('\n').map(function (l) { return '> ' + l; }).join('\n') + '\n\n';
          case 'table': return '\n\n' + table(n) + '\n';
        }
        var inner = kids(n);
        if (isBlock(n)) {
          var w = parseInt(st.fontWeight, 10), size = parseFloat(st.fontSize), body = parseFloat(getComputedStyle(document.body).fontSize) || 16;
          var text = inner.trim();
          if (text && text.length < 120 && text.indexOf('\n') < 0 && size >= body * 1.5) return '\n\n# ' + text + '\n\n';
          if (text && text.length < 120 && text.indexOf('\n') < 0 && size >= body * 1.2 && w >= 600) return '\n\n## ' + text + '\n\n';
          return '\n\n' + text + '\n\n';
        }
        return inner;
      }
      var md = node(document.body || document.documentElement);
      return md.replace(/[ \t]+\n/g, function (m) { return m.indexOf('  ') === 0 ? '  \n' : '\n'; })
               .replace(/\n{3,}/g, '\n\n').trim() + '\n';
    })()
    """#
}
