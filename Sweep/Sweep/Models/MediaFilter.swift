import Foundation

/// 統計分三類
enum StatsKind: String, CaseIterable, Identifiable, Codable {
    case photo
    case screenshot
    case video

    var id: String { rawValue }

    var title: String {
        switch self {
        case .photo: "照片"
        case .screenshot: "截圖"
        case .video: "影片"
        }
    }

    var systemImage: String {
        switch self {
        case .photo: "photo"
        case .screenshot: "camera.viewfinder"
        case .video: "video"
        }
    }
}

/// 從相簿抽哪一種
enum MediaFilter: String, CaseIterable, Identifiable {
    case photos
    case screenshots
    case selfies
    case live
    case animated
    case videos

    var id: String { rawValue }

    /// 照片頁選單裡的分類（影片在自己的分頁）
    static let photoFilters: [MediaFilter] = [.photos, .screenshots, .selfies, .live, .animated]

    var title: String {
        switch self {
        case .photos: "照片"
        case .screenshots: "截圖"
        case .selfies: "自拍"
        case .live: "原況照片"
        case .animated: "動圖"
        case .videos: "影片"
        }
    }

    var systemImage: String {
        switch self {
        case .photos: "photo"
        case .screenshots: "camera.viewfinder"
        case .selfies: "person.crop.square"
        case .live: "livephoto"
        case .animated: "square.stack.3d.forward.dottedline"
        case .videos: "video"
        }
    }

    /// 刪掉後算在哪一類統計
    var statsKind: StatsKind {
        switch self {
        case .screenshots: .screenshot
        case .videos: .video
        default: .photo
        }
    }
}
