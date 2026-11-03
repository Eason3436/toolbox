import Photos
import SwiftUI

/// 讀取相簿中的截圖。
/// 階段 1：每次重新整理都全量讀取；階段 2 會改成增量同步 + SwiftData。
@Observable
final class PhotoSyncService {
    enum Access: Equatable {
        case notDetermined
        case denied
        case limited
        case full
    }

    private(set) var access: Access
    private(set) var records: [ScreenshotRecord] = []
    private(set) var sections: [DaySection] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    var errorMessage: String?

    let thumbnails = ThumbnailService()

    /// 與 `records` 位置一一對應，用來取回 PHAsset。
    @ObservationIgnored private var fetchResult: PHFetchResult<PHAsset>?

    init() {
        access = Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func refreshAccess() {
        access = Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestAccess() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        access = Self.map(status)
        appLog.info("照片權限：\(String(describing: status.rawValue))")
    }

    /// 重新讀取指定範圍內的所有截圖（新到舊）。
    func reload(range: ImportRange) {
        guard access == .full || access == .limited else { return }
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }

        let options = PHFetchOptions()
        var predicates = [
            NSPredicate(format: "(mediaSubtypes & %d) != 0", PHAssetMediaSubtype.photoScreenshot.rawValue)
        ]
        if let start = range.startDate() {
            predicates.append(NSPredicate(format: "creationDate >= %@", start as NSDate))
        }
        options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let result = PHAsset.fetchAssets(with: .image, options: options)
        var list: [ScreenshotRecord] = []
        list.reserveCapacity(result.count)
        for i in 0..<result.count {
            let asset = result.object(at: i)
            list.append(ScreenshotRecord(
                id: asset.localIdentifier,
                index: i,
                createdAt: asset.creationDate ?? .distantPast,
                pixelWidth: asset.pixelWidth,
                pixelHeight: asset.pixelHeight
            ))
        }
        fetchResult = result
        records = list
        sections = DayGrouping.sections(from: list)
        appLog.info("讀到 \(list.count) 張截圖")
    }

    /// 取回截圖對應的 PHAsset；位置對不上時改用識別碼查詢。
    func asset(for record: ScreenshotRecord) -> PHAsset? {
        if let result = fetchResult, record.index < result.count {
            let asset = result.object(at: record.index)
            if asset.localIdentifier == record.id { return asset }
        }
        return PHAsset.fetchAssets(withLocalIdentifiers: [record.id], options: nil).firstObject
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
