import Foundation
import SwiftData

/// #Preview 用的 in-memory 資料
@MainActor
enum PreviewData {
    static let container: ModelContainer = {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: ViewedAsset.self, CleanStats.self, configurations: config)
        let samples: [(StatsKind, Int, Int, Int64)] = [
            (.photo, 420, 96, 812_000_000),
            (.screenshot, 260, 180, 96_000_000),
            (.video, 58, 21, 3_400_000_000),
        ]
        for sample in samples {
            let stats = CleanStats(category: sample.0)
            stats.viewedCount = sample.1
            stats.deletedCount = sample.2
            stats.freedBytes = sample.3
            container.mainContext.insert(stats)
        }
        return container
    }()
}
