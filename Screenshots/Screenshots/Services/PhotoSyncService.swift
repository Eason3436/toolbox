import Photos
import SwiftData
import SwiftUI
import Synchronization

/// PhotoKit 讀取與增量同步。
/// - 用 persistent change token 記錄上次處理位置，只處理新增／刪除的截圖；token 失效時退回全量比對。
/// - 前景時註冊 PHPhotoLibraryChangeObserver，新截圖即時入列。
@MainActor
@Observable
final class PhotoSyncService {
    enum Access: Equatable {
        case notDetermined
        case denied
        case limited
        case full
    }

    private(set) var access: Access
    private(set) var isSyncing = false
    private(set) var hasSynced = false
    var errorMessage: String?

    let thumbnails = ThumbnailService()

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let queue: AnalysisQueue
    @ObservationIgnored private var observer: LibraryObserver?
    @ObservationIgnored private var pendingChangeTask: Task<Void, Never>?

    private static let tokenKey = "photoChangeToken"
    private static let rangeKey = "importRange"

    init(context: ModelContext, queue: AnalysisQueue) {
        self.context = context
        self.queue = queue
        access = Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    var importRange: ImportRange {
        ImportRange(rawValue: UserDefaults.standard.string(forKey: Self.rangeKey) ?? "") ?? .all
    }

    // MARK: - 權限

    func refreshAccess() {
        access = Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestAccess() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        access = Self.map(status)
    }

    private var canRead: Bool { access == .full || access == .limited }

    // MARK: - 監看相簿變更

    func startObserving() {
        guard canRead, observer == nil else { return }
        let observer = LibraryObserver { [weak self] in
            Task { @MainActor in self?.scheduleIncrementalSync() }
        }
        PHPhotoLibrary.shared().register(observer)
        self.observer = observer
    }

    func stopObserving() {
        if let observer { PHPhotoLibrary.shared().unregisterChangeObserver(observer) }
        observer = nil
    }

    /// 連續變更合併成一次同步（0.4 秒）。
    private func scheduleIncrementalSync() {
        pendingChangeTask?.cancel()
        pendingChangeTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            sync()
        }
    }

    // MARK: - 同步

    /// 有 token 就增量同步，沒有或失效就全量比對。
    func sync() {
        guard canRead else { return }
        isSyncing = true
        defer {
            isSyncing = false
            hasSynced = true
        }
        if let token = loadToken() {
            do {
                try incrementalSync(since: token)
                return
            } catch {
                appLog.info("增量同步失敗，改用全量比對：\(error.localizedDescription)")
            }
        }
        fullSync()
    }

    /// 匯入範圍改變時呼叫：重新全量比對。
    func resync() {
        guard canRead else { return }
        isSyncing = true
        defer {
            isSyncing = false
            hasSynced = true
        }
        fullSync()
    }

    private func incrementalSync(since token: PHPersistentChangeToken) throws {
        let library = PHPhotoLibrary.shared()
        let changes = try library.fetchPersistentChanges(since: token)
        var inserted = Set<String>()
        var updated = Set<String>()
        var deleted = Set<String>()
        for change in changes {
            let details = try change.changeDetails(for: .asset)
            inserted.formUnion(details.insertedLocalIdentifiers)
            updated.formUnion(details.updatedLocalIdentifiers)
            deleted.formUnion(details.deletedLocalIdentifiers)
            inserted.subtract(details.deletedLocalIdentifiers)
        }
        saveToken(library.currentChangeToken)
        guard !inserted.isEmpty || !updated.isEmpty || !deleted.isEmpty else { return }

        // 新增：只收截圖，且在匯入範圍內
        var newIDs: [String] = []
        if !inserted.isEmpty {
            let options = PHFetchOptions()
            options.predicate = Self.screenshotPredicate(range: importRange)
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: Array(inserted), options: options)
            let existing = existingIDs()
            for i in 0..<assets.count {
                let asset = assets.object(at: i)
                guard !existing.contains(asset.localIdentifier) else { continue }
                context.insert(ScreenshotItem(assetID: asset.localIdentifier, createdAt: asset.creationDate ?? .now))
                newIDs.append(asset.localIdentifier)
            }
        }

        // 更新：丟到「最近刪除」或隱藏的照片，fetch 不到就視為刪除
        let known = existingIDs()
        let updatedKnown = updated.intersection(known)
        if !updatedKnown.isEmpty {
            let stillThere = PHAsset.fetchAssets(withLocalIdentifiers: Array(updatedKnown), options: nil)
            var present = Set<String>()
            for i in 0..<stillThere.count { present.insert(stillThere.object(at: i).localIdentifier) }
            deleted.formUnion(updatedKnown.subtracting(present))
        }

        removeItems(ids: deleted.intersection(known))
        save()
        if !newIDs.isEmpty {
            appLog.info("新增 \(newIDs.count) 張截圖")
            let ids = newIDs
            Task { await queue.enqueue(ids, priority: true) }
        }
    }

    /// 全量比對：相簿裡的截圖 vs 資料庫。
    private func fullSync() {
        let options = PHFetchOptions()
        options.predicate = Self.screenshotPredicate(range: importRange)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let assets = PHAsset.fetchAssets(with: .image, options: options)

        var libraryIDs = Set<String>()
        var dates: [String: Date] = [:]
        for i in 0..<assets.count {
            let asset = assets.object(at: i)
            libraryIDs.insert(asset.localIdentifier)
            dates[asset.localIdentifier] = asset.creationDate ?? .now
        }

        let items = (try? context.fetch(FetchDescriptor<ScreenshotItem>())) ?? []
        var existing = Set<String>()
        var toRemove: [String] = []
        var manualIDs: [String] = []
        for item in items {
            existing.insert(item.assetID)
            if item.isManual {
                manualIDs.append(item.assetID)
            } else if !libraryIDs.contains(item.assetID) {
                toRemove.append(item.assetID)
            }
        }
        // 手動加入的：原圖還在就保留
        if !manualIDs.isEmpty {
            let found = PHAsset.fetchAssets(withLocalIdentifiers: manualIDs, options: nil)
            var present = Set<String>()
            for i in 0..<found.count { present.insert(found.object(at: i).localIdentifier) }
            toRemove += manualIDs.filter { !present.contains($0) }
        }

        let newIDs = libraryIDs.subtracting(existing).sorted { (dates[$0] ?? .distantPast) > (dates[$1] ?? .distantPast) }
        for id in newIDs {
            context.insert(ScreenshotItem(assetID: id, createdAt: dates[id] ?? .now))
        }
        removeItems(ids: Set(toRemove))
        save()
        saveToken(PHPhotoLibrary.shared().currentChangeToken)
        appLog.info("全量比對：共 \(libraryIDs.count) 張，新增 \(newIDs.count)，移除 \(toRemove.count)")
        Task { await queue.enqueueAllPending() }
    }

    private func existingIDs() -> Set<String> {
        var descriptor = FetchDescriptor<ScreenshotItem>()
        descriptor.propertiesToFetch = [\.assetID]
        let items = (try? context.fetch(descriptor)) ?? []
        return Set(items.map(\.assetID))
    }

    private func removeItems(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let list = Array(ids)
        let descriptor = FetchDescriptor<ScreenshotItem>(predicate: #Predicate { list.contains($0.assetID) })
        for item in (try? context.fetch(descriptor)) ?? [] {
            context.delete(item)
        }
        for id in list { ThumbnailCache.remove(id) }
        Task { await SpotlightIndexer.remove(ids: list) }
    }

    private func save() {
        do {
            try context.save()
        } catch {
            appLog.error("儲存失敗：\(error.localizedDescription)")
            errorMessage = "儲存資料時發生錯誤：\(error.localizedDescription)"
        }
    }

    // MARK: - 主動送入

    /// 把指定截圖加入資料庫（若不存在）並優先分析。
    func addAndAnalyze(assetID: String, createdAt: Date, isManual: Bool) {
        let id = assetID
        var descriptor = FetchDescriptor<ScreenshotItem>(predicate: #Predicate { $0.assetID == id })
        descriptor.fetchLimit = 1
        if let item = try? context.fetch(descriptor).first {
            if item.isArchived { item.isArchived = false }
        } else {
            context.insert(ScreenshotItem(assetID: id, createdAt: createdAt, isManual: isManual))
        }
        save()
        Task { await queue.enqueue([id], priority: true) }
    }

    /// 收錄最新一張截圖（App Intent 用）。可等待幾秒讓剛截的圖寫入相簿。
    func captureLatest(newerThan: Date?, waitSeconds: Double = 4) async -> String? {
        let deadline = Date.now.addingTimeInterval(waitSeconds)
        while true {
            let options = PHFetchOptions()
            options.predicate = Self.screenshotPredicate(range: .all)
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            options.fetchLimit = 1
            if let asset = PHAsset.fetchAssets(with: .image, options: options).firstObject {
                let date = asset.creationDate ?? .now
                if newerThan == nil || date >= newerThan! || Date.now >= deadline {
                    addAndAnalyze(assetID: asset.localIdentifier, createdAt: date, isManual: false)
                    return asset.localIdentifier
                }
            } else if Date.now >= deadline {
                return nil
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    /// 把一張圖片存進相簿並收錄（捷徑傳入的截圖、分享時相簿找不到對應的圖）。
    func saveToLibraryAndAnalyze(imageData: Data) async throws -> String {
        let box = IdentifierBox()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: imageData, options: nil)
            box.set(request.placeholderForCreatedAsset?.localIdentifier)
        }
        guard let id = box.value else { throw PhotoLoadError.imageUnavailable }
        addAndAnalyze(assetID: id, createdAt: .now, isManual: true)
        return id
    }

    // MARK: - Share Extension 收件匣

    /// 處理 Share Extension 送進來的圖片：先在相簿找同一張截圖，找不到就存進相簿。
    func processInbox() async {
        guard canRead else { return }
        for file in SharedInbox.pendingFiles() {
            defer { SharedInbox.remove(file) }
            guard let data = try? Data(contentsOf: file), let image = UIImage(data: data) else { continue }
            if let match = await ImageMatcher.findScreenshot(matching: image) {
                addAndAnalyze(assetID: match.id, createdAt: match.date, isManual: false)
            } else {
                do {
                    _ = try await saveToLibraryAndAnalyze(imageData: data)
                } catch {
                    appLog.error("分享的圖片存入相簿失敗：\(error.localizedDescription)")
                    errorMessage = "分享進來的圖片無法存入相簿：\(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - 刪除原圖

    /// 刪除相簿原圖（系統會跳出確認），成功後同步刪除資料庫紀錄。
    func deleteOriginals(ids: [String]) async -> Bool {
        let list = ids
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let assets = PHAsset.fetchAssets(withLocalIdentifiers: list, options: nil)
                PHAssetChangeRequest.deleteAssets(assets)
            }
            removeItems(ids: Set(list))
            save()
            return true
        } catch {
            // 使用者在系統確認視窗按取消也會走到這裡
            appLog.info("刪除原圖未完成：\(error.localizedDescription)")
            return false
        }
    }

    // MARK: - 工具

    func asset(for assetID: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject
    }

    static func screenshotPredicate(range: ImportRange) -> NSPredicate {
        var predicates = [
            NSPredicate(format: "(mediaSubtypes & %d) != 0", PHAssetMediaSubtype.photoScreenshot.rawValue)
        ]
        if let start = range.startDate() {
            predicates.append(NSPredicate(format: "creationDate >= %@", start as NSDate))
        }
        return NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
    }

    private func loadToken() -> PHPersistentChangeToken? {
        guard let data = UserDefaults.standard.data(forKey: Self.tokenKey) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: data)
    }

    private func saveToken(_ token: PHPersistentChangeToken) {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) {
            UserDefaults.standard.set(data, forKey: Self.tokenKey)
        }
    }

    func resetToken() {
        UserDefaults.standard.removeObject(forKey: Self.tokenKey)
    }

    private static func map(_ status: PHAuthorizationStatus) -> Access {
        switch status {
        case .authorized: .full
        case .limited: .limited
        case .notDetermined: .notDetermined
        default: .denied
        }
    }
}

/// 相簿變更通知（在背景執行緒呼叫），轉交給主執行緒處理。
final class LibraryObserver: NSObject, PHPhotoLibraryChangeObserver, Sendable {
    private let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        onChange()
    }
}

/// 從 performChanges 的閉包裡帶出新建立的識別碼。
final class IdentifierBox: Sendable {
    private let storage = Mutex<String?>(nil)
    func set(_ value: String?) { storage.withLock { $0 = value } }
    var value: String? { storage.withLock { $0 } }
}
