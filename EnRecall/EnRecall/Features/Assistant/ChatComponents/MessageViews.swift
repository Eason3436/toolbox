import SwiftUI

/// 使用者的訊息：靠 trailing、主色底
struct UserBubble: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !message.thumbnails.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(message.thumbnails.enumerated()), id: \.offset) { _, data in
                        if let image = UIImage(data: data) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 72, height: 96)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                                    .strokeBorder(Color.er.outline))
                                .accessibilityLabel("圖片")
                        }
                    }
                }
            }
            if let text = message.text {
                Text(text)
                    .font(.body)
                    .foregroundStyle(Color.er.onPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.er.primary, in: RoundedRectangle(cornerRadius: Theme.Radius.card + 4, style: .continuous))
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 48)
    }
}

/// 模型的回覆：靠 leading、卡片底，支援粗體、條列；下面接工具卡片
struct ModelReply: View {
    let message: ChatMessage
    @Environment(ChatSession.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.stack) {
            ForEach(message.cards) { card in
                ToolCardView(card: card)
            }
            if let text = message.text {
                MarkdownText(text: text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.er.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card + 4, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card + 4, style: .continuous).strokeBorder(Color.er.outline))
            }
            if let error = message.error {
                HStack(spacing: 10) {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(Color.er.textSecondary)
                    Spacer(minLength: 0)
                    if message.canRetry {
                        Button("重試") { session.retry(message.id) }
                            .buttonStyle(.bordered)
                            .disabled(session.isBusy)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 24)
    }
}

/// 粗體、斜體、行內程式碼用系統的 Markdown；條列一行一行排
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let line):
                    Text(Self.inline(line))
                case .bullet(let line):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(Color.er.textTertiary)
                        Text(Self.inline(line))
                    }
                case .numbered(let number, let line):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(number).").monospacedDigit().foregroundStyle(Color.er.textTertiary)
                        Text(Self.inline(line))
                    }
                case .heading(let line):
                    Text(Self.inline(line)).font(.headline)
                }
            }
        }
        .font(.body)
        .foregroundStyle(Color.er.text)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }

    enum Block {
        case paragraph(String)
        case bullet(String)
        case numbered(String, String)
        case heading(String)
    }

    var blocks: [Block] {
        text.split(separator: "\n", omittingEmptySubsequences: true).map { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                return .bullet(String(line.dropFirst(2)))
            }
            if line.hasPrefix("#") {
                return .heading(line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces))
            }
            if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
               line[line.index(after: dot)...].hasPrefix(" ") {
                return .numbered(String(line[..<dot]), String(line[line.index(dot, offsetBy: 2)...]))
            }
            return .paragraph(line)
        }
    }

    static func inline(_ line: String) -> AttributedString {
        (try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(line)
    }
}

/// 執行中：目前的步驟
struct ProgressLine: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Color.er.textSecondary)
                .contentTransition(.opacity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .animation(.easeOut(duration: 0.15), value: text)
    }
}
