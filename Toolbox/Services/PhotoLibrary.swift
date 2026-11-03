import Foundation
import Photos

private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

enum PhotoSaver {
    static func save(_ urls: [URL]) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw ToolError("沒有相簿的存取權限，請到「設定」開啟")
        }
        try await PHPhotoLibrary.shared().performChanges {
            for url in urls {
                switch FileKind.detect(url) {
                case .image:
                    _ = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                case .video:
                    _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                default:
                    break
                }
            }
        }
    }
}

/// 原況照片轉靜態照片：保留原始照片（含景深）與編輯資料，去掉影片部分。
enum LivePhotoService {
    struct Summary {
        var converted = 0
        var skipped = 0
        var lostEdits = 0
        var failures: [String] = []
        var deleted = false
    }

    static func requestAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }

    static func convert(identifiers: [String], deleteOriginals: Bool,
                        progress: @escaping @Sendable (Int, Int) -> Void) async -> Summary {
        var summary = Summary()
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var assets: [PHAsset] = []
        fetch.enumerateObjects { asset, _, _ in assets.append(asset) }

        var finished: [PHAsset] = []
        for (index, asset) in assets.enumerated() {
            progress(index + 1, assets.count)
            guard asset.mediaSubtypes.contains(.photoLive) else {
                summary.skipped += 1
                continue
            }
            do {
                let keptEdits = try await convertOne(asset)
                if !keptEdits { summary.lostEdits += 1 }
                summary.converted += 1
                finished.append(asset)
            } catch {
                summary.failures.append(error.localizedDescription)
            }
        }

        if deleteOriginals && !finished.isEmpty {
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.deleteAssets(finished as NSArray)
                }
                summary.deleted = true
            } catch {
                summary.failures.append("新照片已建立，但沒有刪除原本的原況照片：\(error.localizedDescription)")
            }
        }
        return summary
    }

    /// 回傳是否完整保留了編輯（含人像效果、攝影風格等可再調整的資料）。
    private static func convertOne(_ asset: PHAsset) async throws -> Bool {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let photo = resources.first(where: { $0.type == .photo }) else {
            throw ToolError("找不到原始照片")
        }
        let adjustment = resources.first { $0.type == .adjustmentData }
        let fullSize = resources.first { $0.type == .fullSizePhoto }

        let dir = try Workspace.newDirectory("LivePhoto")
        let photoURL = dir.appendingPathComponent(photo.originalFilename)
        try await write(photo, to: photoURL)

        var adjustmentURL: URL?
        var fullSizeURL: URL?
        if let adjustment {
            let url = dir.appendingPathComponent("Adjustments.plist")
            try await write(adjustment, to: url)
            adjustmentURL = url
        }
        if let fullSize {
            let ext = (fullSize.originalFilename as NSString).pathExtension
            let url = dir.appendingPathComponent("FullSize").appendingPathExtension(ext.isEmpty ? "heic" : ext)
            try await write(fullSize, to: url)
            fullSizeURL = url
        }

        let albums = userAlbums(containing: asset)
        if adjustmentURL != nil {
            do {
                try await create(from: asset, albums: albums, photo: photoURL, name: photo.originalFilename,
                                 adjustment: adjustmentURL, fullSize: fullSizeURL)
                return true
            } catch {
                // 系統不接受編輯資料時，改存編輯後的樣子（看起來一樣，但不能再還原編輯）。
                try await create(from: asset, albums: albums, photo: fullSizeURL ?? photoURL,
                                 name: photo.originalFilename, adjustment: nil, fullSize: nil)
                return false
            }
        }
        try await create(from: asset, albums: albums, photo: photoURL, name: photo.originalFilename,
                         adjustment: nil, fullSize: nil)
        return true
    }

    private static func write(_ resource: PHAssetResource, to url: URL) async throws {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options)
    }

    private static func create(from asset: PHAsset, albums: [PHAssetCollection], photo: URL, name: String,
                               adjustment: URL?, fullSize: URL?) async throws {
        let creationDate = asset.creationDate
        let location = asset.location
        let favorite = asset.isFavorite
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = name
            request.addResource(with: .photo, fileURL: photo, options: options)
            if let adjustment {
                request.addResource(with: .adjustmentData, fileURL: adjustment, options: nil)
            }
            if let fullSize {
                request.addResource(with: .fullSizePhoto, fileURL: fullSize, options: nil)
            }
            request.creationDate = creationDate
            request.location = location
            request.isFavorite = favorite
            if let placeholder = request.placeholderForCreatedAsset {
                for album in albums {
                    PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
                }
            }
        }
    }

    private static func userAlbums(containing asset: PHAsset) -> [PHAssetCollection] {
        let result = PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil)
        var albums: [PHAssetCollection] = []
        result.enumerateObjects { collection, _, _ in
            if collection.assetCollectionSubtype == .albumRegular && collection.canPerform(.addContent) {
                albums.append(collection)
            }
        }
        return albums
    }
}
