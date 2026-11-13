import Foundation
import AVFoundation
import CoreLocation
import Photos

/// 存回相簿、拍攝日期／地點、儲存空間這些周邊工作。
enum DownscaleSupport {
    // MARK: 拍攝日期與地點

    /// 從原片的檔案層級 metadata 讀拍攝日期與地點，存回相簿時寫進照片資料庫，
    /// 這樣新影片在相簿裡會排在原本的時間、出現在地圖上。
    static func captureInfo(of url: URL) async -> (date: Date?, location: CLLocation?) {
        let asset = AVURLAsset(url: url)
        var date: Date?
        if let item = try? await asset.load(.creationDate) {
            date = try? await item.load(.dateValue)
        }
        var location: CLLocation?
        if let items = try? await asset.load(.metadata) {
            let matches = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .quickTimeMetadataLocationISO6709)
                + AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierLocation)
            for item in matches {
                if let text = try? await item.load(.stringValue), let parsed = parseISO6709(text) {
                    location = parsed
                    break
                }
            }
        }
        return (date, location)
    }

    /// 解析 ISO 6709 的十進位度數格式，例如「+25.0330+121.5654+010.000/」。
    static func parseISO6709(_ text: String) -> CLLocation? {
        var numbers: [Double] = []
        var current = ""
        for character in text {
            if character == "+" || character == "-" || character == "/" {
                if let value = Double(current) { numbers.append(value) }
                current = character == "/" ? "" : String(character)
                if character == "/" { break }
            } else if character.isNumber || character == "." {
                current.append(character)
            }
        }
        if let value = Double(current) { numbers.append(value) }
        guard numbers.count >= 2 else { return nil }
        let latitude = numbers[0], longitude = numbers[1]
        guard (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        if numbers.count >= 3 {
            return CLLocation(coordinate: coordinate, altitude: numbers[2], horizontalAccuracy: 0,
                              verticalAccuracy: 0, timestamp: Date())
        }
        return CLLocation(latitude: latitude, longitude: longitude)
    }

    // MARK: 存回相簿

    static func saveToPhotos(_ url: URL, originalName: String, date: Date?, location: CLLocation?) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw ToolError("沒有相簿的存取權限，請到「設定 › 工具箱 › 照片」開啟")
        }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = originalName
            request.addResource(with: .video, fileURL: url, options: options)
            if let date { request.creationDate = date }
            if let location { request.location = location }
        }
    }

    // MARK: 儲存空間與溫度

    /// 目前可用空間（位元組）。
    static func availableCapacity() -> Int64? {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// 轉一支影片需要的空間：預估輸出大小再多 20%，加上 300 MB 緩衝給系統。
    static func requiredCapacity(for probe: VideoProbe) -> Int64 {
        Int64(Double(probe.estimatedOutputSize) * 1.2) + 300_000_000
    }

    static var isHot: Bool {
        let state = ProcessInfo.processInfo.thermalState
        return state == .serious || state == .critical
    }
}
