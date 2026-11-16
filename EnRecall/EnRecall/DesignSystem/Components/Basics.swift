import SwiftUI

// MARK: - 區塊標題

/// 等寬小字、字距 0.1em、第三層文字色
struct SectionHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.erLabel)
                .tracking(1.1)
                .foregroundStyle(Color.er.textTertiary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(.erLabel)
                    .foregroundStyle(Color.er.textTertiary)
            }
        }
        .padding(.top, Theme.Spacing.sectionTop)
        .padding(.horizontal, 2)
    }
}

// MARK: - 小方塊（L1、Ph、自訂牌組的第一個字）

struct IconTile: View {
    enum Style {
        case muted
        case hero
        case info
    }

    let label: String
    var size: CGFloat = 40
    var style: Style = .muted

    private var radius: CGFloat {
        if size >= 100 { return Theme.Radius.tileHero }
        if size >= 60 { return Theme.Radius.tileLarge }
        return Theme.Radius.tile
    }

    private var background: Color {
        switch style {
        case .muted: Color.er.fill
        case .hero: Color.er.heroTile
        case .info: Color.er.infoContainer
        }
    }

    private var foreground: Color {
        switch style {
        case .muted: Color.er.text
        case .hero: Color.er.heroText
        case .info: Color.er.info
        }
    }

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(background)
            .frame(width: size, height: size)
            .overlay {
                Text(label)
                    .font(.system(size: size * 0.36, weight: .semibold, design: .monospaced))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .foregroundStyle(foreground)
                    .padding(4)
            }
            .accessibilityHidden(true)
    }
}

// MARK: - 膠囊標籤

struct Chip: View {
    enum Style {
        case muted
        case info
        case hero
    }

    let text: String
    var systemImage: String?
    var style: Style = .muted

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .imageScale(.small)
            }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .monospacedDigit()
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(foreground)
        .background(background, in: Capsule())
    }

    private var foreground: Color {
        switch style {
        case .muted: Color.er.textSecondary
        case .info: Color.er.info
        case .hero: Color.er.heroText
        }
    }

    private var background: Color {
        switch style {
        case .muted: Color.er.fill
        case .info: Color.er.infoContainer
        case .hero: Color.er.heroTile
        }
    }
}

// MARK: - 進度

/// 圓形進度（下載中的按鈕、商店主卡）
struct ProgressRing: View {
    var progress: Double
    var lineWidth: CGFloat = 3
    var track: Color = Color.er.fill
    var tint: Color = Color.er.primary

    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
        .accessibilityElement()
        .accessibilityLabel("進度")
        .accessibilityValue(Text(progress, format: .percent.precision(.fractionLength(0))))
    }
}

/// 6 等分的級別環：第 level 段亮起（單字包詳細頁的大方塊）
struct LevelRing: View {
    var level: Int?
    var lineWidth: CGFloat = 5
    var track: Color = Color.er.infoTrack
    var tint: Color = Color.er.info

    var body: some View {
        ZStack {
            ForEach(0..<6, id: \.self) { index in
                let start = Double(index) / 6 + 0.012
                let end = Double(index + 1) / 6 - 0.012
                Circle()
                    .trim(from: start, to: end)
                    .stroke(index + 1 == level ? tint : track, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }
        }
        .rotationEffect(.degrees(-90))
        .padding(lineWidth / 2)
        .accessibilityHidden(true)
    }
}

/// 細的水平進度條
struct LinearMeter: View {
    var value: Double
    var tint: Color = Color.er.primary
    var track: Color = Color.er.fill
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule()
                    .fill(tint)
                    .frame(width: proxy.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - 數字卡（紀錄頁上方三格）

struct StatCard: View {
    let title: String
    let value: Int
    var unit: String = "張"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Color.er.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value, format: .number)
                    .numberFont(26, relativeTo: .title, weight: .bold)
                    .foregroundStyle(Color.er.text)
                    .contentTransition(.numericText(value: Double(value)))
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(Color.er.textSecondary)
            }
        }
        .erCard(padding: Theme.Spacing.row, elevated: true)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 一行空狀態

struct EmptyLine: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Color.er.textTertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
    }
}

// MARK: - 自動換行的標籤排列

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

#Preview("淺色") {
    VStack(alignment: .leading, spacing: 12) {
        SectionHeader(title: "練習模式", trailing: "2")
        HStack {
            IconTile(label: "L4")
            IconTile(label: "Ph", size: 64)
            IconTile(label: "L5", size: 64, style: .info)
            LevelRing(level: 4).frame(width: 64, height: 64)
            ProgressRing(progress: 0.4).frame(width: 28, height: 28)
        }
        HStack {
            Chip(text: "新卡 20")
            Chip(text: "例句", style: .info)
        }
        LinearMeter(value: 0.6)
        HStack {
            StatCard(title: "今日複習", value: 52)
            StatCard(title: "今日新學", value: 8)
        }
        FlowLayout {
            ForEach(["一字多義", "例句", "搭配", "近義字", "反義字", "易混淆字"], id: \.self) { Chip(text: $0, style: .info) }
        }
        EmptyLine("還沒有牌組")
    }
    .padding(Theme.Spacing.page)
    .erPageBackground()
}

#Preview("深色") {
    VStack(alignment: .leading, spacing: 12) {
        SectionHeader(title: "練習模式", trailing: "2")
        HStack {
            IconTile(label: "L4")
            IconTile(label: "L5", size: 64, style: .info)
            LevelRing(level: 4).frame(width: 64, height: 64)
        }
        StatCard(title: "今日複習", value: 52)
        EmptyLine("還沒有牌組")
    }
    .padding(Theme.Spacing.page)
    .erPageBackground()
    .preferredColorScheme(.dark)
}
