import SwiftUI

struct QuickRecapSheet: View {
    @Environment(QuickRecap.self) private var quick
    @Environment(\.dismiss) private var dismiss
    @State private var showTranscript = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let range = quick.range {
                        Text("\(range.lowerBound.hm)–\(range.upperBound.hm)")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    switch quick.state {
                    case .idle, .working:
                        HStack(spacing: 10) {
                            ProgressView()
                            if case .working(let text) = quick.state { Text(text).foregroundStyle(.secondary) }
                        }
                        .frame(maxWidth: .infinity, minHeight: 160)
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        Button("再試一次") { Task { await quick.run(minutes: quick.minutes) } }.buttonStyle(.glass)
                    case .done:
                        if let d = quick.digest {
                            Text(d.title).font(.title2.bold())
                            if !d.points.isEmpty { BulletList(items: d.points) }
                            if !d.todos.isEmpty {
                                Text("待辦").font(.headline).padding(.top, 4)
                                BulletList(items: d.todos, symbol: "checkmark.circle", tint: .green)
                            }
                        }
                    }
                    if !quick.transcript.isEmpty, quick.state == .done {
                        DisclosureGroup("逐字稿", isExpanded: $showTranscript) {
                            Text(quick.transcript).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        .padding(.top, 8)
                    }
                }
                .padding(20)
            }
            .navigationTitle("最近 \(quick.minutes) 分鐘重點")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
