import SwiftUI

/// 顯示 Claude 透過同步伺服器寫回來的 Markdown 筆記。
struct ClaudeNotesCard: View {
    let title: String
    let markdown: String
    @State private var expanded = false

    var body: some View {
        Card {
            HStack {
                Label(title, systemImage: "text.bubble").font(.headline)
                Spacer()
                Button(expanded ? "收合" : "展開") { withAnimation { expanded.toggle() } }
                    .font(.subheadline)
            }
            Text(Self.render(markdown))
                .font(.callout)
                .lineLimit(expanded ? nil : 8)
                .textSelection(.enabled)
        }
    }

    static func render(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }
}
