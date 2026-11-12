import SwiftUI
import ThinkingOrbsKit

/// AI 處理中的點狀光球（ThinkingOrbsKit），取代轉圈圈。每種工作一個動畫。
/// 旁邊都有說明文字，所以小尺寸對 VoiceOver 隱藏；大尺寸單獨出現時讀「處理中」。
struct ThinkingIndicator: View {
    enum Activity {
        case transcribing, summarizing, searching, writingNotes, working

        /// 依處理佇列的狀態文字挑動畫：轉文字、辨識用聆聽，其他用整理。
        init(status: String) {
            self = status.contains("轉文字") || status.contains("辨識") ? .transcribing : .summarizing
        }

        var orb: OrbState {
            switch self {
            case .transcribing: .listening
            case .summarizing: .composing
            case .searching: .searching
            case .writingNotes: .weaving
            case .working: .working
            }
        }
    }

    var activity: Activity = .working
    var large = false

    var body: some View {
        ThinkingOrb(state: activity.orb, size: large ? .px64 : .px20)
            .accessibilityHidden(!large)
            .accessibilityLabel("處理中")
    }
}

/// 卡片外框。
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: .rect(cornerRadius: 22))
    }
}

/// 條列重點。
struct BulletList: View {
    let items: [String]
    var symbol = "circle.fill"
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: symbol)
                        .font(.system(size: symbol == "circle.fill" ? 6 : 14))
                        .foregroundStyle(tint)
                        .frame(width: 14)
                    Text(item).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// 音量條。
struct LevelMeter: View {
    let level: Float
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(.tint).frame(width: geo.size.width * CGFloat(level))
                    .animation(.linear(duration: 0.1), value: level)
            }
        }
        .frame(height: 6)
    }
}

extension Date {
    var hm: String { formatted(date: .omitted, time: .shortened) }
}

extension TimeInterval {
    var clockText: String {
        let total = Int(self)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
