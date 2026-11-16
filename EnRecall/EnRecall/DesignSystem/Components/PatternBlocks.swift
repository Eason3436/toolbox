import SwiftUI

// 句型卡的內容區塊：卡片背面的分頁和單字頁共用

/// 句型公式：「It is not until + 時間／子句 + that + S + V」
struct PatternFormula: View {
    let text: String
    var size: CGFloat = 20

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(Color.er.text)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 一個空格：可以放什麼、例子
struct PatternSlotLine: View {
    let slot: PatternDetail.Slot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(slot.slot)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.er.info)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.er.infoContainer, in: Capsule())
                if let accepts = slot.accepts {
                    Text(accepts)
                        .font(.subheadline)
                        .foregroundStyle(Color.er.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !slot.examples.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(Array(slot.examples.enumerated()), id: \.offset) { _, example in
                        Text(example)
                            .font(.subheadline)
                            .foregroundStyle(Color.er.textSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.er.fill, in: Capsule())
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// 例句（雜誌原句會標出處）
struct PatternExampleBlock: View {
    let example: PatternDetail.Example

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ExampleLines(en: example.en, zh: example.zh)
            if let source = example.source {
                Label(source, systemImage: "book.closed")
                    .font(.caption)
                    .foregroundStyle(Color.er.textTertiary)
            }
        }
    }
}

/// 用法說明、語氣、記法
struct PatternUsageBlock: View {
    let pattern: PatternDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if pattern.level != nil || pattern.register != nil {
                FlowLayout(spacing: 6) {
                    if let level = pattern.level {
                        Chip(text: level, style: .info)
                    }
                    if let register = pattern.register {
                        Chip(text: register)
                    }
                }
            }
            if let explanation = pattern.explanation {
                Text(explanation)
                    .font(.body)
                    .foregroundStyle(Color.er.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let tips = pattern.tips {
                VStack(alignment: .leading, spacing: 4) {
                    DetailLabel("記法")
                    Text(tips)
                        .font(.subheadline)
                        .foregroundStyle(Color.er.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 其他寫法（倒裝、省略…）
struct PatternVariationBlock: View {
    let variation: PatternDetail.Variation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PatternFormula(text: variation.form, size: 17)
            if let note = variation.note {
                Text(note)
                    .font(.subheadline)
                    .foregroundStyle(Color.er.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let en = variation.en {
                ExampleLines(en: en, zh: variation.zh)
            }
        }
    }
}

struct PatternCollocationLine: View {
    let item: PatternDetail.Collocation

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 5))
                .foregroundStyle(Color.er.textTertiary)
                .frame(width: 14)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.en)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.er.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let zh = item.zh {
                    Text(zh)
                        .font(.subheadline)
                        .foregroundStyle(Color.er.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 相近句型比較
struct PatternSimilarBlock: View {
    let item: PatternDetail.Similar

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PatternFormula(text: item.pattern, size: 17)
            if let diff = item.diff {
                Text(diff)
                    .font(.subheadline)
                    .foregroundStyle(Color.er.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let en = item.en {
                ExampleLines(en: en, zh: item.zh)
            }
        }
    }
}

struct PatternErrorBlock: View {
    let item: PatternDetail.ErrorItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let wrong = item.wrong { VerdictLine(isCorrect: false, text: wrong) }
            if let right = item.right { VerdictLine(isCorrect: true, text: right) }
            if let note = item.note {
                Text(note)
                    .font(.subheadline)
                    .foregroundStyle(Color.er.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - 單字頁用：整份句型內容

struct PatternDetailContent: View {
    let pattern: PatternDetail

    var body: some View {
        if pattern.explanation != nil || pattern.tips != nil || pattern.level != nil || pattern.register != nil {
            PatternUsageBlock(pattern: pattern)
                .erCard()
        }
        if !pattern.slots.isEmpty {
            SectionHeader(title: "結構")
            separated(pattern.slots) { PatternSlotLine(slot: $0) }
        }
        if !pattern.examples.isEmpty {
            SectionHeader(title: "例句", trailing: pattern.examples.count.formatted())
            separated(pattern.examples) { PatternExampleBlock(example: $0) }
        }
        if !pattern.variations.isEmpty {
            SectionHeader(title: "變化")
            separated(pattern.variations) { PatternVariationBlock(variation: $0) }
        }
        if !pattern.collocations.isEmpty {
            SectionHeader(title: "搭配")
            separated(pattern.collocations) { PatternCollocationLine(item: $0) }
        }
        if !pattern.similar.isEmpty {
            SectionHeader(title: "相近句型")
            separated(pattern.similar) { PatternSimilarBlock(item: $0) }
        }
        if !pattern.errors.isEmpty {
            SectionHeader(title: "常見錯誤")
            separated(pattern.errors) { PatternErrorBlock(item: $0) }
        }
    }

    private func separated<Item, Row: View>(_ items: [Item], @ViewBuilder row: @escaping (Item) -> Row) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 { Divider().overlay(Color.er.outline) }
                row(item)
            }
        }
        .erCard()
    }
}
