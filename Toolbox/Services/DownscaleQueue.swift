import Foundation
import AVFoundation
import PhotosUI
import UniformTypeIdentifiers

/// 「4K 轉 1080p」的工作佇列：讀取挑好的影片、依序轉檔、存回相簿。
/// 畫面狀態在主執行緒；真正的轉檔在 DownscaleTranscoder 的背景佇列上跑。
@Observable
@MainActor
final class DownscaleQueue {
    struct Outcome: Equatable {
        let beforeSize: Int64
        let afterSize: Int64
        let audio: AudioCheckSummary
        let keptSpatial: Bool
        let saveError: String?
    }

    /// AudioCheck 的畫面用摘要（Equatable 方便 SwiftUI 比對）。
    struct AudioCheckSummary: Equatable {
        let sourceHadSpatial: Bool
        let spatialPreserved: Bool
        let tracksMatch: Bool
        let expected: [String]
        let output: [String]
        let systemOutput: Bool?
        /// 跟原片不一樣的地方，空的代表一致。
        let problems: [String]
    }

    enum Status: Equatable {
        case loading
        case ready
        case unsupported(String)
        case running
        case done(Outcome)
        case failed(String)
    }

    struct Item: Identifiable {
        let id = UUID()
        var name: String
        var inputURL: URL?
        var probe: VideoProbe?
        var status: Status = .loading
        var progress: Double = 0
        var remaining: TimeInterval?
    }

    /// 空間音訊寫入失敗時，問使用者要不要只保留立體聲。
    struct SpatialQuestion: Identifiable {
        let id = UUID()
        let itemName: String
        let detail: String
        let hasStereo: Bool
    }

    var items: [Item] = []
    var isRunning = false
    var question: SpatialQuestion?
    var isHot = DownscaleSupport.isHot
    /// 觸覺回饋的觸發值。
    var successCount = 0
    var failureCount = 0

    private var task: Task<Void, Never>?
    private var answer: CheckedContinuation<Bool, Never>?
    private var background: BackgroundWork?
    private var createdDirectories: [URL] = []

    var readyCount: Int { items.filter { $0.status == .ready }.count }
    var hasFinished: Bool {
        !isRunning && items.contains {
            if case .done = $0.status { return true }
            if case .failed = $0.status { return true }
            return false
        }
    }

    // MARK: 讀取挑好的影片

    func load(_ results: [PHPickerResult]) {
        for result in results {
            let provider = result.itemProvider
            let item = Item(name: provider.suggestedName ?? "影片")
            items.append(item)
            let id = item.id
            Task {
                do {
                    let (url, directory) = try await Self.loadMovie(provider)
                    createdDirectories.append(directory)
                    let name = provider.suggestedName ?? url.deletingPathExtension().lastPathComponent
                    let probe = try await DownscaleTranscoder.probe(url: url, name: name)
                    update(id) {
                        $0.name = name
                        $0.inputURL = url
                        $0.probe = probe
                        $0.status = probe.unsupportedReason.map(Status.unsupported) ?? .ready
                    }
                } catch {
                    update(id) { $0.status = .failed(error.localizedDescription) }
                }
            }
        }
    }

    /// 用 loadFileRepresentation 拿原始檔（挑選器設定成 .current，系統不會先轉檔）。
    /// 系統給的暫存檔在回呼結束後就會被刪，所以要在回呼裡搬走；能搬就不複製，省空間也省時間。
    private nonisolated static func loadMovie(_ provider: NSItemProvider) async throws -> (URL, URL) {
        let type = provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .movie) == true }
            ?? UTType.movie.identifier
        return try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                guard let url else {
                    continuation.resume(throwing: error ?? ToolError("讀不到這支影片（可能還在 iCloud 下載中）"))
                    return
                }
                do {
                    let directory = try Workspace.newDirectory("Downscale")
                    let destination = directory.appendingPathComponent(url.lastPathComponent)
                    do {
                        try FileManager.default.moveItem(at: url, to: destination)
                    } catch {
                        try FileManager.default.copyItem(at: url, to: destination)
                    }
                    continuation.resume(returning: (destination, directory))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func remove(_ id: Item.ID) {
        guard !isRunning, let index = items.firstIndex(where: { $0.id == id }) else { return }
        if let url = items[index].inputURL { try? FileManager.default.removeItem(at: url) }
        items.remove(at: index)
    }

    // MARK: 轉檔

    func start() {
        guard !isRunning, readyCount > 0 else { return }
        isRunning = true
        let total = readyCount
        let work = BackgroundWork.begin(title: "4K 轉 1080p", subtitle: "共 \(total) 支影片",
                                       systemImage: "arrow.down.right.and.arrow.up.left")
        background = work
        task = Task { await runAll(total: total) }
        work.onExpiration { [weak self] in
            Task { @MainActor in self?.cancel() }
        }
    }

    func cancel() {
        task?.cancel()
        // 正在等使用者回答時也要放行，讓佇列能結束。
        resolveQuestion(false)
    }

    private func runAll(total: Int) async {
        var finished = 0
        var allSucceeded = true
        for id in items.filter({ $0.status == .ready }).map(\.id) {
            if Task.isCancelled { break }
            let name = items.first(where: { $0.id == id })?.name ?? ""
            background?.update(subtitle: total > 1 ? "第 \(finished + 1)/\(total) 支・\(name)" : name)
            let ok = await process(id, keepSpatial: true, finished: finished, total: total)
            allSucceeded = allSucceeded && ok
            finished += 1
        }
        background?.finish(success: allSucceeded && !Task.isCancelled)
        background = nil
        isRunning = false
        task = nil
    }

    /// 處理一支影片；回傳是否成功。
    private func process(_ id: Item.ID, keepSpatial: Bool, finished: Int, total: Int) async -> Bool {
        guard let item = items.first(where: { $0.id == id }), let probe = item.probe else { return false }

        // 轉檔前檢查儲存空間。
        let required = DownscaleSupport.requiredCapacity(for: probe)
        if let available = DownscaleSupport.availableCapacity(), available < required {
            fail(id, "儲存空間不足：大約需要 \(Workspace.formattedSize(required))，目前剩 \(Workspace.formattedSize(available))。")
            return false
        }

        let output: URL
        do {
            let directory = try Workspace.newDirectory("Downscale")
            createdDirectories.append(directory)
            output = directory.appendingPathComponent(Self.outputName(for: probe.name))
        } catch {
            fail(id, error.localizedDescription)
            return false
        }

        update(id) {
            $0.status = .running
            $0.progress = 0
            $0.remaining = nil
        }
        let started = Date()
        let work = background
        do {
            // transcode 不是 MainActor 函式，會在背景執行；取消會一路傳進去。
            try await DownscaleTranscoder.transcode(probe, to: output, keepSpatialAudio: keepSpatial) { [weak self] value in
                work?.update(fraction: (Double(finished) + value) / Double(max(total, 1)))
                Task { @MainActor in self?.reportProgress(id, value, started: started) }
            }
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: output)
            markCancelled(id)
            return false
        } catch DownscaleError.spatialAudioWriteFailed(let detail) {
            try? FileManager.default.removeItem(at: output)
            guard keepSpatial, !Task.isCancelled else {
                fail(id, "空間音訊寫入失敗：\(detail)")
                return false
            }
            let hasStereo = probe.audioTracks.contains { !$0.isSpatial }
            let retry = await ask(SpatialQuestion(itemName: probe.name, detail: detail, hasStereo: hasStereo))
            guard retry, !Task.isCancelled else {
                if Task.isCancelled {
                    markCancelled(id)
                } else {
                    fail(id, "空間音訊寫入失敗，已略過這支。")
                }
                return false
            }
            return await process(id, keepSpatial: false, finished: finished, total: total)
        } catch {
            try? FileManager.default.removeItem(at: output)
            fail(id, error.localizedDescription)
            return false
        }

        // ---- 驗證、存回相簿 ----
        let check = await DownscaleTranscoder.verifyAudio(source: probe, output: output, keptSpatial: keepSpatial)
        let capture = await DownscaleSupport.captureInfo(of: probe.url)
        let afterSize = Workspace.fileSize(output)
        var saveError: String?
        do {
            try await DownscaleSupport.saveToPhotos(output, originalName: output.lastPathComponent,
                                                    date: capture.date, location: capture.location)
            // 已經進相簿了，暫存檔和原片副本都可以清掉，釋放空間給下一支。
            try? FileManager.default.removeItem(at: output)
            try? FileManager.default.removeItem(at: probe.url)
        } catch {
            saveError = error.localizedDescription
        }

        let summary = AudioCheckSummary(
            sourceHadSpatial: check.sourceHadSpatial,
            spatialPreserved: check.spatialPreserved,
            tracksMatch: check.tracksMatch,
            expected: check.expected.audio,
            output: check.output.audio,
            systemOutput: check.systemOutput,
            problems: check.problems
        )
        let outcome = Outcome(beforeSize: probe.fileSize, afterSize: afterSize, audio: summary,
                              keptSpatial: keepSpatial, saveError: saveError)
        update(id) {
            $0.status = .done(outcome)
            $0.progress = 1
            $0.remaining = nil
        }
        if saveError == nil { successCount += 1 } else { failureCount += 1 }
        return saveError == nil
    }

    private func reportProgress(_ id: Item.ID, _ value: Double, started: Date) {
        update(id) { item in
            guard item.status == .running else { return }
            item.progress = value
            // 剩餘時間：用已花的時間等比例推估；剛開始誤差大，先不顯示。
            let elapsed = Date().timeIntervalSince(started)
            if value > 0.03 {
                let estimate = elapsed / value * (1 - value)
                // 跟上一次的估計平滑一下，避免數字跳來跳去。
                item.remaining = item.remaining.map { $0 * 0.7 + estimate * 0.3 } ?? estimate
            }
        }
    }

    /// 取消：暫存檔已在 transcode 裡刪掉，這支回到「可轉換」，之後可以重新開始。
    private func markCancelled(_ id: Item.ID) {
        update(id) {
            $0.status = .ready
            $0.progress = 0
            $0.remaining = nil
        }
    }

    private func fail(_ id: Item.ID, _ message: String) {
        update(id) { $0.status = .failed(message) }
        failureCount += 1
    }

    private func update(_ id: Item.ID, _ change: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    // MARK: 詢問使用者

    private func ask(_ newQuestion: SpatialQuestion) async -> Bool {
        await withCheckedContinuation { continuation in
            answer = continuation
            question = newQuestion
        }
    }

    func resolveQuestion(_ retry: Bool) {
        question = nil
        answer?.resume(returning: retry)
        answer = nil
    }

    // MARK: 清理

    /// 離開畫面時取消工作並刪掉所有暫存檔（原片副本、未存的輸出）。
    func cleanUp() {
        cancel()
        let directories = createdDirectories
        createdDirectories = []
        Task.detached {
            for directory in directories { try? FileManager.default.removeItem(at: directory) }
        }
    }

    /// 刪掉整個 Downscale 暫存資料夾（只在畫面剛打開、還沒有任何工作時呼叫）。
    static func removeLeftovers() {
        let folder = Workspace.root.appendingPathComponent("Downscale", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
    }

    func reset() {
        guard !isRunning else { return }
        cleanUp()
        items = []
    }

    // MARK: 文字

    static func outputName(for name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        return (base.isEmpty ? "影片" : base) + "_1080p.mov"
    }
}
