import SwiftUI

/// 追問畫面：對某天、某堂課或最近幾天的逐字稿提問。
struct AskView: View {
    let initialScope: AskScope
    @Environment(RecapStore.self) private var store
    @State private var scope: AskScope?
    @State private var question = ""
    @State private var turns: [Turn] = []
    @State private var asking = false
    @FocusState private var focused: Bool

    struct Turn: Identifiable {
        let id = UUID()
        let question: String
        var answer: String?
        var sources: [Passage] = []
        var error: String?
    }

    private var currentScope: AskScope { scope ?? initialScope }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if turns.isEmpty {
                        Card {
                            Label("問問看", systemImage: "questionmark.bubble").font(.headline).foregroundStyle(.tint)
                            Text("例如：「老闆說報告什麼時候要交？」、「教授提到的 opportunity cost 是什麼意思？」。會先從逐字稿找出相關的段落，再用 Apple Intelligence 回答，並附上出處。")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(turns) { turn in
                        TurnView(turn: turn)
                            .id(turn.id)
                    }
                    if asking {
                        HStack(spacing: 8) { ThinkingIndicator(activity: .searching); Text("從逐字稿裡找…").foregroundStyle(.secondary) }
                    }
                }
                .padding(16)
            }
            .scrollEdgeEffectStyle(.soft, for: .all)
            .onChange(of: turns.count) {
                if let last = turns.last { withAnimation { proxy.scrollTo(last.id, anchor: .top) } }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 10) {
                TextField("追問…", text: $question, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($focused)
                    .submitLabel(.send)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title)
                }
                .accessibilityLabel("送出")
                .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || asking)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
        .navigationTitle("追問")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if case .lecture = initialScope {} else {
                Menu {
                    Button(initialScope.title) { scope = initialScope }
                    Button("最近 7 天") { scope = .recent(7) }
                    Button("最近 30 天") { scope = .recent(30) }
                } label: {
                    Label(currentScope.title, systemImage: "line.3.horizontal.decrease.circle")
                }
            }
        }
    }

    private func send() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !asking else { return }
        question = ""
        Haptics.tap()
        let previous = turns.last.flatMap { t in t.answer.map { (q: t.question, a: $0) } }
        turns.append(Turn(question: q))
        let index = turns.count - 1
        asking = true
        let passages = AskService.passages(for: currentScope, store: store)
        Task {
            defer { asking = false }
            do {
                let result = try await AskService.ask(q, passages: passages, previous: previous)
                turns[index].answer = result.answer
                turns[index].sources = result.sources
                Haptics.success()
            } catch {
                turns[index].error = Summarizer.describe(error)
                Haptics.error()
            }
        }
    }
}

private struct TurnView: View {
    let turn: AskView.Turn

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer(minLength: 40)
                Text(turn.question)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color.accentColor.opacity(0.18), in: .rect(cornerRadius: 18))
            }
            if let answer = turn.answer {
                Text(answer).textSelection(.enabled)
                if !turn.sources.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("出處").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(turn.sources) { source in
                            SourceRow(passage: source)
                        }
                    }
                }
            } else if let error = turn.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        }
    }
}

private struct SourceRow: View {
    let passage: Passage

    var body: some View {
        Group {
            if let route = passage.segmentRoute {
                NavigationLink(value: route) { content }
            } else if let id = passage.lectureID {
                NavigationLink(value: LectureRoute(id: id)) { content }
            } else {
                content
            }
        }
        .buttonStyle(.plain)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(passage.label).font(.caption.monospacedDigit()).foregroundStyle(.tint)
            Text(passage.text).font(.footnote).foregroundStyle(.secondary).lineLimit(4)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.tertiary, in: .rect(cornerRadius: 12))
    }
}
