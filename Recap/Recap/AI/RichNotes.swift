import Foundation
import SwiftUI
import WebKit

/// 用 Gemini 把整堂課整理成排版完整的課程筆記（HTML）：課堂流程、各主題重點、數字卡、
/// 課堂流程、各主題重點、會考、補充、事實查核、單字表。App 用自己的樣式顯示，不執行任何程式碼。
enum RichNotes {
    static func generate(lecture: Lecture, transcript: String, memory: String) async throws -> String {
        let subject = lecture.subject ?? .general
        let kind = subject.isSeminar ? "講座" : (subject == .general ? "課" : "\(subject.title)課")
        let date = lecture.start.formatted(.dateTime.year().month().day().weekday(.wide).hour().minute())
        let system = """
        你是台灣頂尖的高中助教兼筆記達人，要把一堂\(kind)的逐字稿整理成學生複習用的「上課紀錄整理」。
        逐字稿是語音辨識結果，老師常中英夾雜，會有錯字、把英文聽成中文諧音、斷句錯誤，請依上下文與科目知識修正。
        這是學生自己的私人筆記，照實整理即可。一律使用台灣繁體中文；英文術語保留原文。
        \(subject == .general ? "" : subject.noteFocus)
        \(memory)
        """
        let prompt = """
        上課時間：\(date)
        以下是完整逐字稿：
        \(transcript)

        請輸出一份 HTML 片段（不要 <html>、<head>、<style>、<script>，不要 Markdown code block），只能使用下列結構與 class：

        <header>
          <p class="eyebrow">科目或課名・上課紀錄整理</p>
          <h1>這堂課的標題（點出主題）</h1>
          <p class="lead">摘要：4～6 句，這堂課在講什麼、依什麼順序、整體脈絡與結論</p>
        </header>
        <nav class="chips"><a href="#s0">課堂流程</a><a href="#s1">主題一</a>…<a href="#vocab">單字表</a></nav>

        <section class="card" id="s0"><h2><span class="num">00</span>課堂流程</h2>
          <ol class="steps"><li>依時間順序的每個環節（暖身、講解、看影片、討論、活動、交代作業…）</li></ol>
        </section>

        每個主題一個 section（依上課順序，id 用 s1、s2…，num 用 01、02…）：
        <section class="card" id="s1"><h2><span class="num">01</span>主題名稱</h2>
          <p class="sub">英文全名或一句定義（有才寫）</p>
          <div class="stats"><div class="stat"><b>關鍵數字或名詞</b><span>說明</span></div>…</div>（有重要數字、年份、比例時才用，2～6 個）
          <ul><li><strong>概念</strong>（<code>English term</code>）：具體解釋、老師舉的例子、因果關係</li></ul>
          <table>…</table>（有對照、分類時才用）
          <aside class="example"><h3>課堂範例</h3>老師舉的例子，推導過程寫清楚</aside>
          <aside class="tip"><h3>老師的提示</h3>老師提醒要注意的地方</aside>
          <aside class="exam"><h3>★ 會考</h3>老師說會考、要背、常考的內容</aside>
          <aside class="note"><h3>補充</h3>幫助理解的背景知識（標明是補充）</aside>
          <aside class="check"><h3>事實查核</h3><ul><li>逐字稿或老師說法和目前事實不一致的地方，寫出正確說法與理由</li></ul></aside>
        </section>

        最後一個 section：
        <section class="card" id="vocab"><h2><span class="num">字</span>單字表</h2><table><tr><th>英文</th><th>詞性</th><th>中文</th><th>課堂用法</th></tr>…</table></section>

        規則：
        - aside 只在真的有內容時才放。
        - 不要出練習題、自我測驗或參考答案。
        - 重點要詳細具體，保留老師的例子、數字、公式、原話重點；不要空泛。
        - 講座不用會考，改成 <aside class="exam"><h3>★ 講者強調</h3>…</aside>。
        - 英文術語一律用 <code> 包起來；重點詞用 <strong>。
        - 只根據逐字稿與可靠常識，不要編造課堂上沒發生的事；補充與事實查核要標清楚。
        """
        let html: String
        do {
            // 可以上網查證，事實查核比較準
            html = try await GeminiClient.generate(system: system, prompt: prompt, temperature: 0.4, googleSearch: true)
        } catch GeminiError.server(let code, _) where code == 400 {
            // 這個模型或方案不支援搜尋：不查證也照樣整理
            html = try await GeminiClient.generate(system: system, prompt: prompt, temperature: 0.4)
        }
        return sanitize(html)
    }

    /// 去掉 code block 標記與任何可能執行的東西（WebView 也已關閉 JavaScript）。
    static func sanitize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            s = s.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            if let end = s.range(of: "```", options: .backwards) { s = String(s[..<end.lowerBound]) }
        }
        let patterns = [
            #"(?is)<script.*?</script>"#, #"(?is)<style.*?</style>"#, #"(?is)<iframe.*?</iframe>"#,
            #"(?is)<(object|embed|link|meta|base|form|input)[^>]*>"#,
            #"(?i)\son\w+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#,
            #"(?i)(href|src)\s*=\s*("|')\s*javascript:[^"']*("|')"#,
            #"(?i)\ssrc\s*=\s*("|')https?:[^"']*("|')"#,
        ]
        for p in patterns { s = s.replacingOccurrences(of: p, with: "", options: .regularExpression) }
        return s
    }

    static func page(_ body: String, title: String) -> String {
        """
        <!doctype html><html lang="zh-Hant"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(title.replacingOccurrences(of: "<", with: "&lt;"))</title>
        <style>\(css)</style></head><body><main>\(body)</main></body></html>
        """
    }

    static let css = """
    :root{color-scheme:light dark;--bg:#F5F4F0;--card:#FFFFFF;--line:#E4E1DA;--ink:#1F2328;--muted:#6B6F76;--accent:#C9783F;--en:#2F5FA7;
      --note:#EEF3FA;--check:#FBEFE6;--tip:#EEF3FA;--exam:#FFF4DC;--example:#F1F5EE;}
    @media (prefers-color-scheme:dark){:root{--bg:#15181B;--card:#1D2125;--line:#30353B;--ink:#E8E6E1;--muted:#9AA0A6;--accent:#E0965C;--en:#8DB4F5;
      --note:#1E2A38;--check:#3A2A20;--tip:#1E2A38;--exam:#3A3120;--example:#20301F;}}
    *{box-sizing:border-box}
    body{margin:0;background:var(--bg);color:var(--ink);font:17px/1.75 -apple-system,"PingFang TC",sans-serif;-webkit-text-size-adjust:100%}
    main{padding:20px 16px 48px;max-width:760px;margin:0 auto}
    .eyebrow{color:var(--muted);letter-spacing:.12em;font-size:14px;margin:0 0 6px}
    h1{font-family:ui-serif,"Songti TC",serif;font-size:30px;line-height:1.3;margin:0 0 12px}
    .lead{color:var(--muted);margin:0 0 18px}
    .chips{display:flex;flex-wrap:wrap;gap:8px;margin:0 0 22px}
    .chips a{color:var(--ink);text-decoration:none;border:1px solid var(--line);border-radius:999px;padding:6px 14px;font-size:15px;background:var(--card)}
    .card{background:var(--card);border:1px solid var(--line);border-radius:18px;padding:18px 16px;margin:0 0 18px}
    h2{font-family:ui-serif,"Songti TC",serif;font-size:24px;line-height:1.35;margin:0 0 10px;display:flex;gap:12px;align-items:baseline}
    .num{font:600 15px ui-monospace,Menlo,monospace;color:var(--accent);flex:none}
    h3{font-size:16px;margin:0 0 6px;color:var(--accent)}
    .sub{margin:-4px 0 12px;color:var(--muted)}
    code{font-family:ui-monospace,Menlo,monospace;font-size:.92em;color:var(--en);background:none;word-break:break-word}
    strong{font-weight:700}
    ul,ol{padding-left:1.3em;margin:8px 0}
    li{margin:6px 0}
    .steps li::marker{color:var(--accent);font-weight:600}
    .stats{display:grid;grid-template-columns:repeat(auto-fill,minmax(140px,1fr));gap:14px;margin:12px 0 16px}
    .stat{border-top:3px solid var(--accent);padding-top:8px}
    .stat b{display:block;font:700 24px/1.3 ui-monospace,Menlo,monospace;word-break:break-word}
    .stat span{color:var(--muted);font-size:15px}
    aside{border-radius:12px;padding:12px 14px;margin:14px 0}
    aside.note,aside.tip{background:var(--note)} aside.note h3,aside.tip h3{color:var(--en)}
    aside.check{background:var(--check)} aside.exam{background:var(--exam)} aside.example{background:var(--example)}
    aside.example h3{color:#4E9A5B}
    table{width:100%;border-collapse:collapse;margin:12px 0;font-size:15px;display:block;overflow-x:auto}
    th,td{border:1px solid var(--line);padding:8px;text-align:left;vertical-align:top}
    th{background:var(--bg)}
    .task{border-left:3px solid var(--accent);padding:4px 12px;margin:8px 0}
    details{border:1px solid var(--line);border-radius:12px;padding:10px 12px;margin:10px 0}
    summary{font-weight:600;cursor:pointer}
    details p{margin:8px 0 0;color:var(--muted)}
    """
}

/// 顯示詳細筆記（關閉 JavaScript）。
struct RichNotesWebView: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.dataDetectorTypes = []
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.navigationDelegate = context.coordinator
        view.loadHTMLString(html, baseURL: nil)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        if context.coordinator.loaded != html {
            context.coordinator.loaded = html
            view.loadHTMLString(html, baseURL: nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(html: html) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: String
        init(html: String) { loaded = html }

        // 只允許載入筆記本身和頁內跳轉，外部連結交給 Safari
        @MainActor
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else { return .allow }
            if action.navigationType == .linkActivated, let scheme = url.scheme, scheme.hasPrefix("http") {
                await UIApplication.shared.open(url)
                return .cancel
            }
            return .allow
        }
    }
}

struct RichNotesSheet: View {
    let lecture: Lecture
    let html: String
    @Environment(\.dismiss) private var dismiss

    private var page: String { RichNotes.page(html, title: lecture.displayTitle) }

    var body: some View {
        NavigationStack {
            RichNotesWebView(html: page)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("課程筆記")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("關閉", systemImage: "xmark") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        if let url = exportURL() {
                            ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                        }
                    }
                }
        }
    }

    private func exportURL() -> URL? {
        let safe = lecture.displayTitle.replacingOccurrences(of: "/", with: "-").prefix(40)
        let url = FileManager.default.temporaryDirectory.appending(path: "\(safe).html")
        do {
            try page.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}
