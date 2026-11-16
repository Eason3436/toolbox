import SwiftUI
import SwiftData

/// 測驗：選題型、範圍、題數 → 一題一題打字作答 → 結果（答錯的字可以排進今天的複習）。
/// 測驗不改 FSRS 進度
struct QuizView: View {
    private enum Phase {
        case setup
        case running
        case finished
    }

    struct Record: Identifiable {
        let question: QuizQuestion
        let typed: String
        let isCorrect: Bool

        var id: UUID { question.id }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \Deck.sortIndex) private var decks: [Deck]

    @AppStorage(SettingsKey.quizKind) private var kind = QuizKind.zhToEn
    @AppStorage(SettingsKey.quizScope) private var scope = QuizScope.learned
    @AppStorage(SettingsKey.quizCount) private var count = 10

    @State private var phase = Phase.setup
    @State private var questions: [QuizQuestion] = []
    @State private var index = 0
    @State private var answer = ""
    @State private var isCorrect: Bool?
    @State private var showsLetters = false
    @State private var records: [Record] = []
    @State private var emptyMessage: String?
    @State private var scheduledWrong = false
    /// 排進複習了幾個（還沒背過的字不動）
    @State private var scheduledCount = 0
    @FocusState private var isTyping: Bool

    private var availableKinds: [QuizKind] {
        let categories = Set(decks.map(\.category))
        return QuizKind.allCases.filter { categories.contains($0.category) }
    }

    private var current: QuizQuestion? { questions.indices.contains(index) ? questions[index] : nil }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .setup: setup
                case .running: running
                case .finished: finished
                }
            }
            .erPageBackground()
            .navigationTitle(phase == .running ? kind.title : "測驗")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("關閉", systemImage: "xmark") { dismiss() }
                }
                if phase == .running {
                    ToolbarItem(placement: .principal) {
                        Text("\((index + 1).formatted()) / \(questions.count.formatted())")
                            .font(.erMono.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(Color.er.textSecondary)
                    }
                }
            }
            .animation(.spring(duration: 0.35), value: phase)
        }
        .sensoryFeedback(trigger: isCorrect) { _, new in
            guard let new else { return nil }
            return new ? .success : .error
        }
    }

    // MARK: 設定

    private var setup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.stack) {
                SectionHeader(title: "題型")
                VStack(spacing: 0) {
                    ForEach(availableKinds) { option in
                        KindRow(kind: option, isSelected: option == kind) {
                            kind = option
                            emptyMessage = nil
                        }
                        if option != availableKinds.last {
                            Divider().overlay(Color.er.outline).padding(.leading, Theme.Spacing.card)
                        }
                    }
                }
                .erCard(padding: 0)
                .sensoryFeedback(.selection, trigger: kind)

                SectionHeader(title: "範圍")
                Picker("範圍", selection: $scope) {
                    ForEach(QuizScope.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                SectionHeader(title: "題數")
                Picker("題數", selection: $count) {
                    ForEach([10, 20, 30], id: \.self) { Text($0.formatted()).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if let emptyMessage {
                    EmptyLine(emptyMessage)
                }

                Button(action: start) {
                    Text("開始")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
                .disabled(availableKinds.isEmpty)
            }
            .padding(.horizontal, Theme.Spacing.page)
            .padding(.bottom, 24)
        }
        .onAppear {
            if !availableKinds.contains(kind), let first = availableKinds.first { kind = first }
        }
    }

    private func start() {
        let made = (try? QuizBuilder.questions(kind: kind, scope: scope, count: count, context: context)) ?? []
        guard !made.isEmpty else {
            emptyMessage = scope == .learned ? "背過的字裡沒有可以出這種題的，換成「全部」試試" : "沒有可以出這種題的字"
            return
        }
        questions = made
        index = 0
        records = []
        scheduledWrong = false
        resetAnswer()
        phase = .running
        isTyping = true
    }

    // MARK: 作答

    @ViewBuilder
    private var running: some View {
        if let question = current {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.stack) {
                    ProgressView(value: Double(index), total: Double(max(questions.count, 1)))
                        .tint(Color.er.primary)
                        .accessibilityLabel("第 \(index + 1) 題，共 \(questions.count) 題")

                    QuizQuestionCard(question: question, showsLetters: showsLetters, isCorrect: isCorrect)
                        .id(question.id)
                        .transition(.push(from: .trailing))

                    answerField

                    if isCorrect != nil {
                        feedback(for: question)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, Theme.Spacing.page)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.never)
            .safeAreaInset(edge: .bottom) {
                actionBar
                    .padding(.horizontal, Theme.Spacing.page)
                    .padding(.bottom, 8)
            }
        }
    }

    private var answerField: some View {
        TextField("輸入英文", text: $answer)
            .font(.title3.weight(.medium))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.asciiCapable)
            .submitLabel(.done)
            .focused($isTyping)
            .onSubmit {
                if isCorrect == nil { submit() } else { next() }
            }
            .disabled(isCorrect != nil)
            .padding(.horizontal, 14)
            .frame(minHeight: 52)
            .background(Color.er.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: isCorrect == nil ? 1 : 2)
            )
    }

    private var borderColor: Color {
        switch isCorrect {
        case .some(true): Color.er.ratingGood
        case .some(false): Color.er.danger
        case .none: Color.er.outline
        }
    }

    private func feedback(for question: QuizQuestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(isCorrect == true ? "答對了" : "正確答案", systemImage: isCorrect == true ? "checkmark.circle.fill" : "lightbulb")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isCorrect == true ? Color.er.ratingGood : Color.er.textSecondary)
            if isCorrect == false {
                Text(question.answers.joined(separator: " / "))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Color.er.text)
            }
            if let reference = question.reference {
                ExampleLines(en: reference, zh: question.promptTranslation)
                    .environment(\.highlighter, Highlighter(word: question.mainAnswer))
            }
            Text("\(question.word)  \(question.zh)")
                .font(.footnote)
                .foregroundStyle(Color.er.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .erCard()
    }

    private var actionBar: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                if isCorrect == nil {
                    Button(showsLetters ? "已提示" : "提示") {
                        withAnimation(.spring(duration: 0.3)) { showsLetters = true }
                    }
                    .buttonStyle(.glass)
                    .disabled(showsLetters)
                    Button("不會") {
                        record(typed: "", correct: false)
                    }
                    .buttonStyle(.glass)
                    Button(action: submit) {
                        Text("送出").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(answer.trimmingCharacters(in: .whitespaces).isEmpty)
                } else {
                    Button(action: next) {
                        Text(index + 1 < questions.count ? "下一題" : "看結果").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                }
            }
            .controlSize(.large)
        }
    }

    private func submit() {
        guard let question = current, isCorrect == nil else { return }
        let typed = answer.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return }
        record(typed: typed, correct: QuizBuilder.isCorrect(typed, for: question))
    }

    private func record(typed: String, correct: Bool) {
        guard let question = current else { return }
        records.append(Record(question: question, typed: typed, isCorrect: correct))
        withAnimation(.spring(duration: 0.3)) { isCorrect = correct }
    }

    private func next() {
        guard isCorrect != nil else { return }
        if index + 1 < questions.count {
            withAnimation(.spring(duration: 0.35)) {
                index += 1
                resetAnswer()
            }
            isTyping = true
        } else {
            isTyping = false
            phase = .finished
        }
    }

    private func resetAnswer() {
        answer = ""
        isCorrect = nil
        showsLetters = false
    }

    // MARK: 結果

    private var finished: some View {
        let correct = records.filter(\.isCorrect).count
        let wrong = records.filter { !$0.isCorrect }
        return ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.stack) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(kind.title)
                        .font(.erLabel)
                        .tracking(1.1)
                        .foregroundStyle(Color.er.textTertiary)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(correct, format: .number)
                            .numberFont(48, relativeTo: .largeTitle, weight: .bold)
                            .foregroundStyle(Color.er.text)
                        Text("/ \(records.count.formatted()) 題答對")
                            .font(.subheadline)
                            .foregroundStyle(Color.er.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .erCard(elevated: true)

                if !wrong.isEmpty {
                    SectionHeader(title: "答錯的字", trailing: wrong.count.formatted())
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(wrong.enumerated()), id: \.element.id) { offset, item in
                            if offset > 0 { Divider().overlay(Color.er.outline) }
                            WrongAnswerRow(record: item)
                        }
                    }
                    .erCard()

                    Button {
                        scheduleWrong(wrong)
                    } label: {
                        Label(scheduledWrong ? scheduledText : "答錯的字排進今天的複習",
                              systemImage: scheduledWrong ? "checkmark" : "calendar.badge.plus")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .disabled(scheduledWrong)
                    .sensoryFeedback(.success, trigger: scheduledWrong)
                }

                HStack(spacing: 8) {
                    Button {
                        phase = .setup
                    } label: {
                        Text("再測一次").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    Button {
                        dismiss()
                    } label: {
                        Text("完成").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, Theme.Spacing.page)
            .padding(.bottom, 24)
        }
    }

    private var scheduledText: String {
        scheduledCount > 0 ? "已排進今天的複習（\(scheduledCount.formatted()) 個）" : "這些字還沒背過或已經到期"
    }

    /// 背過的字：到期日提前到現在（FSRS 照實際間隔計算，不會亂掉）；還沒背的字不動
    private func scheduleWrong(_ wrong: [Record]) {
        let ids = Set(wrong.map(\.question.cardID))
        let now = Date()
        var moved = 0
        for id in ids {
            var descriptor = FetchDescriptor<Card>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            guard let card = try? context.fetch(descriptor).first, !card.isNew else { continue }
            if card.due > now {
                card.due = now
                moved += 1
            }
        }
        try? context.save()
        scheduledCount = moved
        scheduledWrong = true
    }
}

// MARK: - 元件

private struct KindRow: View {
    let kind: QuizKind
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: Theme.Spacing.row) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.er.text)
                    Text(kind.subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.er.textSecondary)
                }
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.er.primary : Color.er.outlineStrong)
            }
            .padding(Theme.Spacing.card)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// 一題：題目句子、翻譯、提示
struct QuizQuestionCard: View {
    let question: QuizQuestion
    let showsLetters: Bool
    let isCorrect: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(question.prompt)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.er.text)
                .fixedSize(horizontal: false, vertical: true)
            if let translation = question.promptTranslation, isCorrect == nil || question.reference == nil {
                Text(translation)
                    .font(.subheadline)
                    .foregroundStyle(Color.er.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if let hint = question.hint, !hint.isEmpty {
                    Chip(text: hint, style: .info)
                }
                if showsLetters {
                    Text(question.letterHint)
                        .font(.erMono.weight(.semibold))
                        .foregroundStyle(Color.er.textSecondary)
                        .transition(.opacity)
                        .accessibilityLabel("提示：\(question.mainAnswer.first.map { String($0) } ?? "") 開頭，\(question.mainAnswer.count) 個字母")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .erCard(elevated: true)
    }
}

private struct WrongAnswerRow: View {
    let record: QuizView.Record

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(record.question.mainAnswer)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.er.text)
                Text(record.question.zh)
                    .font(.subheadline)
                    .foregroundStyle(Color.er.textSecondary)
                    .lineLimit(1)
            }
            if !record.typed.isEmpty {
                Text(record.typed)
                    .font(.subheadline)
                    .strikethrough(color: Color.er.danger.opacity(0.6))
                    .foregroundStyle(Color.er.danger)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private extension QuizQuestion {
    static let preview = QuizQuestion(
        cardID: "w:abandon", word: "abandon", zh: "放棄",
        prompt: "The team had to ＿＿ its outdoor practice because of the storm.",
        promptTranslation: "因為暴風雨，球隊只好放棄戶外練習。", hint: "放棄  v.",
        answers: ["abandon", "give up"],
        reference: "The team had to abandon its outdoor practice because of the storm.", allowsInflections: false
    )
}

#Preview("淺色") {
    QuizView()
        .previewEnvironment()
}

#Preview("深色") {
    QuizView()
        .previewEnvironment()
        .preferredColorScheme(.dark)
}

#Preview("題目 淺色") {
    QuizQuestionCard(question: .preview, showsLetters: true, isCorrect: nil)
        .padding(Theme.Spacing.page)
        .erPageBackground()
}

#Preview("題目 深色") {
    QuizQuestionCard(question: .preview, showsLetters: true, isCorrect: nil)
        .padding(Theme.Spacing.page)
        .erPageBackground()
        .preferredColorScheme(.dark)
}
