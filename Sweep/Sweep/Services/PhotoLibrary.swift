import Photos
import UIKit

/// PhotoKit 的讀取、刪除、收藏
enum PhotoLibrary {
    static func authorizationStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    static func requestAccess() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    // MARK: - 讀取

    /// 這個分類所有資產的 ID。只拿 ID，不載圖，幾萬張也不會吃光記憶體。
    static func identifiers(for filter: MediaFilter, excludeFavorites: Bool) async -> [String] {
        await Task.detached(priority: .userInitiated) {
            fetchIdentifiers(for: filter, excludeFavorites: excludeFavorites)
        }.value
    }

    nonisolated private static func fetchIdentifiers(for filter: MediaFilter, excludeFavorites: Bool) -> [String] {
        let options = PHFetchOptions()
        var predicates: [NSPredicate] = []
        if excludeFavorites {
            predicates.append(NSPredicate(format: "favorite == NO"))
        }

        let image = PHAssetMediaType.image.rawValue
        let screenshot = Int(PHAssetMediaSubtype.photoScreenshot.rawValue)
        let live = Int(PHAssetMediaSubtype.photoLive.rawValue)

        let result: PHFetchResult<PHAsset>
        switch filter {
        case .photos:
            predicates.append(NSPredicate(format: "mediaType == %d", image))
            predicates.append(NSPredicate(format: "(mediaSubtypes & %d) == 0", screenshot))
            options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            result = PHAsset.fetchAssets(with: options)
        case .screenshots:
            predicates.append(NSPredicate(format: "mediaType == %d", image))
            predicates.append(NSPredicate(format: "(mediaSubtypes & %d) != 0", screenshot))
            options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            result = PHAsset.fetchAssets(with: options)
        case .live:
            predicates.append(NSPredicate(format: "mediaType == %d", image))
            predicates.append(NSPredicate(format: "(mediaSubtypes & %d) != 0", live))
            options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            result = PHAsset.fetchAssets(with: options)
        case .videos:
            predicates.append(NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue))
            options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            result = PHAsset.fetchAssets(with: options)
        case .selfies, .animated:
            let subtype: PHAssetCollectionSubtype = filter == .selfies ? .smartAlbumSelfPortraits : .smartAlbumAnimated
            guard let album = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil).firstObject else {
                return []
            }
            if !predicates.isEmpty {
                options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            }
            result = PHAsset.fetchAssets(in: album, options: options)
        }

        var ids: [String] = []
        ids.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in ids.append(asset.localIdentifier) }
        return ids
    }

    /// 依照傳進來的順序拿回 PHAsset（相簿裡已經不見的會略過）
    static func assets(for ids: [String]) -> [PHAsset] {
        guard !ids.isEmpty else { return [] }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var byID: [String: PHAsset] = [:]
        result.enumerateObjects { asset, _, _ in byID[asset.localIdentifier] = asset }
        return ids.compactMap { byID[$0] }
    }

    static func asset(for id: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    }

    /// 這個資產在手機上佔的空間（原檔＋編輯後版本＋原況照片的影片）
    nonisolated static func fileSize(of asset: PHAsset) -> Int64 {
        PHAssetResource.assetResources(for: asset).reduce(Int64(0)) { sum, resource in
            sum + ((resource.value(forKey: "fileSize") as? NSNumber)?.int64Value ?? 0)
        }
    }

    /// 原始檔名，例如 IMG_1234.HEIC
    nonisolated static func originalFilename(of asset: PHAsset) -> String? {
        let resources = PHAssetResource.assetResources(for: asset)
        let main = resources.first { [.photo, .video].contains($0.type) } ?? resources.first
        return main?.originalFilename
    }

    // MARK: - 寫入

    /// 一次刪掉。系統只會跳一次確認視窗；照片會進「最近刪除」，30 天內救得回來。
    /// 回傳真的被刪掉的 ID；使用者在系統視窗按取消會丟出 `DeleteError.cancelled`
    static func delete(ids: [String]) async throws -> [String] {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var present: [String] = []
        result.enumerateObjects { asset, _, _ in present.append(asset.localIdentifier) }
        guard !present.isEmpty else { return [] }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(result)
            }
        } catch {
            let ns = error as NSError
            if ns.domain == PHPhotosErrorDomain, ns.code == PHPhotosError.Code.userCancelled.rawValue {
                throw DeleteError.cancelled
            }
            throw error
        }
        return present
    }

    static func setFavorite(_ value: Bool, id: String) async throws {
        guard let asset = asset(for: id) else { return }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest(for: asset).isFavorite = value
        }
    }

    /// 把影片原檔寫到暫存資料夾，給分享用
    static func exportVideo(_ asset: PHAsset) async throws -> URL {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .fullSizeVideo })
                ?? resources.first(where: { $0.type == .video }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let folder = FileManager.default.temporaryDirectory.appending(path: "share", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: resource.originalFilename)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options)
        return url
    }
}

enum DeleteError: Error {
    case cancelled
}
