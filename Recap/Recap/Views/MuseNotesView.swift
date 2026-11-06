import SwiftUI

/// Muse 寫回的筆記：Markdown 或 HTML 都能顯示，用課程筆記的排版。
enum MuseText {
    /// 卡片上的預覽：去掉標記，留前幾行純文字
    static func preview(_ raw: String, lines: Int = 6) -> String {
        var text = raw
        if text.range(of: #"<[a-zA-Z][^>]*>"#, options: .regularExpression) != nil {
            text = text.replacingOccurrences(of: #"(?i)<br\s*/?>|</(p|li|h\d|tr|div|section|header)>"#, with: "\n", options: .regularExpression)
            text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
        }
        let cleaned = text.components(separatedBy: .newlines)
            .map { line -> String in
                var l = line.trimmingCharacters(in: .whitespaces)
                l = l.replacingOccurrences(of: #"^#{1,6}\s*"#, with: "", options: .regularExpression)
                l = l.replacingOccurrences(of: #"^>\s*"#, with: "", options: .regularExpression)
                l = l.replacingOccurrences(of: #"^[-*+]\s+"#, with: "・", options: .regularExpression)
                l = l.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
                return l
            }
            .filter { !$0.isEmpty && !$0.hasPrefix("|") && $0 != "---" }
        return cleaned.prefix(lines).joined(separator: "\n")
    }

    /// 第一個標題（當卡片標題）
    static func title(_ raw: String) -> String? {
        for line in raw.components(separatedBy: .newlines) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("#") { return l.replacingOccurrences(of: #"^#{1,6}\s*"#, with: "", options: .regularExpression).replacingOccurrences(of: "**", with: "") }
            if let range = l.range(of: #"(?i)<h1[^>]*>(.*?)</h1>"#, options: .regularExpression) {
                return String(l[range]).replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            }
        }
        return nil
    }

    /// 轉成可顯示的 HTML 片段
    static func html(_ raw: String) -> String {
        RichNotes.importNotes(raw) ?? "<p>\(raw.replacingOccurrences(of: "<", with: "&lt;"))</p>"
    }

    /// 預覽時去掉第一個標題那行（標題另外顯示）
    static func body(_ raw: String) -> String {
        guard let t = title(raw) else { return preview(raw) }
        let p = preview(raw, lines: 8)
        return p.hasPrefix(t) ? String(p.dropFirst(t.count)).trimmingCharacters(in: .whitespacesAndNewlines) : p
    }
}

/// 整份 Muse 筆記（全螢幕排版）
struct MuseNotesSheet: View {
    let title: String
    let raw: String
    @Environment(\.dismiss) private var dismiss

    private var page: String { RichNotes.page(MuseText.html(raw), title: title) }

    var body: some View {
        NavigationStack {
            RichNotesWebView(html: page)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("關閉", systemImage: "xmark") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: raw) { Image(systemName: "square.and.arrow.up") }
                    }
                }
        }
    }
}

/// 卡片：標題＋幾行預覽，點了打開整份筆記
struct MuseNotesCard: View {
    let label: String
    let raw: String
    var sheetTitle: String
    @State private var showing = false

    var body: some View {
        Button {
            Haptics.tap()
            showing = true
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(label, systemImage: "sparkles.rectangle.stack").font(.subheadline.weight(.semibold)).foregroundStyle(.tint)
                    Spacer()
                    Text("看完整筆記").font(.footnote).foregroundStyle(.tint)
                    Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
                }
                if let title = MuseText.title(raw) {
                    Text(title).font(.title3.bold()).foregroundStyle(.primary).multilineTextAlignment(.leading)
                }
                Text(MuseText.body(raw))
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(7)
                    .multilineTextAlignment(.leading)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showing) { MuseNotesSheet(title: sheetTitle, raw: raw) }
    }
}
