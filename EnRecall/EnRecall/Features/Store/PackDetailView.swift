import SwiftUI
import SwiftData

struct PackDetailView: View {
    let pack: StorePack

    @Environment(StoreModel.self) private var store
    @Environment(ToastCenter.self) private var toasts
    @Query(sort: \Deck.sortIndex) private var decks: [Deck]

    /// 單字包支援的內容（學測單字包都有；片語包只有例句與用法）
    private var features: [String] {
        pack.category == .phrase
            ? ["例句", "用法", "分類"]
            : ["一字多義", "例句", "搭配", "近義字", "反義字", "易混淆字", "常見錯誤", "字源拆解"]
    }

    var body: some View {
        let status = store.status(of: pack, decks: decks)
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.stack) {
                header
                PackStatsRow(pack: pack)
                    .padding(.vertical, 6)
                actionButton(status)
                Text(caption(status))
                    .font(.caption)
                    .foregroundStyle(Color.er.textTertiary)
                    .frame(maxWidth: .infinity)

                if let preview = pack.preview, !preview.isEmpty {
                    SectionHeader(title: "試看")
                    ScrollView(.horizontal) {
                        HStack(spacing: 10) {
                            ForEach(preview, id: \.w) { PreviewWordCard(word: $0) }
                        }
                        .padding(.horizontal, Theme.Spacing.page)
                    }
                    .scrollIndicators(.hidden)
                    .padding(.horizontal, -Theme.Spacing.page)
                }

                SectionHeader(title: "支援項目")
                FlowLayout(spacing: 6) {
                    ForEach(features, id: \.self) { Chip(text: $0, style: .info) }
                }

                SectionHeader(title: "關於這個單字包")
                VStack(alignment: .leading, spacing: 12) {
                    if let desc = pack.desc {
                        Text(desc)
                            .font(.subheadline)
                            .foregroundStyle(Color.er.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Divider().overlay(Color.er.outline)
                    LabeledContent("版本") {
                        Text("v\(pack.version)").font(.erMono)
                    }
                    if let date = updatedDate {
                        LabeledContent("更新") {
                            Text(date, format: .dateTime.year().month().day())
                        }
                    }
                }
                .font(.subheadline)
                .foregroundStyle(Color.er.textSecondary)
                .erCard(elevated: true)
            }
            .padding(.horizontal, Theme.Spacing.page)
            .padding(.bottom, 24)
        }
        .erPageBackground()
        .navigationBarTitleDisplayMode(.inline)
    }

    private var updatedDate: Date? {
        guard let updated = pack.updated else { return nil }
        return try? Date(updated, strategy: .iso8601.year().month().day())
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                IconTile(label: pack.tileLabel, size: 112, style: .info)
                if pack.level != nil {
                    LevelRing(level: pack.level)
                        .frame(width: 84, height: 84)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(pack.title)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Color.er.text)
                    .minimumScaleFactor(0.7)
                if pack.official == true {
                    Label("\(pack.author ?? "EnRecall") 官方", systemImage: "checkmark.seal.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.er.info)
                }
                if let subtitle = pack.subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(Color.er.textSecondary)
                }
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func actionButton(_ status: PackStatus) -> some View {
        switch status {
        case .downloading(let progress):
            ProgressView(value: progress)
                .tint(Color.er.primary)
                .frame(minHeight: 50)
        case .downloaded:
            Button {
                toasts.show("已在牌組裡", systemImage: "rectangle.stack")
            } label: {
                Text("已下載")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
        case .notDownloaded, .updateAvailable:
            Button {
                toasts.show("下載功能下一版加上", systemImage: "hammer")
            } label: {
                Text("\(status == .updateAvailable ? "更新" : "下載") · \(pack.downloadSizeText)")
                    .font(.headline)
                    .foregroundStyle(Color.er.onPrimary)
                    .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
        }
    }

    private func caption(_ status: PackStatus) -> String {
        switch status {
        case .updateAvailable: "更新只換字義與例句，複習進度保留"
        case .downloaded: "在「牌組」調整每天新卡"
        default: "下載後在「牌組」出現，離線也能複習"
        }
    }
}

/// 個字／例句／下載／安裝後 四欄
private struct PackStatsRow: View {
    let pack: StorePack

    var body: some View {
        HStack(spacing: 0) {
            cell(value: (pack.words ?? 0).formatted(), label: pack.category == .phrase ? "個片語" : "個字")
            Divider().frame(height: 32)
            cell(value: pack.category == .phrase ? "有" : "每字", label: "例句")
            Divider().frame(height: 32)
            cell(value: pack.downloadSizeText, label: "下載")
            Divider().frame(height: 32)
            cell(value: pack.installedSizeText, label: "安裝後")
        }
    }

    private func cell(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(Color.er.text)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(label)
                .font(.caption)
                .foregroundStyle(Color.er.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct PreviewWordCard: View {
    let word: StorePack.PreviewWord

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(word.w)
                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.er.text)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let pos = word.pos, !pos.isEmpty {
                Chip(text: pos, style: .info)
            }
            Text(word.zh)
                .font(.subheadline)
                .foregroundStyle(Color.er.textSecondary)
                .lineLimit(2, reservesSpace: true)
        }
        .frame(width: 160, alignment: .leading)
        .erCard(elevated: true)
    }
}

#Preview("淺色") {
    NavigationStack {
        PackDetailView(pack: PreviewData.packs[3])
    }
    .previewEnvironment()
}

#Preview("深色") {
    NavigationStack {
        PackDetailView(pack: PreviewData.packs[1])
    }
    .previewEnvironment()
    .preferredColorScheme(.dark)
}
