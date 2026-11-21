import Foundation

/// Google Drive v3 `files` 的回應模型與查詢參數。
public enum DriveAPI {
    public static let base = "https://www.googleapis.com/drive/v3"
    public static let folderMimeType = "application/vnd.google-apps.folder"
    public static let rootId = "root"
    /// 「與我共用」用的虛擬資料夾 ID（Drive 沒有這個 ID，只在 App 裡用）
    public static let sharedWithMeId = "sharedWithMe"

    /// 第一階段支援的副檔名（AVPlayer 原生）
    public static let playableExtensions: Set<String> = ["mp4", "m4v", "mov"]
    public static let playableMimeTypes: Set<String> = ["video/mp4", "video/x-m4v", "video/quicktime"]

    static let fileFields = "id,name,mimeType,size,modifiedTime,createdTime,parents,thumbnailLink,videoMediaMetadata(width,height,durationMillis)"

    /// 列出資料夾內容的網址
    public static func listURL(folderId: String, pageToken: String? = nil) -> URL {
        let q: String
        if folderId == sharedWithMeId {
            q = "sharedWithMe = true and trashed = false"
        } else {
            q = "'\(folderId.replacingOccurrences(of: "'", with: "\\'"))' in parents and trashed = false"
        }
        var c = URLComponents(string: base + "/files")!
        var items = [
            URLQueryItem(name: "q", value: q),
            URLQueryItem(name: "fields", value: "nextPageToken,files(\(fileFields))"),
            URLQueryItem(name: "pageSize", value: "1000"),
            URLQueryItem(name: "orderBy", value: "folder,name_natural"),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
        ]
        if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        c.queryItems = items
        // `+` 在 query 裡要編碼，不然 Google 會當成空白
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url!
    }

    public static func fileURL(fileId: String) -> URL {
        var c = URLComponents(string: base + "/files/" + fileId)!
        c.queryItems = [
            URLQueryItem(name: "fields", value: fileFields),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
        ]
        return c.url!
    }

    /// 下載（串流）檔案內容
    public static func mediaURL(fileId: String) -> URL {
        URL(string: base + "/files/" + fileId + "?alt=media&supportsAllDrives=true")!
    }
}

public struct DriveVideoMetadata: Codable, Sendable, Hashable {
    public var width: Int?
    public var height: Int?
    /// Drive 用字串回傳毫秒數
    public var durationMillis: String?

    public var durationSeconds: Double? { durationMillis.flatMap(Double.init).map { $0 / 1000 } }
}

public struct DriveFile: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var mimeType: String
    /// Drive 用字串回傳位元組數
    public var size: String?
    public var modifiedTime: String?
    public var createdTime: String?
    public var parents: [String]?
    public var thumbnailLink: String?
    public var videoMediaMetadata: DriveVideoMetadata?

    public init(id: String, name: String, mimeType: String, size: String? = nil) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.size = size
    }

    public var isFolder: Bool { mimeType == DriveAPI.folderMimeType }

    public var fileExtension: String {
        guard let dot = name.lastIndex(of: ".") else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }

    /// AVPlayer 能播的（第一階段：mp4／m4v／mov）
    public var isPlayableVideo: Bool {
        guard !isFolder else { return false }
        return DriveAPI.playableExtensions.contains(fileExtension) || DriveAPI.playableMimeTypes.contains(mimeType)
    }

    public var byteCount: Int64? { size.flatMap(Int64.init) }

    public var modifiedDate: Date? { modifiedTime.flatMap(DriveDate.parse) }
}

public struct DriveFileList: Codable, Sendable {
    public var nextPageToken: String?
    public var files: [DriveFile]
}

public enum DriveDate {
    /// Drive 的 RFC 3339 時間（有毫秒）
    public static func parse(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

/// Google API 的錯誤回應 `{"error": {"code": 401, "message": "..."}}`
public struct GoogleAPIError: Codable, Sendable {
    public struct Body: Codable, Sendable {
        public var code: Int?
        public var message: String?
    }
    public var error: Body
}
