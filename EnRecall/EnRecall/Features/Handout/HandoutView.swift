import SwiftUI
import SwiftData
import QuickLook
import UIKit

extension HandoutOptions {
    /// 上次在設定頁選的（首頁一鍵產生用）
    static var saved: HandoutOptions {
        let defaults = UserDefaults.standard
        var options = HandoutOptions()
        if let raw = defaults.string(forKey: SettingsKey.handoutKind), let kind = HandoutKind(rawValue: raw) { options.kind = kind }
        if let raw = defaults.string(forKey: SettingsKey.handoutRange), let range = HandoutRange(rawValue: raw) { options.range = range }
        if let deck = defaults.string(forKey: SettingsKey.handoutDeck), !deck.isEmpty { options.deckID = deck }
        if defaults.object(forKey: SettingsKey.handoutCount) != nil { options.count = defaults.integer(forKey: SettingsKey.handoutCount) }
        if let raw = defaults.string(forKey: SettingsKey.handoutAmount), let amount = HandoutAmount(rawValue: raw) { options.amount = amount }
        if let raw = defaults.string(forKey: SettingsKey.handoutDirection), let direction = HandoutDirection(rawValue: raw) { options.direction = direction }
        return options
    }

    /// 首頁那一列的說明：「講義 · 最常忘 · 30 字」
    var summary: String {
        "\(kind.title) · \(range == .deck ? "牌組" : range.title) · \(count) 字"
    }
}

extension HandoutStyle {
    /// 跟著 App 現在的配色：取主色的淺色版本（紙是白的）
    @MainActor static var current: HandoutStyle {
        let color = UIColor(Color.er.primary).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return .ink }
        return HandoutStyle(red: Double(red), green: Double(green), blue: Double(blue))
    }
}

enum HandoutMaker {
    enum Failure: LocalizedError {
        case empty(HandoutRange)

        var errorDescription: String? {
            switch self {
            case .empty(.weakest): "還沒有背過的字"
            case .empty(.today): "今天還沒有背過字"
            case .empty(.recent): "最近 7 天沒有背過字"
            case .empty(.deck): "這個牌組沒有字"
            }
        }
    }

    /// 挑字 → 排版 → PDF，存成暫存檔給預覽、分享、列印
    @MainActor
    static func make(_ options: HandoutOptions, context: ModelContext, now: Date = Date()) async throws -> URL {
        let entries = try HandoutBuilder.entries(options, context: context, now: now)
        guard !entries.isEmpty else { throw Failure.empty(options.range) }
        let range = HandoutBuilder.rangeTitle(options, context: context)
        let html = HandoutHTML.document(entries: entries, options: options, rangeTitle: range, date: now, style: .current)
        var footer = range
        if options.kind == .notes { footer += " · \(options.amount.title)份量" }
        if options.kind == .test { footer += " · \(options.direction.title)" }
        let data = try await PDFRenderer.render(html: html, footer: footer)

        let day = now.formatted(.iso8601.year().month().day())
        let name = "單字\(options.kind.title)-\(range)-\(day).pdf"
            .replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }
}

/// 單字 PDF：講義、自測卷、速查表，做好直接預覽，可以分享或列印
struct HandoutView: View {
    /// 從牌組打開：範圍預設是這個牌組
    var presetDeckID: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \Deck.sortIndex) private var decks: [Deck]

    @AppStorage(SettingsKey.handoutKind) private var kind = HandoutKind.notes
    @AppStorage(SettingsKey.handoutRange) private var range = HandoutRange.weakest
    @AppStorage(SettingsKey.handoutDeck) private var deckID = ""
    @AppStorage(SettingsKey.handoutCount) private var count = 30
    @AppStorage(SettingsKey.handoutAmount) private var amount = HandoutAmount.standard
    @AppStorage(SettingsKey.handoutDirection) private var direction = HandoutDirection.zhToEn

    @State private var isMaking = false
    @State private var message: String?
    @State private var previewURL: URL?

    private static let counts = [20, 30, 50, 100]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.stack) {
                    SectionHeader(title: "用途")
                    VStack(spacing: 0) {
                        ForEach(HandoutKind.allCases) { option in
                            OptionRow(title: option.title, subtitle: option.subtitle, isSelected: option == kind) {
                                kind = option
                            }
                            if option != HandoutKind.allCases.last {
                                Divider().overlay(Color.er.outline).padding(.leading, Theme.Spacing.card)
                            }
                        }
                    }
                    .erCard(padding: 0)
                    .sensoryFeedback(.selection, trigger: kind)

                    SectionHeader(title: "範圍")
                    Picker("範圍", selection: $range) {
                        ForEach(HandoutRange.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    if range == .deck {
                        Picker("牌組", selection: $deckID) {
                            ForEach(decks) { Text($0.name).tag($0.id) }
                        }
                        .pickerStyle(.menu)
                        .tint(Color.er.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .erCard(padding: Theme.Spacing.row)
                    }

                    SectionHeader(title: "字數", trailing: "最多")
                    Picker("字數", selection: $count) {
                        ForEach(Self.counts, id: \.self) { Text($0.formatted()).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    switch kind {
                    case .notes:
                        SectionHeader(title: "份量")
                        Picker("份量", selection: $amount) {
                            ForEach(HandoutAmount.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    case .test:
                        SectionHeader(title: "方向")
                        Picker("方向", selection: $direction) {
                            ForEach(HandoutDirection.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    case .sheet:
                        EmptyView()
                    }

                    if let message {
                        EmptyLine(message)
                    }

                    Button(action: make) {
                        HStack(spacing: 8) {
                            if isMaking { ProgressView().tint(Color.er.onPrimary) }
                            Text(isMaking ? "製作中" : "產生 PDF")
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .disabled(isMaking || (range == .deck && deckID.isEmpty))
                    .padding(.top, 8)
                }
                .padding(.horizontal, Theme.Spacing.page)
                .padding(.bottom, 24)
            }
            .erPageBackground()
            .navigationTitle("單字 PDF")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("關閉", systemImage: "xmark") { dismiss() }
                }
            }
        }
        .quickLookPreview($previewURL)
        .sensoryFeedback(.success, trigger: previewURL) { _, new in new != nil }
        .onAppear {
            if let presetDeckID {
                range = .deck
                deckID = presetDeckID
            } else if deckID.isEmpty || !decks.contains(where: { $0.id == deckID }) {
                deckID = decks.first?.id ?? ""
            }
        }
        .onChange(of: kind) { message = nil }
        .onChange(of: range) { message = nil }
    }

    private func make() {
        let options = HandoutOptions(kind: kind, range: range, deckID: deckID.isEmpty ? nil : deckID,
                                     count: count, amount: amount, direction: direction)
        isMaking = true
        message = nil
        Task {
            do {
                previewURL = try await HandoutMaker.make(options, context: context)
            } catch {
                message = error.localizedDescription
            }
            isMaking = false
        }
    }
}

private struct OptionRow: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: Theme.Spacing.row) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.er.text)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.er.textSecondary)
                }
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.er.primary : Color.er.outlineStrong)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(Theme.Spacing.card)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview("淺色") {
    HandoutView()
        .previewEnvironment()
}

#Preview("深色") {
    HandoutView(presetDeckID: "custom:preview")
        .previewEnvironment()
        .preferredColorScheme(.dark)
}
