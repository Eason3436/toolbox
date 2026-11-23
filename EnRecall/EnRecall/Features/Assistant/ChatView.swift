import SwiftUI
import SwiftData

/// 助理：像聊天一樣輸入文字、上傳圖片，模型呼叫 App 的工具加單字、整理句型、看學習成效、做 PDF
struct ChatView: View {
    @Environment(ChatSession.self) private var session
    @Environment(\.modelContext) private var context
    @State private var draft = ""
    @State private var images: [Data] = []
    @State private var isScanning = false
    @FocusState private var isFocused: Bool

    private struct Suggestion: Identifiable {
        let title: String
        let systemImage: String
        /// nil：打開掃描
        let prompt: String?
        var id: String { title }
    }

    private static let suggestions: [Suggestion] = [
        Suggestion(title: "拍照加單字", systemImage: "camera", prompt: nil),
        Suggestion(title: "把這篇文章的句型整理成卡片", systemImage: "text.quote", prompt: "把這篇文章的句型整理成卡片"),
        Suggestion(title: "我最近背得怎樣？", systemImage: "chart.bar", prompt: "我最近背得怎樣？"),
        Suggestion(title: "印出最常忘的 30 個字", systemImage: "printer", prompt: "印出最常忘的 30 個字"),
    ]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if session.isEmpty {
                        emptyState
                    }
                    ForEach(session.messages) { message in
                        Group {
                            switch message.role {
                            case .user: UserBubble(message: message)
                            case .model: ModelReply(message: message)
                            }
                        }
                        .id(message.id)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    if let progress = session.progress {
                        ProgressLine(text: progress)
                            .id("progress")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, Theme.Spacing.page)
                .padding(.top, 8)
                .animation(.snappy(duration: 0.25), value: session.messages.count)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: session.messages.count) {
                withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: session.progress) {
                withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .erPageBackground()
        .safeAreaInset(edge: .bottom) {
            InputBar(text: $draft, images: $images, isBusy: session.isBusy, focus: $isFocused,
                     isScanning: $isScanning, send: send)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
        }
        .navigationTitle("助理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("模式", selection: Bindable(session).mode) {
                        ForEach(AssistantMode.allCases) { mode in
                            Text(mode == .precise ? "精準（比較慢）" : "一般").tag(mode)
                        }
                    }
                    Section("這次對話用量") {
                        Text("輸入 \(session.usage.input.formatted()) tokens")
                        Text("快取讀取 \(session.usage.cacheRead.formatted()) tokens")
                        Text("快取寫入 \(session.usage.cacheWrite.formatted()) tokens")
                        Text("輸出（含思考） \(session.usage.output.formatted()) tokens")
                    }
                } label: {
                    Image(systemName: session.mode == .precise ? "scope" : "slider.horizontal.3")
                }
                .accessibilityLabel("模式與用量")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("新對話", systemImage: "square.and.pencil") {
                    withAnimation(.snappy(duration: 0.25)) { session.reset() }
                    draft = ""
                    images = []
                }
                .disabled(session.isEmpty)
            }
        }
        .sensoryFeedback(.selection, trigger: session.mode)
        .onAppear { session.modelContext = context }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.stack) {
            Text("想做什麼？")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.er.text)
                .padding(.top, 24)
                .padding(.horizontal, 2)
            VStack(spacing: 0) {
                ForEach(Self.suggestions) { suggestion in
                    Button {
                        if let prompt = suggestion.prompt {
                            session.send(text: prompt)
                        } else {
                            isScanning = true
                        }
                    } label: {
                        HStack(spacing: Theme.Spacing.row) {
                            Image(systemName: suggestion.systemImage)
                                .font(.body.weight(.medium))
                                .foregroundStyle(Color.er.textSecondary)
                                .frame(width: 28)
                            Text(suggestion.title)
                                .font(.body)
                                .foregroundStyle(Color.er.text)
                            Spacer(minLength: 8)
                            Image(systemName: suggestion.prompt == nil ? "chevron.forward" : "arrow.up.circle")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Color.er.textTertiary)
                        }
                        .padding(Theme.Spacing.card)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if suggestion.id != Self.suggestions.last?.id {
                        Divider().overlay(Color.er.outline).padding(.leading, 54)
                    }
                }
            }
            .erCard(padding: 0, elevated: true)
        }
        .transition(.opacity)
    }

    private func send() {
        let text = draft
        let attached = images
        draft = ""
        images = []
        session.send(text: text.isEmpty && !attached.isEmpty ? "把圖片裡的單字加進牌組" : text, images: attached)
    }
}

#Preview("淺色") {
    NavigationStack {
        ChatView()
    }
    .environment(ChatSession(previewMessages: PreviewChat.messages))
    .previewEnvironment()
}

#Preview("深色") {
    NavigationStack {
        ChatView()
    }
    .environment(ChatSession(previewMessages: PreviewChat.messages))
    .previewEnvironment()
    .preferredColorScheme(.dark)
}

#Preview("空白") {
    NavigationStack {
        ChatView()
    }
    .environment(ChatSession())
    .previewEnvironment()
    .preferredColorScheme(.dark)
}

/// 預覽用的對話
enum PreviewChat {
    static var messages: [ChatMessage] {
        let user = ChatMessage(role: .user, text: "把這張的單字加進「第 3 課」")
        let words = WordProposal(deck: "第 3 課", items: [
            .init(word: "absolute", pos: "adj.", zh: "完全的；絕對的", example: "The teacher gave us absolute freedom.",
                  exampleZh: "老師給我們完全的自由。", libraryWordID: "w:absolute"),
            .init(word: "photosynthesis", pos: "n.", zh: "光合作用", example: "Plants make food through photosynthesis.",
                  exampleZh: "植物透過光合作用製造養分。", libraryWordID: nil),
        ], rejected: [], state: .added("已加入 2 個字到〈第 3 課〉"))
        let reply = ChatMessage(role: .model, text: "共 **2** 個字：1 個來自單字庫，1 個是我寫的。\n- absolute\n- photosynthesis",
                                cards: [
                                    ToolCard(kind: .recognition(RecognitionCard(messageID: user.id, transcript: "absolute\nphotosynthesis",
                                                                                imageType: "handwritten", uncertain: ["photosynthesis"]))),
                                    ToolCard(kind: .words(words)),
                                ])
        let ask = ChatMessage(role: .user, text: "我最近背得怎樣？")
        let stats = ChatMessage(role: .model, text: "這 7 天複習了 260 張，答對率 84%。", cards: [
            ToolCard(kind: .learning(LearningCard(title: "學習總覽", numbers: [
                .init(title: "今天複習", value: "42"), .init(title: "答對率", value: "86%"),
                .init(title: "今天到期", value: "35"), .init(title: "連續天數", value: "5"),
            ], daily: [30, 42, 0, 51, 38, 60, 42], words: []))),
        ])
        return [user, reply, ask, stats]
    }
}
