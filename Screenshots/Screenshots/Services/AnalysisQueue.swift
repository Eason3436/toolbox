import Foundation
import SwiftData
import UIKit

/// 佇列進度（給介面顯示）。
@MainActor
@Observable
final class QueueStatus {
    enum State: Equatable {
        case idle
        case running
        case paused(String)
    }

    var state: State = .idle
    /// 這一輪已處理
    var completed = 0
    /// 這一輪總數
    var total = 0
    /// 資料庫中還在等待分析的數量
    var pendingCount = 0
    var failedCount = 0
    var readiness: ModelReadiness = .current

    var progressText: String? {
        switch state {
        case .running: "分析中 \(completed) / \(total)"
        case .paused(let reason): reason
        case .idle: pendingCount > 0 ? "等待分析 \(pendingCount) 張" : nil
        }
    }
}

/// 串行分析佇列（同時最多 1 張）。新截圖優先，舊截圖排後。
@ModelActor
actor AnalysisQueue {
    private var queue: [String] = []
    private var queued = Set<String>()
    private var isRunning = false
    private var isAppActive = true
    private var allowBackgroundRun = false
    private var status: QueueStatus?
    private var completedThisRun = 0

    func attach(status: QueueStatus) {
        self.status = status
    }

    func setAppActive(_ active: Bool) {
        isAppActive = active
    }

    /// 加入佇列。`priority` 為 true 時插到最前面（新截圖）。
    func enqueue(_ ids: [String], priority: Bool) {
        let fresh = ids.filter { !queued.contains($0) }
        if priority {
            // 已在佇列中的也往前移
            queue.removeAll { ids.contains($0) }
            queue.insert(contentsOf: ids, at: 0)
        } else {
            queue.append(contentsOf: fresh)
        }
        queued.formUnion(ids)
        startIfNeeded()
    }

    /// 把資料庫中所有待分析的截圖排入佇列（啟動、回到前景、模型就緒時呼叫）。
    func enqueueAllPending() {
        let pending = AnalysisStatus.pending.rawValue
        var descriptor = FetchDescriptor<ScreenshotItem>(
            predicate: #Predicate { $0.statusRaw == pending },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.propertiesToFetch = [\.assetID, \.ocrText]
        let items = (try? modelContext.fetch(descriptor)) ?? []
        let modelReady = ModelReadiness.current == .available
        // 模型未就緒時，只排入還沒做 OCR 的（先讓全文搜尋可用）
        let ids = items.filter { modelReady || $0.ocrText == nil }.map(\.assetID)
        enqueue(ids, priority: false)
        Task { await refreshCounts() }
    }

    /// 把失敗的重新排入。
    func retryFailed() {
        let failed = AnalysisStatus.failed.rawValue
        let descriptor = FetchDescriptor<ScreenshotItem>(predicate: #Predicate { $0.statusRaw == failed })
        let items = (try? modelContext.fetch(descriptor)) ?? []
        for item in items {
            item.status = .pending
            item.failureMessage = nil
        }
        try? modelContext.save()
        enqueue(items.sorted { $0.createdAt > $1.createdAt }.map(\.assetID), priority: false)
    }

    /// 全部重新分析。
    func reanalyzeAll() {
        let items = (try? modelContext.fetch(FetchDescriptor<ScreenshotItem>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
        for item in items {
            item.status = .pending
            item.failureMessage = nil
        }
        try? modelContext.save()
        enqueue(items.map(\.assetID), priority: false)
    }

    /// 單張重新分析（詳情頁的「重新分析」）。
    func reanalyze(_ id: String) {
        if let item = fetchItem(id) {
            item.status = .pending
            item.failureMessage = nil
            try? modelContext.save()
        }
        enqueue([id], priority: true)
    }

    /// 背景任務：在充電時執行直到佇列清空或時間用完。
    func runInBackground() async {
        allowBackgroundRun = true
        enqueueAllPending()
        while isRunning || !queue.isEmpty {
            if Task.isCancelled { break }
            try? await Task.sleep(for: .seconds(1))
        }
        allowBackgroundRun = false
    }

    func stopBackgroundRun() {
        allowBackgroundRun = false
    }

    var hasWork: Bool { !queue.isEmpty }

    // MARK: - 執行

    private func startIfNeeded() {
        guard !isRunning, !queue.isEmpty else { return }
        isRunning = true
        completedThisRun = 0
        Task { await runLoop() }
    }

    private func runLoop() async {
        defer { isRunning = false }
        while !queue.isEmpty {
            if let reason = pauseReason() {
                await report(state: .paused(reason))
                // 過熱時等一下再檢查；低耗電且在背景時直接停止，等回到前景再繼續
                if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
                    try? await Task.sleep(for: .seconds(30))
                    continue
                }
                return
            }
            let id = queue.removeFirst()
            queued.remove(id)
            await report(state: .running)
            await process(id)
            completedThisRun += 1
        }
        await report(state: .idle)
        await refreshCounts()
    }

    private func pauseReason() -> String? {
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .serious || thermal == .critical {
            return "手機溫度偏高，暫停分析"
        }
        if !isAppActive {
            if ProcessInfo.processInfo.isLowPowerModeEnabled {
                return "低耗電模式：只在 App 開著時分析"
            }
            if !allowBackgroundRun {
                return "App 在背景，暫停分析"
            }
        }
        return nil
    }

    private func fetchItem(_ id: String) -> ScreenshotItem? {
        var descriptor = FetchDescriptor<ScreenshotItem>(predicate: #Predicate { $0.assetID == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /// 分析一張：OCR → Foundation Models → NSDataDetector 校正 → 存檔 → Spotlight。
    /// 失敗重試 1 次，仍失敗標記為「分析失敗」。
    private func process(_ id: String) async {
        guard let item = fetchItem(id) else { return }
        guard item.status != .done else { return }

        var lastError: Error?
        for attempt in 0..<2 {
            do {
                try await analyze(item, includeOCRInPrompt: attempt == 0)
                lastError = nil
                break
            } catch is CancellationError {
                return
            } catch PhotoLoadError.assetMissing {
                // 原圖已刪除：直接移除紀錄
                modelContext.delete(item)
                try? modelContext.save()
                await SpotlightIndexer.remove(ids: [id])
                ThumbnailCache.remove(id)
                return
            } catch {
                lastError = error
                appLog.error("分析失敗（第 \(attempt + 1) 次）\(id)：\(error.localizedDescription)")
            }
        }
        if let lastError {
            item.status = .failed
            item.failureMessage = lastError.localizedDescription
            try? modelContext.save()
        }
    }

    private func analyze(_ item: ScreenshotItem, includeOCRInPrompt: Bool) async throws {
        let id = item.assetID
        // 1. 讀取影像（OCR 用螢幕原尺寸，AI 用縮小版）
        let fullImage = try await PhotoImageLoader.loadImage(assetID: id, maxPixel: 2900)
        let thumbnailData = ThumbnailCache.store(fullImage, for: id)

        // 2. Vision OCR（已做過就沿用）
        let ocrText: String
        if let existing = item.ocrText {
            ocrText = existing
        } else {
            ocrText = try await OCRService.recognizeText(in: fullImage)
            item.ocrText = ocrText
            try? modelContext.save()
        }

        // 模型未就緒：保留在待分析，OCR 結果已可供搜尋
        let readiness = ModelReadiness.current
        await MainActor.run { [status] in status?.readiness = readiness }
        guard readiness == .available else {
            await SpotlightIndexer.index(item.searchDocument, thumbnailData: thumbnailData)
            return
        }

        // 3. Foundation Models（圖片＋文字）
        let aiImage = Self.downscaled(fullImage, maxPixel: 1280)
        let analysis = try await AIAnalyzer.analyze(image: aiImage, ocrText: includeOCRInPrompt ? ocrText : "")

        // 4. NSDataDetector 校正並合併
        let aiEntities = ScreenshotEntities(
            dates: analysis.dates.map { DetectedDate(text: $0, date: nil, duration: nil) },
            places: analysis.places,
            urls: analysis.urls,
            phoneNumbers: analysis.phoneNumbers,
            prices: analysis.prices
        )
        let detected = EntityExtractor.detect(in: ocrText, referenceDate: item.createdAt)

        item.title = analysis.title.trimmingCharacters(in: .whitespacesAndNewlines)
        item.summary = analysis.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        item.category = analysis.category.appCategory.rawValue
        item.keywords = EntityExtractor.dedupe(analysis.keywords)
        item.entities = EntityExtractor.merge(ai: aiEntities, detected: detected)
        item.status = .done
        item.failureMessage = nil
        item.analyzedAt = .now
        applyAutoRules(to: item)
        try modelContext.save()

        // 5. Spotlight
        await SpotlightIndexer.index(item.searchDocument, thumbnailData: thumbnailData)
    }

    /// 收藏集自動規則：分類符合就加入。
    private func applyAutoRules(to item: ScreenshotItem) {
        guard item.category != nil else { return }
        let category: String? = item.category
        let descriptor = FetchDescriptor<ScreenshotCollection>(predicate: #Predicate { $0.autoRuleCategory == category })
        let collections = (try? modelContext.fetch(descriptor)) ?? []
        for collection in collections where !collection.items.contains(where: { $0.assetID == item.assetID }) {
            collection.items.append(item)
        }
    }

    private static func downscaled(_ image: UIImage, maxPixel: CGFloat) -> UIImage {
        let pixelW = image.size.width * image.scale
        let pixelH = image.size.height * image.scale
        let scale = min(1, maxPixel / max(pixelW, pixelH, 1))
        guard scale < 1 else { return image }
        let target = CGSize(width: pixelW * scale, height: pixelH * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    // MARK: - 回報

    private func report(state: QueueStatus.State) async {
        let completed = completedThisRun
        let total = completedThisRun + queue.count + (state == .running ? 1 : 0)
        await MainActor.run { [status] in
            status?.state = state
            status?.completed = completed
            status?.total = max(total, completed)
        }
    }

    func refreshCounts() async {
        let pending = AnalysisStatus.pending.rawValue
        let failed = AnalysisStatus.failed.rawValue
        let pendingCount = (try? modelContext.fetchCount(FetchDescriptor<ScreenshotItem>(predicate: #Predicate { $0.statusRaw == pending }))) ?? 0
        let failedCount = (try? modelContext.fetchCount(FetchDescriptor<ScreenshotItem>(predicate: #Predicate { $0.statusRaw == failed }))) ?? 0
        await MainActor.run { [status] in
            status?.pendingCount = pendingCount
            status?.failedCount = failedCount
            status?.readiness = .current
        }
    }
}
