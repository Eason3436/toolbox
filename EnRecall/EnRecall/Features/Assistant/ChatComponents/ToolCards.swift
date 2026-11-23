import SwiftUI
import QuickLook

/// 工具結果卡片（樣式沿用 App 的白底卡片）
struct ToolCardView: View {
    let card: ToolCard

    var body: some View {
        switch card.kind {
        case .recognition(let recognition):
            RecognitionCardView(cardID: card.id, card: recognition)
        case .words(let proposal):
            WordProposalView(cardID: card.id, proposal: proposal)
        case .patterns(let proposal):
            PatternProposalView(cardID: card.id, proposal: proposal)
        case .learning(let learning):
            LearningCardView(card: learning)
        case .pdf(let pdf):
            PDFCardView(card: pdf)
        }
    }
}

/// 卡片上方的小標題
private struct CardTitle: View {
    let title: String
    let systemImage: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: systemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.er.textSecondary)
            Text(title)
                .font(.erLabel)
                .tracking(1.1)
                .foregroundStyle(Color.er.textTertiary)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(.erLabel)
                    .foregroundStyle(Color.er.textTertiary)
            }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - 辨識結果

struct RecognitionCardView: View {
    let cardID: UUID
    let card: RecognitionCard
    @Environment(ChatSession.self) private var session
    @State private var isEditing = false
    @State private var draft = ""
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(title: "辨識結果", systemImage: "text.viewfinder", trailing: typeTitle)
            Text(highlighted)
                .font(.callout.monospaced())
                .foregroundStyle(Color.er.text)
                .lineLimit(isExpanded ? nil : 8)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !card.uncertain.isEmpty {
                Text("看不清楚：\(card.uncertain.joined(separator: "、"))")
                    .font(.caption)
                    .foregroundStyle(Color.er.textSecondary)
            }
            HStack(spacing: 8) {
                if card.transcript.split(separator: "\n").count > 8 {
                    Button(isExpanded ? "收起" : "展開") {
                        withAnimation(.snappy(duration: 0.25)) { isExpanded.toggle() }
                    }
                    .buttonStyle(.borderless)
                }
                Spacer()
                Button("修改", systemImage: "pencil") {
                    draft = card.transcript
                    isEditing = true
                }
                .buttonStyle(.bordered)
                Button("精準重新辨識", systemImage: "scope") {
                    session.rerecognize(card.messageID)
                }
                .buttonStyle(.bordered)
                .disabled(session.isBusy)
            }
            .font(.subheadline)
            .labelStyle(.titleOnly)
        }
        .erCard()
        .sheet(isPresented: $isEditing) {
            NavigationStack {
                TextEditor(text: $draft)
                    .font(.body.monospaced())
                    .scrollContentBackground(.hidden)
                    .padding(Theme.Spacing.page)
                    .erPageBackground()
                    .navigationTitle("修改辨識結果")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消", systemImage: "xmark") { isEditing = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成", systemImage: "checkmark") {
                                session.editRecognition(cardID: cardID, transcript: draft)
                                isEditing = false
                            }
                            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
            }
            .presentationDetents([.large])
        }
    }

    private var typeTitle: String? {
        switch card.imageType {
        case "handwritten": "手寫"
        case "printed": "印刷"
        case "mixed": "手寫＋印刷"
        case "article": "文章"
        default: nil
        }
    }

    /// 不確定的字加螢光底
    private var highlighted: AttributedString {
        var text = AttributedString(card.transcript)
        for word in card.uncertain where !word.isEmpty {
            var searchStart = text.startIndex
            while let range = text[searchStart...].range(of: word) {
                text[range].backgroundColor = Color.er.highlight
                searchStart = range.upperBound
            }
        }
        return text
    }
}

// MARK: - 單字確認卡

struct WordProposalView: View {
    let cardID: UUID
    let proposal: WordProposal
    @Environment(ChatSession.self) private var session
    @State private var editing: WordProposal.Item?

    private var included: Int { proposal.items.filter(\.included).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(title: "加入牌組", systemImage: "rectangle.stack.badge.plus",
                      trailing: "\(proposal.items.filter(\.isLibrary).count) 單字庫 · \(proposal.items.filter { !$0.isLibrary }.count) AI 撰寫")
            DeckNameField(name: proposal.deck, isEditable: isPending) { name in
                session.editCard(cardID) { kind in
                    if case .words(var p) = kind { p.deck = name; kind = .words(p) }
                }
            }
            VStack(spacing: 0) {
                ForEach(proposal.items) { item in
                    WordProposalRow(item: item, isEditable: isPending) {
                        toggle(item.id)
                    } edit: {
                        editing = item
                    }
                    if item.id != proposal.items.last?.id {
                        Divider().overlay(Color.er.outline)
                    }
                }
            }
            if !proposal.rejected.isEmpty {
                Text("沒加入：" + proposal.rejected.map { "\($0.word)（\($0.reason)）" }.joined(separator: "、"))
                    .font(.caption)
                    .foregroundStyle(Color.er.textSecondary)
            }
            ProposalFooter(state: proposal.state, isAwaiting: session.isAwaiting(cardID),
                           confirmTitle: "加入〈\(proposal.deck)〉", count: included) { decision in
                session.resolve(cardID, decision)
            }
        }
        .erCard()
        .sheet(item: $editing) { item in
            WordEditSheet(item: item) { updated in
                session.editCard(cardID) { kind in
                    guard case .words(var p) = kind, let index = p.items.firstIndex(where: { $0.id == updated.id }) else { return }
                    p.items[index] = updated
                    kind = .words(p)
                }
            }
        }
        .sensoryFeedback(.success, trigger: proposal.state) { _, new in
            if case .added = new { return true }
            return false
        }
    }

    private var isPending: Bool { proposal.state == .pending && session.isAwaiting(cardID) }

    private func toggle(_ id: UUID) {
        session.editCard(cardID) { kind in
            guard case .words(var p) = kind, let index = p.items.firstIndex(where: { $0.id == id }) else { return }
            p.items[index].included.toggle()
            kind = .words(p)
        }
    }
}

private struct WordProposalRow: View {
    let item: WordProposal.Item
    let isEditable: Bool
    let toggle: () -> Void
    let edit: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isEditable {
                Button(action: toggle) {
                    Image(systemName: item.included ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(item.included ? Color.er.primary : Color.er.outlineStrong)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.included ? "取消勾選 \(item.word)" : "勾選 \(item.word)")
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.word)
                        .font(.body.monospaced().weight(.semibold))
                        .foregroundStyle(Color.er.text)
                    if let pos = item.pos {
                        Text(pos)
                            .font(.erMonoSmall)
                            .foregroundStyle(Color.er.textTertiary)
                    }
                    Spacer(minLength: 4)
                    Chip(text: item.isLibrary ? "單字庫" : "AI 撰寫", style: item.isLibrary ? .muted : .info)
                }
                Text(item.zh.replacingOccurrences(of: "\n", with: "；"))
                    .font(.subheadline)
                    .foregroundStyle(Color.er.text)
                if let example = item.example {
                    Text(example)
                        .font(.footnote)
                        .foregroundStyle(Color.er.textSecondary)
                }
            }
            .opacity(item.included ? 1 : 0.45)
            .contentShape(Rectangle())
            .onTapGesture {
                // 單字庫的內容不能改（一律用單字庫的），只有 AI 寫的可以編輯
                if isEditable && !item.isLibrary { edit() }
            }
        }
        .padding(.vertical, 8)
        .animation(.snappy(duration: 0.2), value: item.included)
    }
}

private struct WordEditSheet: View {
    @State var item: WordProposal.Item
    let save: (WordProposal.Item) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("單字") {
                    TextField("單字", text: $item.word)
                        .textInputAutocapitalization(.never)
                    TextField("詞性", text: Binding(get: { item.pos ?? "" }, set: { item.pos = $0.isEmpty ? nil : $0 }))
                    TextField("中文", text: $item.zh, axis: .vertical)
                }
                Section("例句") {
                    TextField("英文例句", text: Binding(get: { item.example ?? "" }, set: { item.example = $0.isEmpty ? nil : $0 }), axis: .vertical)
                    TextField("中文翻譯", text: Binding(get: { item.exampleZh ?? "" }, set: { item.exampleZh = $0.isEmpty ? nil : $0 }), axis: .vertical)
                }
            }
            .scrollContentBackground(.hidden)
            .erPageBackground()
            .navigationTitle("編輯")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成", systemImage: "checkmark") {
                        save(item)
                        dismiss()
                    }
                    .disabled(item.word.trimmingCharacters(in: .whitespaces).isEmpty || item.zh.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

/// 牌組名稱：確認前可以改
private struct DeckNameField: View {
    let name: String
    let isEditable: Bool
    let rename: (String) -> Void
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.stack")
                .foregroundStyle(Color.er.textTertiary)
            if isEditable {
                TextField("牌組名稱", text: $draft)
                    .font(.headline)
                    .foregroundStyle(Color.er.text)
                    .focused($isFocused)
                    .submitLabel(.done)
                    .onSubmit(commit)
                    .onChange(of: isFocused) { _, focused in if !focused { commit() } }
            } else {
                Text(name)
                    .font(.headline)
                    .foregroundStyle(Color.er.text)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        .background(Color.er.fill, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
        .onAppear { draft = name }
        .onChange(of: name) { _, new in if !isFocused { draft = new } }
    }

    private func commit() {
        let trimmed = String(draft.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        if trimmed.isEmpty { draft = name } else if trimmed != name { rename(trimmed) }
    }
}

/// 確認卡下面：取消／加入；做完之後顯示結果
private struct ProposalFooter: View {
    let state: ProposalState
    let isAwaiting: Bool
    let confirmTitle: String
    let count: Int
    let decide: (ConfirmDecision) -> Void

    var body: some View {
        switch state {
        case .pending:
            if isAwaiting {
                HStack(spacing: 10) {
                    Button("取消") { decide(.cancel) }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    Button {
                        decide(.confirm)
                    } label: {
                        Text("\(confirmTitle) · \(count)")
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(count == 0)
                }
                .padding(.top, 4)
            } else {
                ProgressLine(text: "寫入中…")
            }
        case .added(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.er.text)
        case .cancelled:
            Label("已取消，沒有加入", systemImage: "xmark.circle")
                .font(.subheadline)
                .foregroundStyle(Color.er.textSecondary)
        }
    }
}

// MARK: - 句型確認卡

struct PatternProposalView: View {
    let cardID: UUID
    let proposal: PatternProposal
    @Environment(ChatSession.self) private var session
    @State private var expanded: Set<String> = []

    private var isPending: Bool { proposal.state == .pending && session.isAwaiting(cardID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(title: "加入句型", systemImage: "text.badge.plus",
                      trailing: "\(proposal.items.filter(\.fromLibrary).count) 句型庫 · \(proposal.items.filter { !$0.fromLibrary }.count) 新整理")
            DeckNameField(name: proposal.deck, isEditable: isPending) { name in
                session.editCard(cardID) { kind in
                    if case .patterns(var p) = kind { p.deck = name; kind = .patterns(p) }
                }
            }
            let replacing = proposal.items.filter { $0.replacesLibrary && $0.included }.count
            if replacing > 0 {
                Label("會用新內容覆蓋 App 裡的 \(replacing) 個句型", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Color.er.textSecondary)
            }
            VStack(spacing: 0) {
                ForEach(proposal.items) { item in
                    patternRow(item)
                    if item.id != proposal.items.last?.id {
                        Divider().overlay(Color.er.outline)
                    }
                }
            }
            if !proposal.rejected.isEmpty {
                Text("沒加入：" + proposal.rejected.map { "\($0.pattern)（\($0.reason)）" }.joined(separator: "、"))
                    .font(.caption)
                    .foregroundStyle(Color.er.textSecondary)
            }
            ProposalFooter(state: proposal.state, isAwaiting: session.isAwaiting(cardID),
                           confirmTitle: "加入〈\(proposal.deck)〉", count: proposal.items.filter(\.included).count) { decision in
                session.resolve(cardID, decision)
            }
        }
        .erCard()
        .sensoryFeedback(.success, trigger: proposal.state) { _, new in
            if case .added = new { return true }
            return false
        }
    }

    private func patternRow(_ item: PatternProposal.Item) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                if isPending {
                    Button {
                        session.editCard(cardID) { kind in
                            guard case .patterns(var p) = kind, let index = p.items.firstIndex(where: { $0.id == item.id }) else { return }
                            p.items[index].included.toggle()
                            kind = .patterns(p)
                        }
                    } label: {
                        Image(systemName: item.included ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(item.included ? Color.er.primary : Color.er.outlineStrong)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.included ? "取消勾選" : "勾選")
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        PatternFormula(text: item.detail.pattern, size: 16)
                        Spacer(minLength: 4)
                        Chip(text: item.fromLibrary ? "句型庫" : "新整理", style: item.fromLibrary ? .muted : .info)
                    }
                    if let zh = item.detail.zh {
                        Text(zh).font(.subheadline).foregroundStyle(Color.er.text)
                    }
                    if let example = item.detail.examples.first {
                        Text(example.en).font(.footnote).foregroundStyle(Color.er.textSecondary)
                    }
                    Button(expanded.contains(item.id) ? "收起完整內容" : "看完整內容") {
                        withAnimation(.snappy(duration: 0.25)) {
                            if expanded.contains(item.id) { expanded.remove(item.id) } else { expanded.insert(item.id) }
                        }
                    }
                    .font(.footnote.weight(.medium))
                    .buttonStyle(.borderless)
                }
                .opacity(item.included ? 1 : 0.45)
            }
            if expanded.contains(item.id) {
                VStack(alignment: .leading, spacing: Theme.Spacing.stack) {
                    PatternDetailContent(pattern: item.detail)
                }
                .transition(.opacity)
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - 學習成效

struct LearningCardView: View {
    let card: LearningCard

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(title: card.title, systemImage: "chart.bar")
            HStack(spacing: 8) {
                ForEach(card.numbers) { number in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(number.title)
                            .font(.caption)
                            .foregroundStyle(Color.er.textSecondary)
                        Text(number.value)
                            .numberFont(22, relativeTo: .title2, weight: .bold)
                            .foregroundStyle(Color.er.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
            if card.daily.contains(where: { $0 > 0 }) {
                MiniBars(values: card.daily)
                    .frame(height: 44)
                    .accessibilityLabel("每天複習量")
            }
            if !card.words.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("最常忘")
                        .font(.erLabel)
                        .tracking(1.1)
                        .foregroundStyle(Color.er.textTertiary)
                    ForEach(card.words) { word in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(word.word)
                                .font(.subheadline.monospaced().weight(.semibold))
                                .foregroundStyle(Color.er.text)
                            Text(word.zh.replacingOccurrences(of: "\n", with: "；"))
                                .font(.footnote)
                                .foregroundStyle(Color.er.textSecondary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(word.memory)
                                .font(.caption2)
                                .foregroundStyle(Color.er.textTertiary)
                        }
                    }
                }
            }
        }
        .erCard(elevated: true)
    }
}

/// 每天的量：細長條，最後一天（今天）用深色
private struct MiniBars: View {
    let values: [Int]

    var body: some View {
        GeometryReader { proxy in
            let top = max(values.max() ?? 1, 1)
            let gap: CGFloat = values.count > 30 ? 1 : 3
            let width = max((proxy.size.width - gap * CGFloat(values.count - 1)) / CGFloat(max(values.count, 1)), 1)
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(index == values.count - 1 ? Color.er.text : Color.er.outlineStrong)
                        .frame(width: width, height: max(2, proxy.size.height * CGFloat(value) / CGFloat(top)))
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}

// MARK: - PDF

struct PDFCardView: View {
    let card: PDFCard
    @State private var previewURL: URL?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let data = card.thumbnail, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "doc.richtext")
                        .font(.largeTitle)
                        .foregroundStyle(Color.er.textTertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.er.fill)
                }
            }
            .frame(width: 72, height: 102)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).strokeBorder(Color.er.outline))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(card.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.er.text)
                    .lineLimit(2)
                Text("\(card.pages.formatted()) 頁")
                    .font(.caption)
                    .foregroundStyle(Color.er.textSecondary)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Button("預覽", systemImage: "eye") { previewURL = card.url }
                        .buttonStyle(.borderedProminent)
                    ShareLink(item: card.url) {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                }
                .font(.subheadline)
            }
        }
        .erCard()
        .quickLookPreview($previewURL)
    }
}
