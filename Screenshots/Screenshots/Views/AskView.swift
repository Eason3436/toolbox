import SwiftData
import SwiftUI

struct ChatMessage: Identifiable {
    enum Role { case user, assistant }
    let id = UUID()
    var role: Role
    var text: String
    var sourceIDs: [String] = []
    var isLoading = false
}

/// 問答：聊天式介面，回答下方附來源截圖。
struct AskView: View {
    @Environment(AppRouter.self) private var router
    @Environment(QueueStatus.self) private var queueStatus
    @State private var messages: [ChatMessage] = []
    @State private var input = ""
    @State private var isAsking = false
    @FocusState private var inputFocused: Bool

    private let examples = ["上次截的那家拉麵店叫什麼？", "我有哪些還沒用的票券？", "最近截的優惠價格是多少？"]

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if messages.isEmpty { emptyState }
                        ForEach(messages) { message in
                            MessageBubble(message: message).id(message.id)
                        }
                    }
                    .padding(16)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            .safeAreaInset(edge: .bottom) { inputBar }
            .navigationTitle("問答")
            .navigationDestination(for: ScreenshotRoute.self) { route in
                ScreenshotDetailView(assetID: route.assetID)
            }
            .toolbar {
                if !messages.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("清除", systemImage: "trash") { messages.removeAll() }
                    }
                }
            }
            .onAppear { consumePendingQuestion() }
            .onChange(of: router.pendingQuestion) { _, _ in consumePendingQuestion() }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            Text("用一句話問你的截圖").font(.title2.bold())
            Text("會在手機上搜尋截圖內容再回答，找不到就會直接說找不到。")
                .foregroundStyle(.secondary)
            if queueStatus.readiness != .available {
                Text(queueStatus.readiness.message)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            ForEach(examples, id: \.self) { example in
                Button(example) { send(example) }
                    .buttonStyle(.glass)
            }
        }
        .padding(.top, 24)
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("問問截圖…", text: $input, axis: .vertical)
                .lineLimit(1...4)
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit { send(input) }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .glassEffect(in: .rect(cornerRadius: 22))
            Button {
                send(input)
            } label: {
                Image(systemName: "arrow.up")
                    .font(.headline)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAsking)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func consumePendingQuestion() {
        if let question = router.pendingQuestion {
            router.pendingQuestion = nil
            send(question)
        }
    }

    private func send(_ raw: String) {
        let question = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isAsking else { return }
        input = ""
        isAsking = true
        messages.append(ChatMessage(role: .user, text: question))
        let placeholder = ChatMessage(role: .assistant, text: "搜尋截圖中…", isLoading: true)
        messages.append(placeholder)
        let container = AppServices.shared.container
        Task {
            let result = await AskService.ask(question, container: container)
            if let index = messages.firstIndex(where: { $0.id == placeholder.id }) {
                messages[index] = ChatMessage(role: .assistant, text: result.answer, sourceIDs: result.sourceIDs)
            }
            isAsking = false
        }
    }
}

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(message.text)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .foregroundStyle(.white)
                    .background(Color.accentColor, in: .rect(cornerRadius: 20))
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    if message.isLoading { ProgressView() }
                    Text(message.text).textSelection(.enabled)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(in: .rect(cornerRadius: 20))
                if !message.sourceIDs.isEmpty {
                    Text("來源截圖").font(.caption).foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(message.sourceIDs, id: \.self) { id in
                                NavigationLink(value: ScreenshotRoute(assetID: id)) {
                                    SourceThumbnail(assetID: id)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 來源縮圖：先用快取（400px HEIC），沒有再從相簿讀。
struct SourceThumbnail: View {
    let assetID: String
    @Query private var matches: [ScreenshotItem]

    init(assetID: String) {
        self.assetID = assetID
        _matches = Query(filter: #Predicate<ScreenshotItem> { $0.assetID == assetID })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if let cached = ThumbnailCache.image(for: assetID) {
                    Image(uiImage: cached).resizable().scaledToFill()
                } else {
                    AssetThumbnail(assetID: assetID, pointSize: CGSize(width: 96, height: 128))
                }
            }
            .frame(width: 96, height: 128, alignment: .top)
            .clipShape(.rect(cornerRadius: 14))
            Text(matches.first?.title ?? "截圖")
                .font(.caption2)
                .lineLimit(1)
                .frame(width: 96, alignment: .leading)
        }
    }
}
