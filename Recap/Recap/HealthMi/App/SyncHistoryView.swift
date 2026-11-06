import SwiftData
import SwiftUI

/// 同步歷史日誌頁面。
struct SyncHistoryView: View {
    @Query(sort: \SyncLogEntry.timestamp, order: .reverse) private var entries: [SyncLogEntry]

    var body: some View {
        List {
            if entries.isEmpty {
                ContentUnavailableView("暫無同步記錄", systemImage: "clock")
            } else {
                ForEach(entries, id: \.persistentModelID) { entry in
                    logRow(entry)
                }
            }
        }
        .navigationTitle("同步歷史")
    }

    private func logRow(_ entry: SyncLogEntry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(entry.displayName)
                        .font(.subheadline)
                    if entry.success {
                        Text("+\(entry.added)")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
                if let error = entry.errorMessage, !error.isEmpty {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("拉取 \(entry.fetched)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

