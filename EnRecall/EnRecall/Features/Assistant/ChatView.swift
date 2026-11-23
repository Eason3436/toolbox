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
        /// 粗體那行（動作）
        let title: String
        /// 下面那行
        let detail: String
        let prompt: String
        /// false：先放進輸入框讓人接著貼文章，不直接送出
        var sendsNow = true
        var id: String { title + detail }
    }

    private static let suggestions: [Suggestion] = [
        Suggestion(title: "看看", detail: "最近背得怎樣", prompt: "我最近背得怎樣？"),
        Suggestion(title: "印出", detail: "最常忘的 30 個字", prompt: "印出最常忘的 30 個字"),
        Suggestion(title: "整理", detail: "文章裡的句型", prompt: "把這篇文章的句型整理成卡片：\n", sendsNow: false),
        Suggestion(title: "找出", detail: "我常搞混的字", prompt: "我最常答錯、容易搞混的是哪些字？"),
    ]

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
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
        .overlay {
            if session.isEmpty {
                emptyState
                    .transition(.opacity)
            }
        }
        .background {
            AssistantBackground(isEmpty: session.isEmpty)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                if session.isEmpty && images.isEmpty {
                    suggestionStrip
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                InputBar(text: $draft, images: $images, isBusy: session.isBusy, focus: $isFocused,
                         isScanning: $isScanning, send: send)
                    .padding(.horizontal, Theme.Spacing.page)
            }
            .padding(.bottom, 8)
            .animation(.snappy(duration: 0.25), value: session.isEmpty)
        }
        .navigationTitle("助理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                modeMenu
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

    /// 標題：目前的模式，點開切換、看這次用量
    private var modeMenu: some View {
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
            HStack(spacing: 4) {
                Text(session.mode == .precise ? "精準模式" : "助理")
                    .font(.headline)
                    .foregroundStyle(Color.er.text)
                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.er.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .accessibilityLabel("模式與用量")
    }

    /// 空白時畫面中間：一句話＋拍照鍵
    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("想做什麼？")
                .font(.title2.weight(.bold))
                .foregroundStyle(Color.er.text)
            Text("拍課本或單字表加進牌組、貼一段文章整理句型，\n或問問最近背得怎樣")
                .font(.subheadline)
                .foregroundStyle(Color.er.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                isScanning = true
            } label: {
                Label("拍照加單字", systemImage: "camera")
                    .font(.headline)
                    .foregroundStyle(Color.er.text)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .modifier(AssistantGlass(shape: Capsule(), solid: reduceTransparency))
            .padding(.top, 10)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 往上一點，避開下面的建議和輸入框
        .padding(.bottom, 60)
    }

    /// 輸入框上面一排可以橫滑的建議
    private var suggestionStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(Self.suggestions) { suggestion in
                    Button {
                        use(suggestion)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.title)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(Color.er.text)
                            Text(suggestion.detail)
                                .font(.subheadline)
                                .foregroundStyle(Color.er.textSecondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .frame(minWidth: 112, alignment: .leading)
                        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .modifier(AssistantGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous),
                                             solid: reduceTransparency))
                }
            }
            .padding(.horizontal, Theme.Spacing.page)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }

    private func use(_ suggestion: Suggestion) {
        if suggestion.sendsNow {
            session.send(text: suggestion.prompt)
        } else {
            draft = suggestion.prompt
            isFocused = true
        }
    }

    private func send() {
        let text = draft
        let attached = images
        draft = ""
        images = []
        session.send(text: text.isEmpty && !attached.isEmpty ? "把圖片裡的單字加進牌組" : text, images: attached)
    }
}

/// 助理頁背景：上面一層主色漸層，往下淡到頁面底色；開始對話後變淡，訊息才好讀
private struct AssistantBackground: View {
    let isEmpty: Bool

    var body: some View {
        ZStack {
            Color.er.background
            LinearGradient(stops: [
                .init(color: Color.er.primary.opacity(isEmpty ? 0.45 : 0.16), location: 0),
                .init(color: Color.er.primary.opacity(isEmpty ? 0.16 : 0.05), location: 0.4),
                .init(color: Color.er.primary.opacity(0), location: 0.7),
            ], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color.er.info.opacity(isEmpty ? 0.22 : 0.06), Color.er.info.opacity(0)],
                           center: .topTrailing, startRadius: 0, endRadius: 420)
        }
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.35), value: isEmpty)
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
