import SwiftUI
import SwiftData
import UIKit

/// 拍照找片語、句型的結果：照片裡出現的、片語總表和句型卡裡有的，依出現順序列出，下面附照片裡的那一句
struct PhraseScanView: View {
    let image: UIImage

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case scanning
        case done(PhraseSpotter.Result)
        case failed(String)
    }

    @State private var phase = Phase.scanning
    @State private var selected: Card?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.stack) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 140)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                        .accessibilityHidden(true)
                    content
                }
                .padding(.horizontal, Theme.Spacing.page)
                .padding(.bottom, 24)
            }
            .erPageBackground()
            .navigationTitle("照片裡的片語和句型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .task { await scan() }
        .sheet(item: $selected) { card in
            WordDetailSheet(card: card)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .scanning:
            HStack(spacing: 10) {
                ProgressView()
                Text("正在讀照片裡的英文")
                    .font(.subheadline)
                    .foregroundStyle(Color.er.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        case .failed(let message):
            EmptyLine(message)
        case .done(let result):
            let patterns = result.matches.filter(\.isPattern)
            let phrases = result.matches.filter { !$0.isPattern }
            if result.matches.isEmpty {
                EmptyLine("沒有找到片語總表或句型卡裡的片語、句型")
            }
            if !patterns.isEmpty {
                SectionHeader(title: "句型", trailing: patterns.count.formatted())
                matchList(patterns)
            }
            if !phrases.isEmpty {
                SectionHeader(title: "片語", trailing: phrases.count.formatted())
                    .padding(.top, patterns.isEmpty ? 0 : Theme.Spacing.sectionTop)
                matchList(phrases)
            }
            Text("只會找到學測片語總表和你的句型卡裡有的")
                .font(.footnote)
                .foregroundStyle(Color.er.textTertiary)
                .padding(.top, 4)
        }
    }

    private func matchList(_ matches: [PhraseSpotter.Match]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(matches.enumerated()), id: \.element.id) { index, match in
                if index > 0 {
                    Divider().overlay(Color.er.outline)
                }
                Button {
                    open(match)
                } label: {
                    MatchRow(match: match)
                        .padding(.vertical, Theme.Spacing.row)
                }
                .buttonStyle(.plain)
            }
        }
        .erCard(elevated: true)
    }

    private func scan() async {
        do {
            let result = try await PhraseSpotter.scan(image, container: context.container)
            withAnimation(.spring(duration: 0.3)) { phase = .done(result) }
        } catch {
            withAnimation(.spring(duration: 0.3)) { phase = .failed("照片裡沒有讀到英文") }
        }
    }

    private func open(_ match: PhraseSpotter.Match) {
        let id = match.cardID
        var descriptor = FetchDescriptor<Card>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        selected = try? context.fetch(descriptor).first
    }
}

private struct MatchRow: View {
    let match: PhraseSpotter.Match

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(match.title)
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.er.text)
            Text(match.zh)
                .font(.subheadline)
                .foregroundStyle(Color.er.textSecondary)
                .lineLimit(2)
            Text(highlighted)
                .font(.footnote)
                .foregroundStyle(Color.er.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// 照片裡的句子，符合的那段加螢光底色
    private var highlighted: AttributedString {
        var result = AttributedString(match.sentence)
        let range = NSRange(location: match.location, length: match.length)
        if let stringRange = Range(range, in: match.sentence),
           let lower = AttributedString.Index(stringRange.lowerBound, within: result),
           let upper = AttributedString.Index(stringRange.upperBound, within: result) {
            result[lower..<upper].backgroundColor = Color.er.highlight
            result[lower..<upper].foregroundColor = Color.er.text
        }
        return result
    }
}

/// 系統相機（拍課本、雜誌）
struct CameraPicker: UIViewControllerRepresentable {
    let onFinish: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onFinish: (UIImage?) -> Void

        init(onFinish: @escaping (UIImage?) -> Void) {
            self.onFinish = onFinish
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onFinish(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish(nil)
        }
    }
}

#Preview("淺色") {
    PhraseScanView(image: UIImage(systemName: "doc.text") ?? UIImage())
        .previewEnvironment()
}

#Preview("深色") {
    PhraseScanView(image: UIImage(systemName: "doc.text") ?? UIImage())
        .previewEnvironment()
        .preferredColorScheme(.dark)
}
