import SwiftUI
import SwiftData

/// 統計：三類各自的查看、刪除、騰出空間
struct StatsView: View {
    @Environment(\.modelContext) private var context
    @Query private var allStats: [CleanStats]
    @Query private var viewed: [ViewedAsset]
    @AppStorage(SettingsKey.hapticsOn) private var hapticsOn = true
    @State private var confirmReset = false
    @State private var resetTick = 0

    private func stats(_ kind: StatsKind) -> (viewed: Int, deleted: Int, bytes: Int64) {
        let rows = allStats.filter { $0.kind == kind }
        return (rows.reduce(0) { $0 + $1.viewedCount },
                rows.reduce(0) { $0 + $1.deletedCount },
                rows.reduce(Int64(0)) { $0 + $1.freedBytes })
    }

    private var totalBytes: Int64 {
        allStats.reduce(Int64(0)) { $0 + $1.freedBytes }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                freedCard
                ForEach(StatsKind.allCases) { kind in
                    kindCard(kind)
                }
                resetCard
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("統計")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    SettingsView()
                } label: {
                    Label("設定", systemImage: "gearshape")
                }
            }
        }
        .confirmationDialog("重設瀏覽記錄？", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("重設", role: .destructive) {
                StatsRecorder.resetViewed(context: context)
                resetTick += 1
            }
        } message: {
            Text("看過的照片和影片會重新回到隨機池。統計數字不會變。")
        }
        .sensoryFeedback(.success, trigger: resetTick) { _, _ in hapticsOn }
    }

    // MARK: - 騰出空間

    private var freedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("騰出空間")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(totalBytes.formatted(.byteCount(style: .file)))
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
            if totalBytes > 0 {
                ProportionBar(segments: StatsKind.allCases.map { kind in
                    ProportionBar.Segment(id: kind.rawValue, title: kind.title,
                                          value: Double(stats(kind).bytes), color: color(for: kind))
                })
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(breakdownDescription)
            } else {
                Text("還沒刪過東西。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
    }

    private func color(for kind: StatsKind) -> Color {
        switch kind {
        case .photo: .accentColor
        case .screenshot: .orange
        case .video: .purple
        }
    }

    private var breakdownDescription: String {
        StatsKind.allCases
            .map { "\($0.title) \(stats($0).bytes.formatted(.byteCount(style: .file)))" }
            .joined(separator: "，")
    }

    // MARK: - 各類

    private func kindCard(_ kind: StatsKind) -> some View {
        let s = stats(kind)
        return VStack(alignment: .leading, spacing: 12) {
            Label(kind.title, systemImage: kind.systemImage)
                .font(.headline)
            HStack(spacing: 0) {
                number(s.viewed.formatted(), label: "查看")
                Divider().frame(height: 32)
                number(s.deleted.formatted(), label: "刪除")
                Divider().frame(height: 32)
                number(s.bytes.formatted(.byteCount(style: .file)), label: "已清理")
            }
            if s.viewed > 0 {
                Gauge(value: Double(min(s.deleted, s.viewed)), in: 0...Double(s.viewed)) {
                    Text("刪除比例")
                } currentValueLabel: {
                    Text((Double(s.deleted) / Double(s.viewed)).formatted(.percent.precision(.fractionLength(0))))
                }
                .gaugeStyle(.accessoryLinearCapacity)
                .tint(color(for: kind))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
    }

    private func number(_ value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 重設

    private var resetCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(role: .destructive) {
                confirmReset = true
            } label: {
                Label("重設瀏覽記錄", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(viewed.isEmpty)
            Text("已記住 \(viewed.count.formatted()) 項看過的。重設後會重新回到隨機池。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
    }
}

/// 三類比例的長條，加上圖例
private struct ProportionBar: View {
    struct Segment: Identifiable {
        let id: String
        let title: String
        let value: Double
        let color: Color
    }

    let segments: [Segment]

    private var total: Double { segments.reduce(0) { $0 + $1.value } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(segments.filter { $0.value > 0 }) { segment in
                        Rectangle()
                            .fill(segment.color)
                            .frame(width: max(geo.size.width * segment.value / max(total, 1), 4))
                    }
                }
                .frame(width: geo.size.width, alignment: .leading)
                .clipShape(.capsule)
            }
            .frame(height: 14)

            HStack(spacing: 14) {
                ForEach(segments) { segment in
                    HStack(spacing: 5) {
                        Circle().fill(segment.color).frame(width: 8, height: 8)
                        Text(segment.title)
                        Text((total > 0 ? segment.value / total : 0).formatted(.percent.precision(.fractionLength(0))))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            .font(.caption)
        }
    }
}

#Preview("淺色") {
    NavigationStack { StatsView() }
        .modelContainer(PreviewData.container)
}

#Preview("深色") {
    NavigationStack { StatsView() }
        .modelContainer(PreviewData.container)
        .preferredColorScheme(.dark)
}
