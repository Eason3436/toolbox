import Foundation

/// 進度回報：0～1。用 TaskLocal 傳遞，讓巢狀的步驟（多個檔案、功能包的多個步驟）
/// 各自只回報自己那一段，外層自動換算成整體進度。
enum ProgressScope {
    @TaskLocal static var report: (@Sendable (Double) -> Void)?

    /// 把 body 的 0～1 進度對應到目前範圍的 [start, start + length]。
    static func slice<T>(start: Double, length: Double,
                         _ body: () async throws -> T) async rethrows -> T {
        let outer = report
        outer?(start)
        let mapped: (@Sendable (Double) -> Void)? = outer.map { outer in
            { fraction in outer(start + length * Swift.min(Swift.max(fraction, 0), 1)) }
        }
        return try await $report.withValue(mapped) {
            try await body()
        }
    }
}
